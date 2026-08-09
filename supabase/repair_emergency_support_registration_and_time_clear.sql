begin;

-- 보완 SQL이 나중에 실행되어도 긴급지원 유형이 다시 제외되지 않게 합니다.
do $$
declare v_constraint record;
begin
  for v_constraint in
    select conname from pg_constraint
    where conrelid = 'public.correction_requests'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%request_type%'
  loop
    execute format('alter table public.correction_requests drop constraint %I', v_constraint.conname);
  end loop;
end $$;

alter table public.correction_requests
  add constraint correction_requests_request_type_check
  check (request_type in (
    'clock_in_at','clock_out_at','annual_leave','comp_time','sick_leave','special_leave',
    'business_trip','overtime','emergency_support','other_leave','work_type','note','attendance_status'
  )) not valid;

create or replace function public.calculate_emergency_support_minutes(
  p_start_date date, p_end_date date, p_start_time time, p_end_time time
) returns integer
language plpgsql immutable security definer set search_path = public as $$
declare v_minutes integer;
begin
  if p_start_date is null or p_end_date is null or p_start_time is null or p_end_time is null then
    raise exception 'TIME_REQUIRED';
  end if;
  v_minutes := floor(extract(epoch from ((p_end_date + p_end_time) - (p_start_date + p_start_time))) / 60)::integer;
  if v_minutes <= 0 or v_minutes > 1440 then raise exception 'INVALID_EMERGENCY_SUPPORT_RANGE'; end if;
  return v_minutes;
end $$;

create or replace function public.emergency_support_time_overlaps(
  p_employee_id uuid, p_start_date date, p_end_date date,
  p_start_time time, p_end_time time, p_exclude_request_id uuid default null
) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.correction_requests request
    where request.employee_id = p_employee_id
      and request.request_type = 'emergency_support'
      and request.status not in ('rejected','cancelled')
      and request.end_date is not null and request.end_time is not null
      and request.id is distinct from p_exclude_request_id
      and (request.target_date + request.start_time) < (p_end_date + p_end_time)
      and (p_start_date + p_start_time) < (request.end_date + request.end_time)
  );
$$;

create or replace function public.admin_create_emergency_support_work(
  p_employee_id uuid, p_start_date date, p_end_date date,
  p_start_time time, p_end_time time, p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_employee_org_id uuid;
  v_minutes integer;
  v_request_id uuid;
  v_record_id uuid;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select org_id into v_employee_org_id from public.profiles
  where id = p_employee_id and role in ('employee','team_lead') and is_active = true;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_employee_org_id is distinct from v_org_id then
    raise exception 'ORGANIZATION_ACCESS_DENIED';
  end if;
  if exists (
    select 1 from public.monthly_closings
    where org_id = v_employee_org_id
      and year = extract(year from p_start_date)
      and month = extract(month from p_start_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  v_minutes := public.calculate_emergency_support_minutes(p_start_date,p_end_date,p_start_time,p_end_time);
  if public.emergency_support_time_overlaps(p_employee_id,p_start_date,p_end_date,p_start_time,p_end_time,null) then
    raise exception 'EMERGENCY_SUPPORT_TIME_OVERLAP';
  end if;

  -- 일반 출퇴근과 긴급지원은 별개이며, 같은 날짜 기록은 변경이력 연결에만 사용합니다.
  select id into v_record_id from public.attendance_records
  where employee_id = p_employee_id and org_id = v_employee_org_id
    and work_date = p_start_date and deleted_at is null
  order by created_at desc limit 1;

  insert into public.correction_requests (
    attendance_record_id,employee_id,target_date,end_date,start_time,end_time,
    request_type,request_subtype,before_value,requested_value,calculated_minutes,
    approved_minutes,reason,status,reviewer_id,reviewer_comment,reviewed_at,org_id
  ) values (
    v_record_id,p_employee_id,p_start_date,p_end_date,p_start_time,p_end_time,
    'emergency_support','긴급 내담자 지원','관리자 직접 등록',v_minutes::text,v_minutes,
    v_minutes,trim(p_reason),'approved',auth.uid(),'관리자 직접 확인 등록',now(),v_employee_org_id
  ) returning id into v_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,correction_request_id,org_id
  ) values (
    v_record_id,p_employee_id,'emergency_support_created','emergency_support','없음',
    jsonb_build_object('status','approved','start_date',p_start_date,'end_date',p_end_date,
      'start_time',p_start_time,'end_time',p_end_time,'minutes',v_minutes)::text,
    trim(p_reason),auth.uid(),v_role,v_request_id,v_employee_org_id
  );
  return v_request_id;
end $$;

create or replace function public.admin_update_attendance(
  p_record_id uuid, p_clock_in_time time, p_clock_out_time time,
  p_work_type text, p_attendance_status text, p_note text, p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_before text;
  v_after text;
  v_clock_in timestamptz;
  v_clock_out timestamptz;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records
  where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_record.org_id is distinct from v_org_id then
    raise exception 'ORGANIZATION_ACCESS_DENIED';
  end if;
  if exists (
    select 1 from public.monthly_closings
    where org_id = v_record.org_id
      and year = extract(year from v_record.work_date)
      and month = extract(month from v_record.work_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  v_clock_in := case when p_clock_in_time is null then null
    else (v_record.work_date + p_clock_in_time) at time zone 'Asia/Seoul' end;
  v_clock_out := case when p_clock_out_time is null then null
    else (v_record.work_date + p_clock_out_time) at time zone 'Asia/Seoul' end;
  if v_clock_out is not null and v_clock_in is null then raise exception 'CLOCK_IN_REQUIRED'; end if;
  if v_clock_out = v_clock_in then raise exception 'INVALID_TIME_RANGE'; end if;
  if v_clock_out is not null and v_clock_out < v_clock_in then v_clock_out := v_clock_out + interval '1 day'; end if;

  v_before := jsonb_build_object('clock_in_at',v_record.clock_in_at,'clock_out_at',v_record.clock_out_at,
    'work_type',v_record.work_type,'attendance_status',v_record.attendance_status,'note',v_record.note)::text;
  update public.attendance_records set
    clock_in_at = v_clock_in, clock_out_at = v_clock_out,
    clock_in_accuracy = case when v_clock_in is null then null else clock_in_accuracy end,
    clock_in_distance = case when v_clock_in is null then null else clock_in_distance end,
    clock_in_location_status = case when v_clock_in is null then 'not_checked' else clock_in_location_status end,
    clock_in_ip_address = case when v_clock_in is null then null else clock_in_ip_address end,
    clock_in_ip_matched = case when v_clock_in is null then false else clock_in_ip_matched end,
    clock_out_accuracy = case when v_clock_out is null then null else clock_out_accuracy end,
    clock_out_distance = case when v_clock_out is null then null else clock_out_distance end,
    clock_out_location_status = case when v_clock_out is null then 'not_checked' else clock_out_location_status end,
    clock_out_ip_address = case when v_clock_out is null then null else clock_out_ip_address end,
    clock_out_ip_matched = case when v_clock_out is null then false else clock_out_ip_matched end,
    work_type = p_work_type,
    attendance_status = case
      when v_clock_in is null and exists (
        select 1 from public.correction_requests r
        where r.employee_id = v_record.employee_id and r.request_type = 'emergency_support'
          and r.status = 'approved' and r.target_date = v_record.work_date
      ) then 'holiday_work'
      when v_clock_in is null and exists (
        select 1 from public.correction_requests r
        where r.employee_id = v_record.employee_id
          and r.request_type in ('annual_leave','comp_time','sick_leave','special_leave','other_leave')
          and r.status = 'approved' and r.target_date <= v_record.work_date
          and coalesce(r.end_date,r.target_date) >= v_record.work_date
      ) then 'leave'
      when v_clock_in is null then 'missing_in'
      when v_clock_out is null and v_record.work_date < (now() at time zone 'Asia/Seoul')::date then 'missing_out'
      when v_clock_out is null then 'working'
      else p_attendance_status
    end,
    note = coalesce(p_note,''), changed = true, is_closed = false, updated_at = now()
  where id = p_record_id
  returning jsonb_build_object('clock_in_at',clock_in_at,'clock_out_at',clock_out_at,
    'work_type',work_type,'attendance_status',attendance_status,'note',note)::text into v_after;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,org_id
  ) values (
    v_record.id,v_record.employee_id,'admin_update','attendance_record',v_before,v_after,
    trim(p_reason),auth.uid(),v_role,v_record.org_id
  );
end $$;

-- 이전 버전에서 시각만 삭제되어 남은 위치 정보를 한 번 정리한다.
update public.attendance_records set
  clock_in_accuracy = null,
  clock_in_distance = null,
  clock_in_location_status = 'not_checked',
  clock_in_ip_address = null,
  clock_in_ip_matched = false
where clock_in_at is null
  and (clock_in_accuracy is not null or clock_in_distance is not null
    or clock_in_location_status <> 'not_checked' or clock_in_ip_address is not null
    or clock_in_ip_matched is true);

update public.attendance_records set
  clock_out_accuracy = null,
  clock_out_distance = null,
  clock_out_location_status = 'not_checked',
  clock_out_ip_address = null,
  clock_out_ip_matched = false
where clock_out_at is null
  and (clock_out_accuracy is not null or clock_out_distance is not null
    or clock_out_location_status <> 'not_checked' or clock_out_ip_address is not null
    or clock_out_ip_matched is true);

create or replace function public.cleanup_attendance_events_after_time_clear()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.clock_in_at is not null and new.clock_in_at is null then
    delete from public.attendance_events
    where employee_id = new.employee_id and work_date = new.work_date
      and action_type in ('clock_in','clock_out');
  elsif old.clock_out_at is not null and new.clock_out_at is null then
    delete from public.attendance_events
    where employee_id = new.employee_id and work_date = new.work_date and action_type = 'clock_out';
  end if;
  return new;
end $$;

drop trigger if exists attendance_cleanup_events_after_time_clear on public.attendance_records;
create trigger attendance_cleanup_events_after_time_clear
after update of clock_in_at,clock_out_at on public.attendance_records
for each row
when (old.clock_in_at is distinct from new.clock_in_at or old.clock_out_at is distinct from new.clock_out_at)
execute function public.cleanup_attendance_events_after_time_clear();

revoke all on function public.calculate_emergency_support_minutes(date,date,time,time) from public,anon;
revoke all on function public.emergency_support_time_overlaps(uuid,date,date,time,time,uuid) from public,anon;
revoke all on function public.admin_create_emergency_support_work(uuid,date,date,time,time,text) from public,anon;
revoke all on function public.admin_update_attendance(uuid,time,time,text,text,text,text) from public,anon;
revoke all on function public.cleanup_attendance_events_after_time_clear() from public,anon,authenticated;
grant execute on function public.calculate_emergency_support_minutes(date,date,time,time) to authenticated;
grant execute on function public.admin_create_emergency_support_work(uuid,date,date,time,time,text) to authenticated;
grant execute on function public.admin_update_attendance(uuid,time,time,text,text,text,text) to authenticated;

notify pgrst, 'reload schema';
commit;

select '긴급지원 등록과 출퇴근시각 삭제 보완 완료' as result;
