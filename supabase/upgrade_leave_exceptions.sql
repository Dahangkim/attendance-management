begin;

alter table public.attendance_exceptions
  add column if not exists correction_request_id uuid references public.correction_requests(id) on delete restrict;

do $$
declare v_constraint record;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.attendance_exceptions'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%exception_type%'
  loop
    execute format('alter table public.attendance_exceptions drop constraint %I', v_constraint.conname);
  end loop;
end $$;

alter table public.attendance_exceptions
  add constraint attendance_exceptions_exception_type_check
  check (exception_type in (
    'business_trip','approved_other','annual_leave','comp_time','sick_leave','other_leave'
  )) not valid;

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
  v_request_id uuid;
  v_request_reason text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_end_date < p_start_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_exception_type not in ('business_trip','approved_other','annual_leave','comp_time','sick_leave','other_leave') then raise exception 'INVALID_EXCEPTION_TYPE'; end if;
  if p_exception_type = 'other_leave' and char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'OTHER_LEAVE_NAME_REQUIRED'; end if;
  if not exists (select 1 from public.profiles where id = p_employee_id and role = 'employee' and is_active = true) then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if exists (
    select 1 from public.attendance_exceptions
    where employee_id = p_employee_id
      and cancelled_at is null
      and start_date <= p_end_date
      and end_date >= p_start_date
  ) then raise exception 'EXCEPTION_OVERLAP'; end if;

  if p_exception_type in ('annual_leave','comp_time','sick_leave','other_leave') then
    v_request_reason := case p_exception_type
      when 'annual_leave' then '관리자 직접 등록 종일 연차'
      when 'comp_time' then '관리자 직접 등록 종일 대체휴무'
      when 'sick_leave' then '관리자 직접 등록 종일 병가'
      else '관리자 직접 등록 ' || trim(p_reason)
    end;

    insert into public.correction_requests (
      employee_id, target_date, end_date, start_time, end_time,
      request_type, request_subtype, before_value, requested_value, reason,
      status, reviewer_id, reviewer_comment, reviewed_at
    ) values (
      p_employee_id, p_start_date, p_end_date, time '09:00', time '18:00',
      p_exception_type,
      case when p_exception_type = 'other_leave' then trim(p_reason) else '' end,
      '관리자 직접 등록', '0', v_request_reason,
      'approved', auth.uid(), v_request_reason, now()
    ) returning id into v_request_id;

    update public.correction_requests
    set approved_minutes = calculated_minutes
    where id = v_request_id;
  end if;

  insert into public.attendance_exceptions (
    employee_id, start_date, end_date, exception_type, reason, approved_by, correction_request_id
  ) values (
    p_employee_id, p_start_date, p_end_date, p_exception_type,
    trim(coalesce(p_reason,'')), auth.uid(), v_request_id
  ) returning id into v_id;

  insert into public.attendance_audit_logs (
    employee_id, action_type, changed_field, before_value, after_value,
    reason, changed_by, changed_by_role, correction_request_id
  ) values (
    p_employee_id,
    'exception_create',
    'attendance_exception',
    '',
    jsonb_build_object('id',v_id,'start_date',p_start_date,'end_date',p_end_date,'exception_type',p_exception_type)::text,
    trim(coalesce(p_reason,'')),
    auth.uid(),
    v_role,
    v_request_id
  );
  return v_id;
end $$;

create or replace function public.admin_cancel_attendance_exception(
  p_exception_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_item public.attendance_exceptions;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;

  select * into v_item
  from public.attendance_exceptions
  where id = p_exception_id and cancelled_at is null
  for update;
  if not found then raise exception 'EXCEPTION_NOT_FOUND'; end if;

  update public.attendance_exceptions
  set cancelled_at = now(),
      cancelled_by = auth.uid(),
      cancellation_reason = trim(p_reason)
  where id = p_exception_id;

  if v_item.correction_request_id is not null then
    update public.correction_requests
    set status = 'rejected',
        reviewer_id = auth.uid(),
        reviewer_comment = '예외 일정 취소: ' || trim(p_reason),
        reviewed_at = now(),
        approved_minutes = 0
    where id = v_item.correction_request_id;
  end if;

  insert into public.attendance_audit_logs (
    employee_id, action_type, changed_field, before_value, after_value,
    reason, changed_by, changed_by_role, correction_request_id
  ) values (
    v_item.employee_id,
    'exception_cancel',
    'attendance_exception',
    jsonb_build_object('id',v_item.id,'start_date',v_item.start_date,'end_date',v_item.end_date,'exception_type',v_item.exception_type)::text,
    '취소됨',
    trim(p_reason),
    auth.uid(),
    v_role,
    v_item.correction_request_id
  );
end $$;

revoke all on function public.admin_create_attendance_exception(uuid,date,date,text,text) from public, anon;
grant execute on function public.admin_create_attendance_exception(uuid,date,date,text,text) to authenticated;
revoke all on function public.admin_cancel_attendance_exception(uuid,text) from public, anon;
grant execute on function public.admin_cancel_attendance_exception(uuid,text) to authenticated;

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
    p_request_type, v_record.work_date, v_record.work_date, p_start_time, p_end_time
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
    jsonb_build_object('attendance_status',v_record.attendance_status,'leave_type',v_record.leave_type)::text,
    jsonb_build_object('request_type',p_request_type,'start_time',p_start_time,'end_time',p_end_time,'minutes',v_minutes,'subtype',trim(coalesce(p_request_subtype,'')))::text,
    trim(p_comment), auth.uid(), v_role, v_request_id
  );

  return v_request_id;
end $$;

revoke all on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) from public, anon;
grant execute on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) to authenticated;

notify pgrst, 'reload schema';

commit;
