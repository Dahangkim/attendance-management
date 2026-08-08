begin;

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
