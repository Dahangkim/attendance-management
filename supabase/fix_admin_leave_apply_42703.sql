begin;

-- 여러 차례 나누어 설치된 기관 데이터베이스에서 빠질 수 있는 열을 먼저 보완합니다.
alter table public.attendance_records add column if not exists leave_type text not null default 'none';
alter table public.attendance_records add column if not exists is_closed boolean not null default false;
alter table public.attendance_records add column if not exists changed boolean not null default false;
alter table public.attendance_records add column if not exists deleted_at timestamptz;

alter table public.correction_requests add column if not exists end_date date;
alter table public.correction_requests add column if not exists start_time time;
alter table public.correction_requests add column if not exists end_time time;
alter table public.correction_requests add column if not exists calculated_minutes integer not null default 0;
alter table public.correction_requests add column if not exists approved_minutes integer not null default 0;
alter table public.correction_requests add column if not exists request_subtype text not null default '';

alter table public.attendance_audit_logs
  add column if not exists correction_request_id uuid references public.correction_requests(id) on delete restrict;

create or replace function public.admin_apply_leave_to_attendance_record(
  p_record_id uuid,
  p_request_type text,
  p_start_time time,
  p_end_time time,
  p_request_subtype text,
  p_comment text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_request_id uuid;
  v_minutes integer;
  v_leave_type text := 'none';
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_request_type not in ('annual_leave','comp_time','sick_leave','other_leave') then raise exception 'INVALID_LEAVE_TYPE'; end if;
  if char_length(trim(coalesce(p_comment,''))) < 5 then raise exception 'COMMENT_REQUIRED'; end if;
  if p_start_time is null or p_end_time is null or p_end_time <= p_start_time then raise exception 'INVALID_TIME_RANGE'; end if;
  if p_request_type = 'other_leave' and char_length(trim(coalesce(p_request_subtype,''))) < 2 then raise exception 'OTHER_LEAVE_NAME_REQUIRED'; end if;

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;

  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if exists (
    select 1
    from public.monthly_closings
    where year = extract(year from v_record.work_date)
      and month = extract(month from v_record.work_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  v_minutes := public.calculate_attendance_request_minutes(
    p_request_type,
    v_record.work_date,
    v_record.work_date,
    p_start_time,
    p_end_time
  );
  if v_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;

  select id into v_request_id
  from public.correction_requests
  where attendance_record_id = v_record.id
    and request_type in ('annual_leave','comp_time','sick_leave','other_leave')
  order by requested_at desc
  limit 1
  for update;

  if v_request_id is null then
    insert into public.correction_requests (
      attendance_record_id, employee_id, target_date, end_date,
      start_time, end_time, calculated_minutes, approved_minutes,
      request_type, request_subtype, before_value, requested_value, reason,
      status, reviewer_id, reviewer_comment, reviewed_at
    ) values (
      v_record.id, v_record.employee_id, v_record.work_date, v_record.work_date,
      p_start_time, p_end_time, v_minutes, v_minutes,
      p_request_type,
      case when p_request_type = 'other_leave' then trim(coalesce(p_request_subtype,'')) else '' end,
      v_record.attendance_status, v_minutes::text, trim(p_comment),
      'approved', auth.uid(), trim(p_comment), now()
    ) returning id into v_request_id;
  else
    update public.correction_requests
    set target_date = v_record.work_date,
        end_date = v_record.work_date,
        start_time = p_start_time,
        end_time = p_end_time,
        calculated_minutes = v_minutes,
        approved_minutes = v_minutes,
        request_type = p_request_type,
        request_subtype = case when p_request_type = 'other_leave' then trim(coalesce(p_request_subtype,'')) else '' end,
        requested_value = v_minutes::text,
        reason = trim(p_comment),
        status = 'approved',
        reviewer_id = auth.uid(),
        reviewer_comment = trim(p_comment),
        reviewed_at = now()
    where id = v_request_id;
  end if;

  if p_request_type = 'annual_leave' then
    v_leave_type := case v_minutes
      when 480 then 'annual_leave'
      when 240 then 'half_day'
      when 120 then 'quarter_day'
      when 60 then 'hourly_leave'
      else 'none'
    end;
  elsif p_request_type = 'sick_leave' then
    v_leave_type := 'sick_leave';
  end if;

  update public.attendance_records
  set attendance_status = case when clock_out_at is null then 'working' else 'normal' end,
      leave_type = v_leave_type,
      changed = true,
      updated_at = now()
  where id = v_record.id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
  ) values (
    v_record.id, v_record.employee_id, 'admin_leave_applied', 'leave_request',
    jsonb_build_object(
      'attendance_status',v_record.attendance_status,
      'leave_type',coalesce(to_jsonb(v_record)->>'leave_type','none')
    )::text,
    jsonb_build_object('request_type',p_request_type,'start_time',p_start_time,'end_time',p_end_time,'minutes',v_minutes,'subtype',trim(coalesce(p_request_subtype,'')))::text,
    trim(p_comment), auth.uid(), v_role, v_request_id
  );

  return v_request_id;
end $$;

revoke all on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) from public, anon;
grant execute on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) to authenticated;

-- 대체휴무 사용일이 다음 달이어도 발생일의 유효 적립분에서 먼저 차감합니다.
-- 적립분보다 많이 사용한 경우 잔액을 음수로 만들지 않고 미연결 사용 이력만 남깁니다.
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

create or replace function public.allocate_comp_time_usage_without_negative()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_allocation record;
  v_credit record;
  v_needed integer := 0;
  v_use integer := 0;
begin
  for v_allocation in
    select credit_id, used_minutes
    from public.comp_time_usage_allocations
    where correction_request_id = new.id
  loop
    update public.comp_time_credits
    set remaining_minutes = least(granted_minutes, remaining_minutes + v_allocation.used_minutes)
    where id = v_allocation.credit_id;
  end loop;

  delete from public.comp_time_usage_allocations
  where correction_request_id = new.id;

  if new.status <> 'approved' or new.request_type <> 'comp_time' then
    return new;
  end if;

  v_needed := greatest(
    0,
    coalesce(
      nullif(new.approved_minutes, 0),
      nullif(new.calculated_minutes, 0),
      case when new.requested_value ~ '^[0-9]+$' then new.requested_value::integer else 0 end
    )
  );

  for v_credit in
    select credit.*
    from public.comp_time_credits credit
    join public.attendance_records attendance on attendance.id = credit.attendance_record_id
    where credit.employee_id = new.employee_id
      and credit.remaining_minutes > 0
      and credit.expires_on >= new.target_date
      and attendance.work_date < new.target_date
      and attendance.deleted_at is null
    order by credit.expires_on, attendance.work_date, credit.granted_at
    for update of credit
  loop
    exit when v_needed <= 0;
    v_use := least(v_needed, v_credit.remaining_minutes);

    update public.comp_time_credits
    set remaining_minutes = remaining_minutes - v_use
    where id = v_credit.id;

    insert into public.comp_time_usage_allocations (
      correction_request_id, credit_id, used_minutes
    ) values (
      new.id, v_credit.id, v_use
    );

    v_needed := v_needed - v_use;
  end loop;

  if v_needed > 0 then
    insert into public.attendance_audit_logs (
      attendance_record_id, employee_id, action_type, changed_field,
      before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
    ) values (
      new.attendance_record_id, new.employee_id,
      'comp_time_usage_unallocated', 'comp_time_balance',
      '', v_needed::text,
      '승인된 대체휴무 중 적립 이력과 아직 연결되지 않은 시간입니다. 잔액은 음수로 계산하지 않습니다.',
      coalesce(new.reviewer_id, auth.uid()), public.current_profile_role(), new.id
    );
  end if;

  return new;
end $$;

drop trigger if exists allocate_comp_time_usage_without_negative_trigger on public.correction_requests;
create trigger allocate_comp_time_usage_without_negative_trigger
after insert or update of status, request_type, approved_minutes, calculated_minutes, requested_value
on public.correction_requests
for each row execute function public.allocate_comp_time_usage_without_negative();

notify pgrst, 'reload schema';

commit;
