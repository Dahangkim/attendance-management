begin;

do $$
declare
  v_constraint record;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.correction_requests'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%status%pending%approved%rejected%more_info%'
  loop
    execute format('alter table public.correction_requests drop constraint %I', v_constraint.conname);
  end loop;
end $$;

alter table public.correction_requests
  add constraint correction_requests_status_check
  check (status in ('pending','approved','rejected','more_info','cancelled'));

create or replace function public.employee_cancel_emergency_support_work(
  p_request_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_actor public.profiles;
begin
  select * into v_actor from public.profiles where id = auth.uid() and role in ('employee','team_lead') and is_active = true;
  if not found then raise exception 'EMPLOYEE_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_request from public.correction_requests
  where id = p_request_id and employee_id = auth.uid() and request_type = 'emergency_support'
  for update;
  if not found then raise exception 'EMERGENCY_SUPPORT_NOT_FOUND'; end if;
  if v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_CANCELLABLE'; end if;

  update public.correction_requests
  set status = 'cancelled', approved_minutes = 0, reviewer_id = null,
      reviewer_comment = '활동가 취소: ' || trim(p_reason), reviewed_at = now()
  where id = p_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,correction_request_id,org_id
  ) values (
    v_request.attendance_record_id,v_request.employee_id,'emergency_support_cancelled','emergency_support',
    jsonb_build_object('status',v_request.status,'start_date',v_request.target_date,'end_date',v_request.end_date,'start_time',v_request.start_time,'end_time',v_request.end_time)::text,
    jsonb_build_object('status','cancelled')::text,trim(p_reason),auth.uid(),v_actor.role,v_request.id,v_request.org_id
  );
end $$;

create or replace function public.update_emergency_support_work(
  p_request_id uuid,
  p_start_date date,
  p_end_date date,
  p_start_time time,
  p_end_time time,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_actor public.profiles;
  v_before text;
  v_is_admin boolean;
begin
  select * into v_actor from public.profiles where id = auth.uid() and is_active = true;
  if not found then raise exception 'AUTH_REQUIRED'; end if;
  v_is_admin := v_actor.role in ('admin','org_admin','super_admin');
  if not v_is_admin and v_actor.role not in ('employee','team_lead') then raise exception 'ACCESS_DENIED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  if p_start_date is null or p_start_time is null then raise exception 'START_REQUIRED'; end if;
  if (p_end_date is null) <> (p_end_time is null) then raise exception 'END_DATE_TIME_PAIR_REQUIRED'; end if;

  select * into v_request from public.correction_requests
  where id = p_request_id and request_type = 'emergency_support'
  for update;
  if not found then raise exception 'EMERGENCY_SUPPORT_NOT_FOUND'; end if;
  if v_request.status not in ('pending','more_info','rejected') then raise exception 'REQUEST_NOT_EDITABLE'; end if;
  if not v_is_admin and v_request.employee_id <> auth.uid() then raise exception 'ACCESS_DENIED'; end if;
  if v_is_admin and v_actor.role <> 'super_admin' and v_request.org_id is distinct from v_actor.org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if exists (
    select 1 from public.monthly_closings
    where org_id = v_request.org_id and year = extract(year from v_request.target_date)
      and month = extract(month from v_request.target_date) and status = 'closed'
  ) and v_actor.role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if p_end_date is not null then
    perform public.calculate_emergency_support_minutes(p_start_date,p_end_date,p_start_time,p_end_time);
  end if;

  v_before := jsonb_build_object('status',v_request.status,'start_date',v_request.target_date,'end_date',v_request.end_date,'start_time',v_request.start_time,'end_time',v_request.end_time,'reason',v_request.reason)::text;
  update public.correction_requests
  set target_date = p_start_date, end_date = p_end_date, start_time = p_start_time, end_time = p_end_time,
      reason = trim(p_reason), status = 'pending', approved_minutes = 0,
      reviewer_id = null, reviewer_comment = '', reviewed_at = null,
      requested_at = case when v_is_admin then requested_at else now() end
  where id = p_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,correction_request_id,org_id
  )
  select attendance_record_id,employee_id,
    case when v_is_admin then 'emergency_support_admin_updated' else 'emergency_support_employee_updated' end,
    'emergency_support',v_before,
    jsonb_build_object('status',status,'start_date',target_date,'end_date',end_date,'start_time',start_time,'end_time',end_time,'minutes',calculated_minutes,'reason',reason)::text,
    trim(p_reason),auth.uid(),v_actor.role,id,org_id
  from public.correction_requests where id = p_request_id;
end $$;

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
  if p_decision = 'approved' and (v_request.end_date is null or v_request.end_time is null or coalesce(v_request.calculated_minutes,0) <= 0) then raise exception 'EMERGENCY_SUPPORT_NOT_FINISHED'; end if;
  if v_role <> 'super_admin' and v_request.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if exists (select 1 from public.monthly_closings where org_id = v_request.org_id and year = extract(year from v_request.target_date) and month = extract(month from v_request.target_date) and status = 'closed') and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  update public.correction_requests
  set status = p_decision, approved_minutes = case when p_decision = 'approved' then calculated_minutes else 0 end,
      reviewer_id = auth.uid(), reviewer_comment = coalesce(p_comment,''), reviewed_at = now()
  where id = p_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,correction_request_id,org_id
  ) values (
    v_request.attendance_record_id,v_request.employee_id,'emergency_support_review','emergency_support',v_request.status,
    jsonb_build_object('status',p_decision,'start_date',v_request.target_date,'end_date',v_request.end_date,'start_time',v_request.start_time,'end_time',v_request.end_time,'minutes',case when p_decision = 'approved' then v_request.calculated_minutes else 0 end)::text,
    coalesce(nullif(trim(p_comment),''),v_request.reason),auth.uid(),v_role,v_request.id,v_request.org_id
  );
end $$;

revoke all on function public.employee_cancel_emergency_support_work(uuid,text) from public, anon;
revoke all on function public.update_emergency_support_work(uuid,date,date,time,time,text) from public, anon;
grant execute on function public.employee_cancel_emergency_support_work(uuid,text) to authenticated;
grant execute on function public.update_emergency_support_work(uuid,date,date,time,time,text) to authenticated;

commit;
