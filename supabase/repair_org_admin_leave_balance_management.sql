-- 기관관리자가 자기 기관 직원의 연차와 대휴 잔액을 관리할 수 있게 보완한다.
-- 다른 기관의 직원, 부여내역, 적립내역은 수정할 수 없다.

begin;

create or replace function public.admin_save_annual_leave_entitlement(
  p_entitlement_id uuid,
  p_employee_id uuid,
  p_valid_from date,
  p_valid_to date,
  p_base_minutes integer,
  p_carryover_minutes integer,
  p_adjustment_minutes integer,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_actor_org_id uuid := public.current_profile_org_id();
  v_employee_org_id uuid;
  v_id uuid;
  v_before text := '';
  v_after text;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  select org_id into v_employee_org_id
  from public.profiles
  where id = p_employee_id and role = 'employee' and is_active = true;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_employee_org_id is distinct from v_actor_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if p_valid_to < p_valid_from then raise exception 'INVALID_DATE_RANGE'; end if;
  if coalesce(p_base_minutes,0) < 0 or coalesce(p_carryover_minutes,0) < 0
     or coalesce(p_base_minutes,0) + coalesce(p_carryover_minutes,0) + coalesce(p_adjustment_minutes,0) < 0
     or coalesce(p_base_minutes,0) % 60 <> 0 or coalesce(p_carryover_minutes,0) % 60 <> 0
     or coalesce(p_adjustment_minutes,0) % 60 <> 0 then raise exception 'INVALID_LEAVE_MINUTES'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  if exists (
    select 1 from public.annual_leave_entitlements
    where employee_id = p_employee_id and org_id = v_employee_org_id and deleted_at is null
      and id <> coalesce(p_entitlement_id,'00000000-0000-0000-0000-000000000000'::uuid)
      and valid_from <= p_valid_to and valid_to >= p_valid_from
  ) then raise exception 'ANNUAL_LEAVE_PERIOD_OVERLAP'; end if;

  if p_entitlement_id is null then
    insert into public.annual_leave_entitlements (
      employee_id,org_id,valid_from,valid_to,base_minutes,carryover_minutes,
      adjustment_minutes,reason,created_by
    ) values (
      p_employee_id,v_employee_org_id,p_valid_from,p_valid_to,p_base_minutes,p_carryover_minutes,
      p_adjustment_minutes,trim(p_reason),auth.uid()
    ) returning id into v_id;
  else
    select to_jsonb(entitlement)::text into v_before
    from public.annual_leave_entitlements entitlement
    where id = p_entitlement_id and employee_id = p_employee_id and org_id = v_employee_org_id and deleted_at is null
    for update;
    if not found then raise exception 'ENTITLEMENT_NOT_FOUND'; end if;
    update public.annual_leave_entitlements
    set valid_from = p_valid_from, valid_to = p_valid_to,
        base_minutes = p_base_minutes, carryover_minutes = p_carryover_minutes,
        adjustment_minutes = p_adjustment_minutes, reason = trim(p_reason), updated_at = now()
    where id = p_entitlement_id returning id into v_id;
  end if;

  select to_jsonb(entitlement)::text into v_after
  from public.annual_leave_entitlements entitlement where id = v_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,org_id
  ) values (
    p_employee_id,'annual_leave_entitlement_saved','annual_leave_balance',
    v_before,v_after,trim(p_reason),auth.uid(),v_role,v_employee_org_id
  );
  return v_id;
end $$;

create or replace function public.admin_delete_annual_leave_entitlement(
  p_entitlement_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_actor_org_id uuid := public.current_profile_org_id();
  v_entitlement public.annual_leave_entitlements;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_entitlement from public.annual_leave_entitlements
  where id = p_entitlement_id and deleted_at is null for update;
  if not found then raise exception 'ENTITLEMENT_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_entitlement.org_id is distinct from v_actor_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  update public.annual_leave_entitlements
  set deleted_at = now(),deleted_by = auth.uid(),delete_reason = trim(p_reason),updated_at = now()
  where id = p_entitlement_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,org_id
  ) values (
    v_entitlement.employee_id,'annual_leave_entitlement_deleted','annual_leave_balance',
    to_jsonb(v_entitlement)::text,'삭제 처리',trim(p_reason),auth.uid(),v_role,v_entitlement.org_id
  );
end $$;

create or replace function public.admin_add_comp_time_credit(
  p_employee_id uuid,
  p_minutes integer,
  p_source_date date,
  p_expires_on date,
  p_source_type text,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_actor_org_id uuid := public.current_profile_org_id();
  v_employee_org_id uuid;
  v_id uuid;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  select org_id into v_employee_org_id from public.profiles
  where id = p_employee_id and role = 'employee' and is_active = true;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_employee_org_id is distinct from v_actor_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if p_minutes < 30 or p_minutes % 30 <> 0 then raise exception 'INVALID_COMP_TIME_MINUTES'; end if;
  if p_source_date is null or p_expires_on < p_source_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_source_type not in ('opening_balance','admin_adjustment') then raise exception 'INVALID_SOURCE_TYPE'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  insert into public.comp_time_credits (
    attendance_record_id,employee_id,org_id,granted_minutes,remaining_minutes,
    expires_on,granted_by,reason,source_type,source_date
  ) values (
    null,p_employee_id,v_employee_org_id,p_minutes,p_minutes,p_expires_on,
    auth.uid(),trim(p_reason),p_source_type,p_source_date
  ) returning id into v_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,org_id
  ) values (
    p_employee_id,'comp_time_credit_added','comp_time_balance','',
    jsonb_build_object('minutes',p_minutes,'source_date',p_source_date,'expires_on',p_expires_on,'source_type',p_source_type)::text,
    trim(p_reason),auth.uid(),v_role,v_employee_org_id
  );
  return v_id;
end $$;

create or replace function public.admin_extend_comp_time_credit(
  p_credit_id uuid,
  p_new_expires_on date,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_actor_org_id uuid := public.current_profile_org_id();
  v_credit public.comp_time_credits;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_credit from public.comp_time_credits where id = p_credit_id for update;
  if not found then raise exception 'CREDIT_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_credit.org_id is distinct from v_actor_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if p_new_expires_on <= v_credit.expires_on then raise exception 'EXPIRY_MUST_EXTEND'; end if;
  update public.comp_time_credits set expires_on = p_new_expires_on where id = p_credit_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,org_id
  ) values (
    v_credit.employee_id,'comp_time_expiry_extended','comp_time_expiry',
    v_credit.expires_on::text,p_new_expires_on::text,trim(p_reason),auth.uid(),v_role,v_credit.org_id
  );
end $$;

revoke all on function public.admin_save_annual_leave_entitlement(uuid,uuid,date,date,integer,integer,integer,text) from public,anon;
grant execute on function public.admin_save_annual_leave_entitlement(uuid,uuid,date,date,integer,integer,integer,text) to authenticated;
revoke all on function public.admin_delete_annual_leave_entitlement(uuid,text) from public,anon;
grant execute on function public.admin_delete_annual_leave_entitlement(uuid,text) to authenticated;
revoke all on function public.admin_add_comp_time_credit(uuid,integer,date,date,text,text) from public,anon;
grant execute on function public.admin_add_comp_time_credit(uuid,integer,date,date,text,text) to authenticated;
revoke all on function public.admin_extend_comp_time_credit(uuid,date,text) from public,anon;
grant execute on function public.admin_extend_comp_time_credit(uuid,date,text) to authenticated;

commit;
