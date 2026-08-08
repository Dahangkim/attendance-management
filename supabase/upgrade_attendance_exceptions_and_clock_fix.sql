begin;

create table if not exists public.attendance_exceptions (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.profiles(id) on delete restrict,
  start_date date not null,
  end_date date not null,
  exception_type text not null check (exception_type in ('business_trip','approved_other')),
  reason text not null default '',
  approved_by uuid not null references public.profiles(id) on delete restrict,
  approved_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles(id) on delete restrict,
  cancellation_reason text not null default '',
  created_at timestamptz not null default now(),
  check (end_date >= start_date)
);

create index if not exists attendance_exceptions_period_idx
  on public.attendance_exceptions (employee_id, start_date, end_date)
  where cancelled_at is null;

alter table public.attendance_exceptions enable row level security;
drop policy if exists "own or admin exception read" on public.attendance_exceptions;
create policy "own or admin exception read" on public.attendance_exceptions
  for select to authenticated
  using (employee_id = auth.uid() or public.is_attendance_admin());

revoke insert, update, delete on public.attendance_exceptions from authenticated;

drop view if exists public.attendance_exceptions_view;
create view public.attendance_exceptions_view with (security_invoker = true) as
select
  ae.*,
  employee.name as employee_name,
  approver.name as approved_by_name
from public.attendance_exceptions ae
join public.profiles employee on employee.id = ae.employee_id
join public.profiles approver on approver.id = ae.approved_by;
grant select on public.attendance_exceptions_view to authenticated;

create or replace function public.admin_create_attendance_exception(
  p_employee_id uuid,
  p_start_date date,
  p_end_date date,
  p_exception_type text,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_id uuid;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_end_date < p_start_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_exception_type not in ('business_trip','approved_other') then raise exception 'INVALID_EXCEPTION_TYPE'; end if;
  if not exists (select 1 from public.profiles where id = p_employee_id and role = 'employee' and is_active = true) then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if exists (
    select 1 from public.attendance_exceptions
    where employee_id = p_employee_id
      and cancelled_at is null
      and start_date <= p_end_date
      and end_date >= p_start_date
  ) then raise exception 'EXCEPTION_OVERLAP'; end if;

  insert into public.attendance_exceptions (employee_id, start_date, end_date, exception_type, reason, approved_by)
  values (p_employee_id, p_start_date, p_end_date, p_exception_type, trim(coalesce(p_reason,'')), auth.uid())
  returning id into v_id;

  insert into public.attendance_audit_logs (employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role)
  values (
    p_employee_id,
    'exception_create',
    'attendance_exception',
    '',
    jsonb_build_object('id',v_id,'start_date',p_start_date,'end_date',p_end_date,'exception_type',p_exception_type)::text,
    trim(coalesce(p_reason,'')),
    auth.uid(),
    v_role
  );
  return v_id;
end $$;

create or replace function public.admin_cancel_attendance_exception(p_exception_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_item public.attendance_exceptions;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_item from public.attendance_exceptions where id = p_exception_id and cancelled_at is null for update;
  if not found then raise exception 'EXCEPTION_NOT_FOUND'; end if;

  update public.attendance_exceptions
  set cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = trim(p_reason)
  where id = p_exception_id;

  insert into public.attendance_audit_logs (employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role)
  values (
    v_item.employee_id,
    'exception_cancel',
    'attendance_exception',
    jsonb_build_object('id',v_item.id,'start_date',v_item.start_date,'end_date',v_item.end_date,'exception_type',v_item.exception_type)::text,
    '취소됨',
    trim(p_reason),
    auth.uid(),
    v_role
  );
end $$;

revoke all on function public.admin_create_attendance_exception(uuid,date,date,text,text) from public, anon;
grant execute on function public.admin_create_attendance_exception(uuid,date,date,text,text) to authenticated;
revoke all on function public.admin_cancel_attendance_exception(uuid,text) from public, anon;
grant execute on function public.admin_cancel_attendance_exception(uuid,text) to authenticated;

create or replace function public.recalculate_attendance_month(p_year integer, p_month integer)
returns void language plpgsql security definer set search_path = public as $$
declare v_start date; v_end date; v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if not public.is_attendance_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  v_start := make_date(p_year, p_month, 1); v_end := (v_start + interval '1 month')::date;
  insert into public.attendance_records (employee_id, work_date, work_type, attendance_status, note)
  select p.id, day::date, 'office', 'absent', '자동 판정, 출퇴근기록 없음'
  from public.profiles p
  cross join generate_series(v_start, least(v_end - 1, v_today - 1), interval '1 day') day
  left join public.employee_schedule_overrides o on o.employee_id = p.id and o.work_date = day::date
  left join public.holidays h on h.holiday_date = day::date
  cross join public.organization_settings s
  where p.role = 'employee' and p.is_active
    and coalesce(o.is_workday, extract(isodow from day)::smallint = any(s.work_days))
    and h.holiday_date is null
    and not exists (
      select 1 from public.attendance_exceptions ae
      where ae.employee_id = p.id
        and ae.cancelled_at is null
        and day::date between ae.start_date and ae.end_date
    )
    and not exists (select 1 from public.attendance_records ar where ar.employee_id = p.id and ar.work_date = day::date)
  on conflict (employee_id, work_date) do nothing;
  update public.attendance_records
  set attendance_status = case
      when clock_in_at is null and clock_out_at is null then 'absent'
      when clock_in_at is null then 'missing_in'
      when clock_out_at is null and work_date < v_today then 'missing_out'
      else attendance_status end
  where work_date >= v_start and work_date < v_end and not is_closed
    and not exists (
      select 1 from public.attendance_exceptions ae
      where ae.employee_id = attendance_records.employee_id
        and ae.cancelled_at is null
        and attendance_records.work_date between ae.start_date and ae.end_date
    );
end $$;

revoke all on function public.recalculate_attendance_month(integer,integer) from public, anon;
grant execute on function public.recalculate_attendance_month(integer,integer) to authenticated;

-- 삭제한 당일 기록을 다시 입력할 때 이전 중복방지 행이 저장을 막지 않도록 정리합니다.
delete from public.attendance_events event
using public.attendance_records record
where event.attendance_record_id = record.id
  and record.deleted_at is not null;

create or replace function public.admin_delete_attendance(p_record_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_before text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  v_before := jsonb_build_object('work_date',v_record.work_date,'clock_in_at',v_record.clock_in_at,'clock_out_at',v_record.clock_out_at,'attendance_status',v_record.attendance_status,'note',v_record.note)::text;
  delete from public.attendance_events where employee_id = v_record.employee_id and work_date = v_record.work_date;
  update public.attendance_records set deleted_at = now(), deleted_by = auth.uid(), deletion_reason = trim(p_reason), updated_at = now() where id = p_record_id;
  insert into public.attendance_audit_logs (attendance_record_id, employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role)
  values (v_record.id, v_record.employee_id, 'admin_delete', 'attendance_record', v_before, '목록에서 삭제됨', trim(p_reason), auth.uid(), v_role);
end $$;

revoke all on function public.admin_delete_attendance(uuid,text) from public, anon;
grant execute on function public.admin_delete_attendance(uuid,text) to authenticated;

notify pgrst, 'reload schema';
commit;
