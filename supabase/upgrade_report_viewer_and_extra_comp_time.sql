begin;

-- 직원 계정을 유지한 채 조회 전용 부관리자 권한을 부여합니다.
alter table public.profiles
  add column if not exists can_view_reports boolean not null default false;

alter table public.attendance_records
  add column if not exists raw_overtime_minutes integer not null default 0;
alter table public.attendance_records
  add column if not exists recorded_overtime_minutes integer not null default 0;
alter table public.attendance_records
  add column if not exists approved_overtime_minutes integer not null default 0;
alter table public.attendance_records
  add column if not exists overtime_status text not null default 'none';
alter table public.attendance_records
  add column if not exists comp_time_eligible_minutes integer not null default 0;

drop view if exists public.attendance_records_view;
create view public.attendance_records_view with (security_invoker = true) as
select ar.*, p.name as employee_name, p.employee_number, p.department
from public.attendance_records ar
join public.profiles p on p.id = ar.employee_id
where ar.deleted_at is null;
grant select on public.attendance_records_view to authenticated;

-- 이전 대체휴무 보완 SQL을 실행하지 않은 기관 데이터베이스에서도
-- 이 파일 하나만으로 적립과 사용 내역을 준비할 수 있게 합니다.
create table if not exists public.comp_time_credits (
  id uuid primary key default gen_random_uuid(),
  attendance_record_id uuid not null unique references public.attendance_records(id) on delete restrict,
  employee_id uuid not null references public.profiles(id) on delete restrict,
  granted_minutes integer not null,
  remaining_minutes integer not null,
  expires_on date not null,
  granted_by uuid not null references public.profiles(id) on delete restrict,
  granted_at timestamptz not null default now(),
  reason text not null default ''
);

create table if not exists public.comp_time_usage_allocations (
  id uuid primary key default gen_random_uuid(),
  correction_request_id uuid not null references public.correction_requests(id) on delete restrict,
  credit_id uuid not null references public.comp_time_credits(id) on delete restrict,
  used_minutes integer not null check (used_minutes > 0),
  created_at timestamptz not null default now(),
  unique (correction_request_id, credit_id)
);

create index if not exists comp_time_credits_employee_expiry_idx
  on public.comp_time_credits (employee_id, expires_on);

alter table public.comp_time_credits enable row level security;
alter table public.comp_time_usage_allocations enable row level security;

alter table public.comp_time_credits drop constraint if exists comp_time_credits_granted_minutes_check;
alter table public.comp_time_credits drop constraint if exists comp_time_credits_remaining_minutes_check;
alter table public.comp_time_credits
  add constraint comp_time_credits_granted_minutes_check check (granted_minutes between 30 and 720),
  add constraint comp_time_credits_remaining_minutes_check check (remaining_minutes between 0 and 720);

create or replace function public.can_view_attendance_reports()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and is_active = true
      and (role in ('admin','super_admin') or can_view_reports)
  )
$$;

revoke all on function public.can_view_attendance_reports() from public, anon;
grant execute on function public.can_view_attendance_reports() to authenticated;

drop policy if exists "profiles own or admin read" on public.profiles;
create policy "profiles own or admin read" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.can_view_attendance_reports());

drop policy if exists "own or admin attendance read" on public.attendance_records;
create policy "own or admin attendance read" on public.attendance_records
  for select to authenticated
  using (employee_id = auth.uid() or public.can_view_attendance_reports());

drop policy if exists "own or admin correction read" on public.correction_requests;
create policy "own or admin correction read" on public.correction_requests
  for select to authenticated
  using (employee_id = auth.uid() or public.can_view_attendance_reports());

drop policy if exists "admin audit read" on public.attendance_audit_logs;
create policy "admin audit read" on public.attendance_audit_logs
  for select to authenticated
  using (public.can_view_attendance_reports());

drop policy if exists "own or admin exception read" on public.attendance_exceptions;
create policy "own or admin exception read" on public.attendance_exceptions
  for select to authenticated
  using (employee_id = auth.uid() or public.can_view_attendance_reports());

drop policy if exists "own or admin comp credits read" on public.comp_time_credits;
create policy "own or admin comp credits read" on public.comp_time_credits
  for select to authenticated
  using (employee_id = auth.uid() or public.can_view_attendance_reports());

drop policy if exists "own or admin comp allocations read" on public.comp_time_usage_allocations;
create policy "own or admin comp allocations read" on public.comp_time_usage_allocations
  for select to authenticated
  using (exists (
    select 1 from public.comp_time_credits c
    where c.id = credit_id
      and (c.employee_id = auth.uid() or public.can_view_attendance_reports())
  ));

revoke insert, update, delete on public.comp_time_credits from authenticated;
revoke insert, update, delete on public.comp_time_usage_allocations from authenticated;

drop view if exists public.comp_time_balances_view;
create view public.comp_time_balances_view with (security_invoker = true) as
select p.id as employee_id,
  coalesce((select sum(c.granted_minutes) from public.comp_time_credits c where c.employee_id = p.id),0)::integer as approved_overtime_minutes,
  coalesce((select sum(a.used_minutes) from public.comp_time_usage_allocations a join public.comp_time_credits c on c.id = a.credit_id where c.employee_id = p.id),0)::integer as used_comp_time_minutes,
  coalesce((select sum(c.remaining_minutes) from public.comp_time_credits c where c.employee_id = p.id and c.expires_on >= (now() at time zone 'Asia/Seoul')::date),0)::integer as available_comp_time_minutes
from public.profiles p
where p.is_active and p.role = 'employee';
grant select on public.comp_time_balances_view to authenticated;

create or replace function public.admin_set_report_viewer(
  p_employee_id uuid,
  p_enabled boolean
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_before boolean;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  select can_view_reports into v_before
  from public.profiles
  where id = p_employee_id and role = 'employee' and is_active = true
  for update;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;

  update public.profiles
  set can_view_reports = p_enabled, updated_at = now()
  where id = p_employee_id;

  insert into public.attendance_audit_logs (
    employee_id, action_type, changed_field, before_value, after_value,
    reason, changed_by, changed_by_role
  ) values (
    p_employee_id, 'report_viewer_changed', 'can_view_reports',
    v_before::text, p_enabled::text,
    case when p_enabled then '부관리자 조회 권한 부여' else '부관리자 조회 권한 해제' end,
    auth.uid(), v_role
  );
end $$;

revoke all on function public.admin_set_report_viewer(uuid,boolean) from public, anon;
grant execute on function public.admin_set_report_viewer(uuid,boolean) to authenticated;

-- 시간외근무는 하루 최대 4시간까지 승인하고, 겹치지 않는 실제 추가근무는
-- 관리자가 선택한 경우에만 1시간 단위 대체휴무로 별도 적립합니다.
create or replace function public.admin_review_overtime(
  p_record_id uuid,
  p_decision text,
  p_approved_minutes integer,
  p_comp_time_minutes integer,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_week_start date;
  v_week_total integer := 0;
  v_raw_minutes integer := 0;
  v_after text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'INVALID_DECISION'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if coalesce(v_record.recorded_overtime_minutes,0) <= 0 then raise exception 'NO_RECORDED_OVERTIME'; end if;
  v_raw_minutes := greatest(coalesce(v_record.raw_overtime_minutes,0), coalesce(v_record.recorded_overtime_minutes,0));

  if p_decision = 'approved' then
    if p_approved_minutes not in (60,90,120,150,180,210,240)
       or p_approved_minutes > v_record.recorded_overtime_minutes then
      raise exception 'INVALID_OVERTIME_MINUTES';
    end if;
    if p_comp_time_minutes < 0 or p_comp_time_minutes % 60 <> 0
       or p_approved_minutes + p_comp_time_minutes > v_raw_minutes then
      raise exception 'INVALID_EXTRA_COMP_TIME';
    end if;

    v_week_start := date_trunc('week', v_record.work_date::timestamp)::date;
    select coalesce(sum(approved_overtime_minutes + comp_time_eligible_minutes), 0)::integer into v_week_total
    from public.attendance_records
    where employee_id = v_record.employee_id
      and id <> v_record.id
      and work_date between v_week_start and v_week_start + 6
      and overtime_status = 'approved'
      and deleted_at is null;
    if v_week_total + p_approved_minutes + p_comp_time_minutes > 720 then raise exception 'WEEKLY_OVERTIME_LIMIT'; end if;

    update public.attendance_records
    set overtime_status = 'approved',
        approved_overtime_minutes = p_approved_minutes,
        comp_time_eligible_minutes = p_comp_time_minutes,
        changed = true,
        updated_at = now()
    where id = v_record.id;

    if p_comp_time_minutes > 0 then
      insert into public.comp_time_credits (
        attendance_record_id, employee_id, granted_minutes, remaining_minutes,
        expires_on, granted_by, reason
      ) values (
        v_record.id, v_record.employee_id, p_comp_time_minutes, p_comp_time_minutes,
        v_record.work_date + 30, auth.uid(), trim(p_reason)
      )
      on conflict (attendance_record_id) do update
      set granted_minutes = excluded.granted_minutes,
          remaining_minutes = greatest(0, excluded.granted_minutes - (public.comp_time_credits.granted_minutes - public.comp_time_credits.remaining_minutes)),
          expires_on = excluded.expires_on,
          granted_by = excluded.granted_by,
          granted_at = now(),
          reason = excluded.reason;
    else
      update public.comp_time_credits
      set remaining_minutes = 0,
          reason = trim(concat_ws(E'\n', reason, '관리자 재검토로 추가 대체휴무 적립 취소'))
      where attendance_record_id = v_record.id and remaining_minutes > 0;
    end if;
    v_after := jsonb_build_object('status','approved','minutes',p_approved_minutes,'comp_time_eligible_minutes',p_comp_time_minutes)::text;
  else
    update public.attendance_records
    set overtime_status = 'rejected',
        approved_overtime_minutes = 0,
        comp_time_eligible_minutes = 0,
        changed = true,
        updated_at = now()
    where id = v_record.id;
    update public.comp_time_credits
    set remaining_minutes = 0,
        reason = trim(concat_ws(E'\n', reason, '시간외근무 반려로 미사용 잔액 소멸'))
    where attendance_record_id = v_record.id and remaining_minutes > 0;
    v_after := jsonb_build_object('status','rejected','minutes',0,'comp_time_eligible_minutes',0)::text;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role
  ) values (
    v_record.id, v_record.employee_id, 'overtime_review', 'approved_overtime_minutes',
    jsonb_build_object('status',v_record.overtime_status,'minutes',v_record.approved_overtime_minutes,'comp_time_eligible_minutes',v_record.comp_time_eligible_minutes)::text,
    v_after, trim(p_reason), auth.uid(), v_role
  );
end $$;

revoke all on function public.admin_review_overtime(uuid,text,integer,integer,text) from public, anon;
grant execute on function public.admin_review_overtime(uuid,text,integer,integer,text) to authenticated;

notify pgrst, 'reload schema';
commit;
