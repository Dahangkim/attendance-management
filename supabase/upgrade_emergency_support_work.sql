begin;

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
  p_start_date date,
  p_end_date date,
  p_start_time time,
  p_end_time time
) returns integer
language plpgsql immutable security definer set search_path = public as $$
declare v_minutes integer;
begin
  if p_start_date is null or p_end_date is null or p_start_time is null or p_end_time is null then raise exception 'TIME_REQUIRED'; end if;
  v_minutes := floor(extract(epoch from ((p_end_date + p_end_time) - (p_start_date + p_start_time))) / 60)::integer;
  if v_minutes <= 0 or v_minutes > 1440 then raise exception 'INVALID_EMERGENCY_SUPPORT_RANGE'; end if;
  return v_minutes;
end $$;

create or replace function public.prepare_emergency_support_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.request_type = 'emergency_support' then
    new.end_date := coalesce(new.end_date, new.target_date);
    new.calculated_minutes := public.calculate_emergency_support_minutes(new.target_date, new.end_date, new.start_time, new.end_time);
    new.requested_value := new.calculated_minutes::text;
    new.request_subtype := '긴급 내담자 지원';
  end if;
  return new;
end $$;

drop trigger if exists prepare_emergency_support_request_trigger on public.correction_requests;
create trigger prepare_emergency_support_request_trigger
before insert or update of target_date, end_date, start_time, end_time, request_type
on public.correction_requests
for each row execute function public.prepare_emergency_support_request();

create or replace function public.review_emergency_support_work(
  p_request_id uuid,
  p_decision text,
  p_comment text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected','more_info') then raise exception 'INVALID_DECISION'; end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_comment,''))) < 2 then raise exception 'COMMENT_REQUIRED'; end if;
  select * into v_request from public.correction_requests where id = p_request_id and request_type = 'emergency_support' for update;
  if not found or v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_REVIEWABLE'; end if;
  if v_role <> 'super_admin' and v_request.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if exists (
    select 1 from public.monthly_closings
    where org_id = v_request.org_id
      and year = extract(year from v_request.target_date)
      and month = extract(month from v_request.target_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  update public.correction_requests
  set status = p_decision,
      approved_minutes = case when p_decision = 'approved' then calculated_minutes else 0 end,
      reviewer_id = auth.uid(), reviewer_comment = coalesce(p_comment,''), reviewed_at = now()
  where id = p_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field, before_value, after_value,
    reason, changed_by, changed_by_role, correction_request_id, org_id
  ) values (
    v_request.attendance_record_id, v_request.employee_id, 'emergency_support_review', 'emergency_support',
    v_request.status,
    jsonb_build_object('status',p_decision,'start_date',v_request.target_date,'end_date',v_request.end_date,'start_time',v_request.start_time,'end_time',v_request.end_time,'minutes',case when p_decision = 'approved' then v_request.calculated_minutes else 0 end)::text,
    coalesce(nullif(trim(p_comment),''),v_request.reason), auth.uid(), v_role, v_request.id, v_request.org_id
  );
end $$;

create or replace function public.admin_create_emergency_support_work(
  p_employee_id uuid,
  p_start_date date,
  p_end_date date,
  p_start_time time,
  p_end_time time,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_employee_org_id uuid;
  v_minutes integer;
  v_request_id uuid;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select org_id into v_employee_org_id from public.profiles where id = p_employee_id and role = 'employee' and is_active = true;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_employee_org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  v_minutes := public.calculate_emergency_support_minutes(p_start_date,p_end_date,p_start_time,p_end_time);

  insert into public.correction_requests (
    employee_id, target_date, end_date, start_time, end_time, request_type, request_subtype,
    before_value, requested_value, calculated_minutes, approved_minutes, reason, status,
    reviewer_id, reviewer_comment, reviewed_at, org_id
  ) values (
    p_employee_id,p_start_date,p_end_date,p_start_time,p_end_time,'emergency_support','긴급 내담자 지원',
    '관리자 직접 등록',v_minutes::text,v_minutes,v_minutes,trim(p_reason),'approved',
    auth.uid(),'관리자 직접 확인 등록',now(),v_employee_org_id
  ) returning id into v_request_id;

  insert into public.attendance_audit_logs (
    employee_id, action_type, changed_field, before_value, after_value, reason,
    changed_by, changed_by_role, correction_request_id, org_id
  ) values (
    p_employee_id,'emergency_support_created','emergency_support','없음',
    jsonb_build_object('status','approved','start_date',p_start_date,'end_date',p_end_date,'start_time',p_start_time,'end_time',p_end_time,'minutes',v_minutes)::text,
    trim(p_reason),auth.uid(),v_role,v_request_id,v_employee_org_id
  );
  return v_request_id;
end $$;

revoke all on function public.calculate_emergency_support_minutes(date,date,time,time) from public, anon;
revoke all on function public.review_emergency_support_work(uuid,text,text) from public, anon;
revoke all on function public.admin_create_emergency_support_work(uuid,date,date,time,time,text) from public, anon;
grant execute on function public.calculate_emergency_support_minutes(date,date,time,time) to authenticated;
grant execute on function public.review_emergency_support_work(uuid,text,text) to authenticated;
grant execute on function public.admin_create_emergency_support_work(uuid,date,date,time,time,text) to authenticated;

commit;
