begin;

alter table public.attendance_exceptions
  add column if not exists correction_request_id uuid references public.correction_requests(id) on delete restrict;

create or replace function public.admin_create_attendance_record(
  p_employee_id uuid,
  p_work_date date,
  p_clock_in_time time,
  p_clock_out_time time,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_record public.attendance_records;
  v_record_id uuid;
  v_clock_in timestamptz;
  v_clock_out timestamptz;
  v_was_deleted boolean := false;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_work_date is null or p_clock_in_time is null or p_clock_out_time is null then raise exception 'REQUIRED_VALUE_MISSING'; end if;
  if p_clock_out_time <= p_clock_in_time then raise exception 'INVALID_TIME_RANGE'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  if not exists (
    select 1 from public.profiles
    where id = p_employee_id and role = 'employee' and is_active = true
  ) then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if exists (
    select 1 from public.monthly_closings
    where year = extract(year from p_work_date)
      and month = extract(month from p_work_date)
      and status = 'closed'
  ) then raise exception 'MONTH_CLOSED'; end if;

  v_clock_in := (p_work_date + p_clock_in_time) at time zone 'Asia/Seoul';
  v_clock_out := (p_work_date + p_clock_out_time) at time zone 'Asia/Seoul';

  select * into v_record
  from public.attendance_records
  where employee_id = p_employee_id and work_date = p_work_date
  for update;

  if found and v_record.deleted_at is null then raise exception 'RECORD_ALREADY_EXISTS'; end if;

  if found then
    v_was_deleted := true;
    update public.attendance_records
    set work_type = 'office',
        clock_in_at = v_clock_in,
        clock_out_at = v_clock_out,
        clock_in_accuracy = null,
        clock_in_distance = null,
        clock_in_location_status = 'not_checked',
        clock_in_ip_address = null,
        clock_in_ip_matched = false,
        clock_out_accuracy = null,
        clock_out_distance = null,
        clock_out_location_status = 'not_checked',
        clock_out_ip_address = null,
        clock_out_ip_matched = false,
        attendance_status = 'normal',
        leave_type = 'none',
        note = '관리자 직접 추가: ' || trim(p_reason),
        changed = true,
        deleted_at = null,
        deleted_by = null,
        deletion_reason = '',
        updated_at = now()
    where id = v_record.id
    returning id into v_record_id;
  else
    insert into public.attendance_records (
      employee_id, work_date, work_type, clock_in_at, clock_out_at,
      clock_in_location_status, clock_out_location_status,
      attendance_status, leave_type, note, changed
    ) values (
      p_employee_id, p_work_date, 'office', v_clock_in, v_clock_out,
      'not_checked', 'not_checked',
      'normal', 'none', '관리자 직접 추가: ' || trim(p_reason), true
    ) returning id into v_record_id;
  end if;

  select * into v_record from public.attendance_records where id = v_record_id;
  update public.attendance_records
  set attendance_status = public.derive_attendance_status(v_record),
      updated_at = now()
  where id = v_record_id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role
  ) values (
    v_record_id, p_employee_id, 'admin_create', 'attendance_record',
    case when v_was_deleted then '삭제된 기록' else '기록 없음' end,
    jsonb_build_object(
      'work_date',p_work_date,
      'clock_in_time',p_clock_in_time,
      'clock_out_time',p_clock_out_time,
      'location','관리자 직접 등록, 위치 미확인'
    )::text,
    trim(p_reason), auth.uid(), v_role
  );

  return v_record_id;
end $$;

create or replace function public.sync_approved_request_to_attendance_exception()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_default_start time := coalesce((select default_start_time from public.organization_settings where id = true), time '09:00');
  v_default_end time := coalesce((select default_end_time from public.organization_settings where id = true), time '18:00');
  v_end_date date := coalesce(new.end_date, new.target_date);
  v_exception_type text;
  v_should_create boolean := false;
begin
  if coalesce(new.before_value,'') = '관리자 직접 등록' then return new; end if;

  if new.status = 'approved' then
    if new.request_type = 'business_trip' then
      v_exception_type := 'business_trip';
      v_should_create := true;
    elsif new.request_type in ('annual_leave','comp_time','sick_leave','other_leave')
      and coalesce(new.start_time, v_default_start) <= v_default_start
      and coalesce(new.end_time, v_default_end) >= v_default_end then
      v_exception_type := new.request_type;
      v_should_create := true;
    end if;
  end if;

  if v_should_create then
    if not exists (
      select 1 from public.attendance_exceptions
      where correction_request_id = new.id and cancelled_at is null
    ) and not exists (
      select 1 from public.attendance_exceptions
      where employee_id = new.employee_id
        and cancelled_at is null
        and start_date <= v_end_date
        and end_date >= new.target_date
    ) then
      insert into public.attendance_exceptions (
        employee_id, start_date, end_date, exception_type,
        reason, approved_by, approved_at, correction_request_id
      ) values (
        new.employee_id, new.target_date, v_end_date, v_exception_type,
        case when new.request_type = 'other_leave' and trim(coalesce(new.request_subtype,'')) <> ''
          then trim(new.request_subtype) || ': ' || trim(new.reason)
          else trim(new.reason)
        end,
        coalesce(new.reviewer_id, auth.uid()), coalesce(new.reviewed_at, now()), new.id
      );
    end if;
  else
    update public.attendance_exceptions
    set cancelled_at = coalesce(cancelled_at, now()),
        cancelled_by = coalesce(cancelled_by, auth.uid()),
        cancellation_reason = case when cancellation_reason = '' then '연결된 신청의 승인 상태 변경' else cancellation_reason end
    where correction_request_id = new.id and cancelled_at is null;
  end if;

  return new;
end $$;

drop trigger if exists sync_approved_request_to_attendance_exception_trigger on public.correction_requests;
create trigger sync_approved_request_to_attendance_exception_trigger
after insert or update of status, request_type, target_date, end_date, start_time, end_time
on public.correction_requests
for each row execute function public.sync_approved_request_to_attendance_exception();

insert into public.attendance_exceptions (
  employee_id, start_date, end_date, exception_type,
  reason, approved_by, approved_at, correction_request_id
)
select
  request.employee_id,
  request.target_date,
  coalesce(request.end_date, request.target_date),
  request.request_type,
  case when request.request_type = 'other_leave' and trim(coalesce(request.request_subtype,'')) <> ''
    then trim(request.request_subtype) || ': ' || trim(request.reason)
    else trim(request.reason)
  end,
  request.reviewer_id,
  coalesce(request.reviewed_at, now()),
  request.id
from public.correction_requests request
cross join lateral (
  select
    coalesce((select default_start_time from public.organization_settings where id = true), time '09:00') as default_start,
    coalesce((select default_end_time from public.organization_settings where id = true), time '18:00') as default_end
) settings
where request.status = 'approved'
  and coalesce(request.before_value,'') <> '관리자 직접 등록'
  and request.reviewer_id is not null
  and (
    request.request_type = 'business_trip'
    or (
      request.request_type in ('annual_leave','comp_time','sick_leave','other_leave')
      and coalesce(request.start_time, settings.default_start) <= settings.default_start
      and coalesce(request.end_time, settings.default_end) >= settings.default_end
    )
  )
  and not exists (
    select 1 from public.attendance_exceptions item
    where item.correction_request_id = request.id and item.cancelled_at is null
  )
  and not exists (
    select 1 from public.attendance_exceptions item
    where item.employee_id = request.employee_id
      and item.cancelled_at is null
      and item.start_date <= coalesce(request.end_date, request.target_date)
      and item.end_date >= request.target_date
  );

revoke all on function public.admin_create_attendance_record(uuid,date,time,time,text) from public, anon;
grant execute on function public.admin_create_attendance_record(uuid,date,time,time,text) to authenticated;

notify pgrst, 'reload schema';

commit;
