begin;

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
  v_actor_org_id uuid := public.current_profile_org_id();
  v_employee_org_id uuid;
  v_record public.attendance_records;
  v_record_id uuid;
  v_clock_in timestamptz;
  v_clock_out timestamptz;
  v_was_deleted boolean := false;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_work_date is null or p_clock_in_time is null or p_clock_out_time is null then raise exception 'REQUIRED_VALUE_MISSING'; end if;
  if p_clock_out_time <= p_clock_in_time then raise exception 'INVALID_TIME_RANGE'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;

  select org_id into v_employee_org_id
  from public.profiles
  where id = p_employee_id and role in ('employee','team_lead') and is_active = true;
  if not found or v_employee_org_id is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_employee_org_id is distinct from v_actor_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if exists (
    select 1 from public.monthly_closings
    where org_id = v_employee_org_id
      and year = extract(year from p_work_date)
      and month = extract(month from p_work_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

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
    set org_id = v_employee_org_id, work_type = 'office', clock_in_at = v_clock_in, clock_out_at = v_clock_out,
        clock_in_accuracy = null, clock_in_distance = null, clock_in_location_status = 'not_checked',
        clock_in_ip_address = null, clock_in_ip_matched = false,
        clock_out_accuracy = null, clock_out_distance = null, clock_out_location_status = 'not_checked',
        clock_out_ip_address = null, clock_out_ip_matched = false,
        attendance_status = 'normal', leave_type = 'none',
        note = '관리자 직접 추가: ' || trim(p_reason), changed = true,
        deleted_at = null, deleted_by = null, deletion_reason = '', updated_at = now()
    where id = v_record.id returning id into v_record_id;
  else
    insert into public.attendance_records (
      employee_id, org_id, work_date, work_type, clock_in_at, clock_out_at,
      clock_in_location_status, clock_out_location_status,
      attendance_status, leave_type, note, changed
    ) values (
      p_employee_id, v_employee_org_id, p_work_date, 'office', v_clock_in, v_clock_out,
      'not_checked', 'not_checked', 'normal', 'none',
      '관리자 직접 추가: ' || trim(p_reason), true
    ) returning id into v_record_id;
  end if;

  select * into v_record from public.attendance_records where id = v_record_id;
  update public.attendance_records
  set attendance_status = public.derive_attendance_status(v_record), updated_at = now()
  where id = v_record_id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, org_id
  ) values (
    v_record_id, p_employee_id, 'admin_create', 'attendance_record',
    case when v_was_deleted then '삭제된 기록' else '기록 없음' end,
    jsonb_build_object('work_date',p_work_date,'clock_in_time',p_clock_in_time,
      'clock_out_time',p_clock_out_time,'location','관리자 직접 등록, 위치 미확인')::text,
    trim(p_reason), auth.uid(), v_role, v_employee_org_id
  );
  return v_record_id;
end $$;

create or replace function public.admin_create_attendance_records(
  p_employee_ids uuid[],
  p_work_date date,
  p_clock_in_time time,
  p_clock_out_time time,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_employee_id uuid;
  v_employee_name text;
  v_created integer := 0;
  v_skipped_names text[] := array[]::text[];
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if coalesce(array_length(p_employee_ids,1),0) = 0 then raise exception 'EMPLOYEE_REQUIRED'; end if;
  if p_work_date is null or p_clock_in_time is null or p_clock_out_time is null then raise exception 'REQUIRED_VALUE_MISSING'; end if;
  if p_clock_out_time <= p_clock_in_time then raise exception 'INVALID_TIME_RANGE'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;

  foreach v_employee_id in array p_employee_ids loop
    select name into v_employee_name from public.profiles where id = v_employee_id and role in ('employee','team_lead') and is_active = true;
    if not found then
      v_skipped_names := array_append(v_skipped_names, '비활성 또는 미확인 직원');
    elsif exists (select 1 from public.attendance_records where employee_id = v_employee_id and work_date = p_work_date and deleted_at is null) then
      v_skipped_names := array_append(v_skipped_names, v_employee_name);
    else
      perform public.admin_create_attendance_record(v_employee_id,p_work_date,p_clock_in_time,p_clock_out_time,p_reason);
      v_created := v_created + 1;
    end if;
  end loop;
  return jsonb_build_object('created_count',v_created,'skipped_count',coalesce(array_length(v_skipped_names,1),0),'skipped_names',to_jsonb(v_skipped_names));
end $$;

revoke all on function public.admin_create_attendance_record(uuid,date,time,time,text) from public,anon;
revoke all on function public.admin_create_attendance_records(uuid[],date,time,time,text) from public,anon;
grant execute on function public.admin_create_attendance_record(uuid,date,time,time,text) to authenticated;
grant execute on function public.admin_create_attendance_records(uuid[],date,time,time,text) to authenticated;

notify pgrst, 'reload schema';
commit;
