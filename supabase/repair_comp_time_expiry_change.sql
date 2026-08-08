-- 대체휴무 사용기한을 늘리거나 이전 날짜로 되돌릴 수 있게 보완한다.

begin;

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
  v_action_type text;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_credit from public.comp_time_credits where id = p_credit_id for update;
  if not found then raise exception 'CREDIT_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_credit.org_id is distinct from v_actor_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if p_new_expires_on < v_credit.source_date then raise exception 'EXPIRY_BEFORE_SOURCE_DATE'; end if;
  if p_new_expires_on = v_credit.expires_on then raise exception 'EXPIRY_UNCHANGED'; end if;
  v_action_type := case when p_new_expires_on > v_credit.expires_on then 'comp_time_expiry_extended' else 'comp_time_expiry_reverted' end;
  update public.comp_time_credits set expires_on = p_new_expires_on where id = p_credit_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,org_id
  ) values (
    v_credit.employee_id,v_action_type,'comp_time_expiry',
    v_credit.expires_on::text,p_new_expires_on::text,trim(p_reason),auth.uid(),v_role,v_credit.org_id
  );
end $$;

revoke all on function public.admin_extend_comp_time_credit(uuid,date,text) from public,anon;
grant execute on function public.admin_extend_comp_time_credit(uuid,date,text) to authenticated;

notify pgrst, 'reload schema';
commit;
