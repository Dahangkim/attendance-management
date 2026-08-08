begin;

drop function if exists public.admin_update_attendance_request(uuid,date,date,time,time,text,text,text);

create or replace function public.admin_update_attendance_request(
  p_request_id uuid,
  p_start_date date,
  p_end_date date,
  p_start_time time,
  p_end_time time,
  p_request_type text,
  p_request_subtype text,
  p_requested_value text,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_role text := public.current_profile_role();
  v_before text;
  v_request_type text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;

  select * into v_request
  from public.correction_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.status = 'approved' and v_request.request_type in ('clock_in_at','clock_out_at') then raise exception 'APPLIED_CLOCK_CORRECTION'; end if;
  if exists (
    select 1 from public.monthly_closings
    where year = extract(year from v_request.target_date)
      and month = extract(month from v_request.target_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then
    raise exception 'MONTH_CLOSED';
  end if;

  v_request_type := trim(coalesce(p_request_type,''));
  if v_request_type not in (
    'clock_in_at','clock_out_at','annual_leave','comp_time','sick_leave',
    'business_trip','overtime','other_leave'
  ) then
    raise exception 'INVALID_REQUEST_TYPE';
  end if;

  v_before := jsonb_build_object(
    'request_type',v_request.request_type,
    'start_date',v_request.target_date,
    'end_date',v_request.end_date,
    'start_time',v_request.start_time,
    'end_time',v_request.end_time,
    'subtype',v_request.request_subtype,
    'value',v_request.requested_value,
    'reason',v_request.reason,
    'status',v_request.status
  )::text;

  if v_request_type in ('clock_in_at','clock_out_at') then
    update public.correction_requests
    set request_type = v_request_type,
        target_date = p_start_date,
        end_date = p_start_date,
        start_time = null,
        end_time = null,
        request_subtype = '',
        approved_minutes = 0,
        requested_value = trim(coalesce(p_requested_value,'')),
        reason = trim(p_reason),
        status = 'pending',
        reviewer_id = null,
        reviewer_comment = '',
        reviewed_at = null
    where id = p_request_id;
  else
    update public.correction_requests
    set request_type = v_request_type,
        target_date = p_start_date,
        end_date = case when v_request_type = 'overtime' then p_start_date else coalesce(p_end_date,p_start_date) end,
        start_time = p_start_time,
        end_time = p_end_time,
        request_subtype = case when v_request_type = 'other_leave' then trim(coalesce(p_request_subtype,'')) else '' end,
        approved_minutes = 0,
        reason = trim(p_reason),
        status = 'pending',
        reviewer_id = null,
        reviewer_comment = '',
        reviewed_at = null
    where id = p_request_id;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
  )
  select
    attendance_record_id, employee_id, 'request_edited', 'attendance_request',
    v_before,
    jsonb_build_object(
      'request_type',request_type,
      'start_date',target_date,
      'end_date',end_date,
      'start_time',start_time,
      'end_time',end_time,
      'subtype',request_subtype,
      'value',requested_value,
      'reason',reason,
      'status',status
    )::text,
    trim(p_reason), auth.uid(), v_role, id
  from public.correction_requests
  where id = p_request_id;
end $$;

revoke all on function public.admin_update_attendance_request(uuid,date,date,time,time,text,text,text,text) from public, anon;
grant execute on function public.admin_update_attendance_request(uuid,date,date,time,time,text,text,text,text) to authenticated;

notify pgrst, 'reload schema';

commit;
