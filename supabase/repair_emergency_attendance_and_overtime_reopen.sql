begin;

create or replace function public.emergency_support_time_overlaps(
  p_employee_id uuid,
  p_start_date date,
  p_end_date date,
  p_start_time time,
  p_end_time time,
  p_exclude_request_id uuid default null
) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.correction_requests request
    where request.employee_id = p_employee_id
      and request.request_type = 'emergency_support'
      and request.status not in ('rejected','cancelled')
      and request.end_date is not null
      and request.end_time is not null
      and request.id is distinct from p_exclude_request_id
      and (request.target_date + request.start_time) < (p_end_date + p_end_time)
      and (p_start_date + p_start_time) < (request.end_date + request.end_time)
  );
$$;

create or replace function public.prepare_emergency_support_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.request_type = 'emergency_support' then
    if new.end_date is null or new.end_time is null then
      new.calculated_minutes := 0;
      new.requested_value := '0';
      new.request_subtype := '긴급지원 진행 중';
    else
      if new.status = 'approved' and public.emergency_support_time_overlaps(new.employee_id,new.target_date,new.end_date,new.start_time,new.end_time,new.id) then
        raise exception 'EMERGENCY_SUPPORT_TIME_OVERLAP';
      end if;
      new.calculated_minutes := public.calculate_emergency_support_minutes(new.target_date,new.end_date,new.start_time,new.end_time);
      new.requested_value := new.calculated_minutes::text;
      new.request_subtype := '긴급 내담자 지원';
    end if;
  end if;
  return new;
end $$;

create or replace function public.start_emergency_support_work(p_reason text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_employee public.profiles;
  v_record public.attendance_records;
  v_now timestamptz := now();
  v_local timestamp := now() at time zone 'Asia/Seoul';
  v_request_id uuid;
begin
  select * into v_employee from public.profiles where id = auth.uid() and role in ('employee','team_lead') and is_active = true;
  if not found then raise exception 'EMPLOYEE_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  if exists (select 1 from public.correction_requests where employee_id = auth.uid() and request_type = 'emergency_support' and status in ('pending','more_info') and end_time is null) then raise exception 'EMERGENCY_SUPPORT_ALREADY_RUNNING'; end if;

  select * into v_record from public.attendance_records
  where employee_id = auth.uid() and org_id = v_employee.org_id
    and work_date = v_local::date and deleted_at is null
  order by coalesce(clock_out_at,clock_in_at) desc limit 1;

  insert into public.correction_requests (
    attendance_record_id,employee_id,target_date,end_date,start_time,end_time,
    request_type,request_subtype,before_value,requested_value,calculated_minutes,
    approved_minutes,reason,status,org_id
  ) values (
    v_record.id,auth.uid(),v_local::date,null,v_local::time,null,
    'emergency_support','긴급지원 진행 중','출퇴근과 별도로 긴급지원 시작','0',0,
    0,trim(p_reason),'pending',v_employee.org_id
  ) returning id into v_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,correction_request_id,org_id
  ) values (
    v_record.id,auth.uid(),'emergency_support_started','emergency_support','없음',
    jsonb_build_object('status','running','start_date',v_local::date,'start_time',v_local::time)::text,
    trim(p_reason),auth.uid(),v_employee.role,v_request_id,v_employee.org_id
  );
  return v_request_id;
end $$;

create or replace function public.finish_emergency_support_work(p_request_id uuid,p_completion_note text default '')
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_employee public.profiles;
  v_local timestamp := now() at time zone 'Asia/Seoul';
  v_minutes integer;
begin
  select * into v_employee from public.profiles where id = auth.uid() and role in ('employee','team_lead') and is_active = true;
  if not found then raise exception 'EMPLOYEE_REQUIRED'; end if;
  select * into v_request from public.correction_requests where id = p_request_id and employee_id = auth.uid() and request_type = 'emergency_support' for update;
  if not found then raise exception 'EMERGENCY_SUPPORT_NOT_FOUND'; end if;
  if v_request.status not in ('pending','more_info') or v_request.end_time is not null then raise exception 'EMERGENCY_SUPPORT_NOT_RUNNING'; end if;
  v_minutes := public.calculate_emergency_support_minutes(v_request.target_date,v_local::date,v_request.start_time,v_local::time);
  if public.emergency_support_time_overlaps(v_request.employee_id,v_request.target_date,v_local::date,v_request.start_time,v_local::time,v_request.id) then raise exception 'EMERGENCY_SUPPORT_TIME_OVERLAP'; end if;
  update public.correction_requests set end_date = v_local::date,end_time = v_local::time,request_subtype = '긴급 내담자 지원',
    reason = case when char_length(trim(coalesce(p_completion_note,''))) > 0 then reason || E'\n종료 메모: ' || trim(p_completion_note) else reason end,
    status = 'pending',reviewer_id = null,reviewer_comment = '',reviewed_at = null
  where id = p_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,correction_request_id,org_id
  ) values (
    v_request.attendance_record_id,auth.uid(),'emergency_support_finished','emergency_support',
    jsonb_build_object('status','running','start_date',v_request.target_date,'start_time',v_request.start_time)::text,
    jsonb_build_object('status','pending','start_date',v_request.target_date,'end_date',v_local::date,'start_time',v_request.start_time,'end_time',v_local::time,'minutes',v_minutes)::text,
    coalesce(nullif(trim(p_completion_note),''),v_request.reason),auth.uid(),v_employee.role,p_request_id,v_employee.org_id
  );
  return v_minutes;
end $$;

create or replace function public.review_emergency_support_work(p_request_id uuid,p_decision text,p_comment text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_record_id uuid;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected','more_info') then raise exception 'INVALID_DECISION'; end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_comment,''))) < 2 then raise exception 'COMMENT_REQUIRED'; end if;
  select * into v_request from public.correction_requests where id = p_request_id and request_type = 'emergency_support' for update;
  if not found or v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_REVIEWABLE'; end if;
  if v_request.end_date is null or v_request.end_time is null or coalesce(v_request.calculated_minutes,0) <= 0 then raise exception 'EMERGENCY_SUPPORT_NOT_FINISHED'; end if;
  if p_decision = 'approved' and public.emergency_support_time_overlaps(v_request.employee_id,v_request.target_date,v_request.end_date,v_request.start_time,v_request.end_time,v_request.id) then raise exception 'EMERGENCY_SUPPORT_TIME_OVERLAP'; end if;
  if v_role <> 'super_admin' and v_request.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if exists (select 1 from public.monthly_closings where org_id = v_request.org_id and year = extract(year from v_request.target_date) and month = extract(month from v_request.target_date) and status = 'closed') and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  update public.correction_requests set status = p_decision,approved_minutes = case when p_decision = 'approved' then calculated_minutes else 0 end,
    reviewer_id = auth.uid(),reviewer_comment = coalesce(p_comment,''),reviewed_at = now() where id = p_request_id;

  if p_decision = 'approved' then
    select id into v_record_id from public.attendance_records
    where employee_id = v_request.employee_id and org_id = v_request.org_id
      and work_date = v_request.target_date and deleted_at is null
    order by created_at desc limit 1;
    update public.correction_requests set attendance_record_id = v_record_id where id = p_request_id and v_record_id is not null;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,correction_request_id,org_id
  ) values (
    v_request.attendance_record_id,v_request.employee_id,'emergency_support_review','emergency_support',v_request.status,
    jsonb_build_object('status',p_decision,'start_date',v_request.target_date,'end_date',v_request.end_date,'start_time',v_request.start_time,'end_time',v_request.end_time,'minutes',case when p_decision = 'approved' then v_request.calculated_minutes else 0 end)::text,
    coalesce(nullif(trim(p_comment),''),v_request.reason),auth.uid(),v_role,v_request.id,v_request.org_id
  );
end $$;

create or replace function public.admin_reopen_overtime_review(p_record_id uuid,p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_credit public.comp_time_credits;
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.overtime_status not in ('approved','rejected') then raise exception 'OVERTIME_ALREADY_PENDING'; end if;
  if v_role <> 'super_admin' and v_record.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  select * into v_credit from public.comp_time_credits where attendance_record_id = v_record.id for update;
  if found and v_credit.granted_minutes > v_credit.remaining_minutes then raise exception 'COMP_TIME_ALREADY_USED'; end if;
  if found then delete from public.comp_time_credits where id = v_credit.id; end if;

  update public.attendance_records set overtime_status = 'pending',approved_overtime_minutes = 0,comp_time_eligible_minutes = 0,changed = true,updated_at = now() where id = v_record.id;
  update public.correction_requests set status = 'pending',approved_minutes = 0,reviewer_id = null,reviewer_comment = '',reviewed_at = null
  where attendance_record_id = v_record.id and request_type = 'overtime' and status in ('approved','rejected');
  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,org_id
  ) values (
    v_record.id,v_record.employee_id,'overtime_review_reopened','approved_overtime_minutes',
    jsonb_build_object('status',v_record.overtime_status,'minutes',v_record.approved_overtime_minutes,'comp_time_eligible_minutes',v_record.comp_time_eligible_minutes)::text,
    jsonb_build_object('status','pending','minutes',0,'comp_time_eligible_minutes',0)::text,
    trim(p_reason),auth.uid(),v_role,v_record.org_id
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
  v_record_id uuid;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select org_id into v_employee_org_id from public.profiles where id = p_employee_id and role in ('employee','team_lead') and is_active = true;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_employee_org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  v_minutes := public.calculate_emergency_support_minutes(p_start_date,p_end_date,p_start_time,p_end_time);
  if public.emergency_support_time_overlaps(p_employee_id,p_start_date,p_end_date,p_start_time,p_end_time,null) then raise exception 'EMERGENCY_SUPPORT_TIME_OVERLAP'; end if;

  select id into v_record_id from public.attendance_records
  where employee_id = p_employee_id and org_id = v_employee_org_id
    and work_date = p_start_date and deleted_at is null
  order by created_at desc limit 1;

  insert into public.correction_requests (
    attendance_record_id,employee_id,target_date,end_date,start_time,end_time,request_type,request_subtype,
    before_value,requested_value,calculated_minutes,approved_minutes,reason,status,
    reviewer_id,reviewer_comment,reviewed_at,org_id
  ) values (
    v_record_id,p_employee_id,p_start_date,p_end_date,p_start_time,p_end_time,'emergency_support','긴급 내담자 지원',
    '관리자 직접 등록',v_minutes::text,v_minutes,v_minutes,trim(p_reason),'approved',
    auth.uid(),'관리자 직접 확인 등록',now(),v_employee_org_id
  ) returning id into v_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,reason,
    changed_by,changed_by_role,correction_request_id,org_id
  ) values (
    v_record_id,p_employee_id,'emergency_support_created','emergency_support','없음',
    jsonb_build_object('status','approved','start_date',p_start_date,'end_date',p_end_date,
      'start_time',p_start_time,'end_time',p_end_time,'minutes',v_minutes)::text,
    trim(p_reason),auth.uid(),v_role,v_request_id,v_employee_org_id
  );
  return v_request_id;
end $$;

revoke all on function public.emergency_support_time_overlaps(uuid,date,date,time,time,uuid) from public,anon;
revoke all on function public.start_emergency_support_work(text) from public,anon;
revoke all on function public.finish_emergency_support_work(uuid,text) from public,anon;
revoke all on function public.review_emergency_support_work(uuid,text,text) from public,anon;
revoke all on function public.admin_reopen_overtime_review(uuid,text) from public,anon;
revoke all on function public.admin_create_emergency_support_work(uuid,date,date,time,time,text) from public,anon;
grant execute on function public.emergency_support_time_overlaps(uuid,date,date,time,time,uuid) to authenticated;
grant execute on function public.start_emergency_support_work(text) to authenticated;
grant execute on function public.finish_emergency_support_work(uuid,text) to authenticated;
grant execute on function public.review_emergency_support_work(uuid,text,text) to authenticated;
grant execute on function public.admin_reopen_overtime_review(uuid,text) to authenticated;
grant execute on function public.admin_create_emergency_support_work(uuid,date,date,time,time,text) to authenticated;

update public.correction_requests request
set attendance_record_id = record.id
from public.attendance_records record
where request.request_type = 'emergency_support'
  and request.employee_id = record.employee_id
  and request.org_id = record.org_id
  and request.target_date = record.work_date
  and record.deleted_at is null
  and request.attendance_record_id is null;

update public.attendance_records
set note = trim(regexp_replace(coalesce(note,''),'(^|\n)긴급지원[^\n]*','','g')),
    updated_at = now()
where note like '%긴급지원%';

notify pgrst, 'reload schema';
commit;
