-- 수기로 등록한 대체휴무 적립내역을 기관관리자가 수정, 삭제할 수 있게 한다.
-- 시간외근무 승인으로 자동 생성된 적립내역은 변경하지 않는다.

begin;

create or replace function public.admin_update_comp_time_credit(
  p_credit_id uuid,
  p_minutes integer,
  p_source_date date,
  p_expires_on date,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_actor_org_id uuid := public.current_profile_org_id();
  v_credit public.comp_time_credits;
  v_used_minutes integer;
  v_before text;
  v_after text;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_minutes < 30 or p_minutes % 30 <> 0 then raise exception 'INVALID_COMP_TIME_MINUTES'; end if;
  if p_source_date is null or p_expires_on < p_source_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;

  select * into v_credit from public.comp_time_credits where id = p_credit_id for update;
  if not found then raise exception 'CREDIT_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_credit.org_id is distinct from v_actor_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if v_credit.source_type not in ('opening_balance','admin_adjustment') then raise exception 'AUTOMATIC_CREDIT_READ_ONLY'; end if;
  v_used_minutes := greatest(0, v_credit.granted_minutes - v_credit.remaining_minutes);
  if p_minutes < v_used_minutes then raise exception 'MINUTES_BELOW_USED'; end if;
  v_before := to_jsonb(v_credit)::text;

  update public.comp_time_credits
  set granted_minutes = p_minutes,
      remaining_minutes = p_minutes - v_used_minutes,
      source_date = p_source_date,
      expires_on = p_expires_on,
      reason = trim(p_reason)
  where id = p_credit_id;

  select to_jsonb(credit)::text into v_after from public.comp_time_credits credit where id = p_credit_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,org_id
  ) values (
    v_credit.employee_id,'comp_time_credit_updated','comp_time_balance',v_before,v_after,
    trim(p_reason),auth.uid(),v_role,v_credit.org_id
  );
end $$;

create or replace function public.admin_delete_comp_time_credit(
  p_credit_id uuid,
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
  if v_credit.source_type not in ('opening_balance','admin_adjustment') then raise exception 'AUTOMATIC_CREDIT_READ_ONLY'; end if;
  if v_credit.remaining_minutes <> v_credit.granted_minutes
     or exists (select 1 from public.comp_time_usage_allocations where credit_id = p_credit_id)
  then raise exception 'USED_CREDIT_CANNOT_DELETE'; end if;

  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,org_id
  ) values (
    v_credit.employee_id,'comp_time_credit_deleted','comp_time_balance',
    to_jsonb(v_credit)::text,'삭제',trim(p_reason),auth.uid(),v_role,v_credit.org_id
  );
  delete from public.comp_time_credits where id = p_credit_id;
end $$;

revoke all on function public.admin_update_comp_time_credit(uuid,integer,date,date,text) from public,anon;
grant execute on function public.admin_update_comp_time_credit(uuid,integer,date,date,text) to authenticated;
revoke all on function public.admin_delete_comp_time_credit(uuid,text) from public,anon;
grant execute on function public.admin_delete_comp_time_credit(uuid,text) to authenticated;

notify pgrst, 'reload schema';
commit;
