begin;

alter table public.profiles
  add column if not exists can_view_reports boolean not null default false;

create or replace function public.admin_set_employee_active(
  p_employee_id uuid,
  p_active boolean
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_employee public.profiles;
begin
  if v_role <> 'super_admin' then raise exception 'SUPER_ADMIN_REQUIRED'; end if;
  select * into v_employee
  from public.profiles
  where id = p_employee_id and role = 'employee'
  for update;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_employee.is_active = p_active then return; end if;

  update public.profiles
  set is_active = p_active,
      can_view_reports = case when p_active then can_view_reports else false end,
      updated_at = now()
  where id = p_employee_id;

  insert into public.attendance_audit_logs (
    employee_id, action_type, changed_field, before_value, after_value,
    reason, changed_by, changed_by_role
  ) values (
    p_employee_id,
    case when p_active then 'employee_reactivated' else 'employee_deactivated' end,
    'is_active',
    v_employee.is_active::text,
    p_active::text,
    case when p_active then '직원 계정 재활성화' else '퇴사 처리, 로그인 목록 제외' end,
    auth.uid(), v_role
  );
end $$;

revoke all on function public.admin_set_employee_active(uuid,boolean) from public, anon;
grant execute on function public.admin_set_employee_active(uuid,boolean) to authenticated;

notify pgrst, 'reload schema';
commit;
