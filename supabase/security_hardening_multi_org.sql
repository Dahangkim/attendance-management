begin;

alter table public.profiles add column if not exists must_change_password boolean not null default true;
update public.profiles set must_change_password = true where is_active;

create or replace function public.complete_required_password_change()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  update public.profiles set must_change_password = false, updated_at = now() where id = auth.uid();
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
end $$;
revoke all on function public.complete_required_password_change() from public, anon;
grant execute on function public.complete_required_password_change() to authenticated;

-- 기관마다 독립적으로 관리하는 휴일입니다. 기존 휴일은 모든 기존 기관에 복사해
-- 전환 직후의 근태 판정이 달라지지 않게 합니다.
create table if not exists public.organization_holidays (
  org_id uuid not null references public.organizations(id) on delete cascade,
  holiday_date date not null,
  holiday_name text not null,
  is_paid_holiday boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (org_id, holiday_date)
);

insert into public.organization_holidays (org_id, holiday_date, holiday_name, is_paid_holiday)
select organization.id, holiday.holiday_date, holiday.holiday_name, holiday.is_paid_holiday
from public.organizations organization
cross join public.holidays holiday
on conflict (org_id, holiday_date) do nothing;

alter table public.organization_holidays enable row level security;

drop policy if exists "organization holidays read" on public.organization_holidays;
create policy "organization holidays read" on public.organization_holidays
for select to authenticated
using (org_id = public.current_profile_org_id() or public.is_super_admin());

drop policy if exists "organization admins manage holidays" on public.organization_holidays;
create policy "organization admins manage holidays" on public.organization_holidays
for all to authenticated
using (public.is_super_admin() or (org_id = public.current_profile_org_id() and public.current_profile_role() in ('admin','org_admin')))
with check (public.is_super_admin() or (org_id = public.current_profile_org_id() and public.current_profile_role() in ('admin','org_admin')));

grant select, insert, update, delete on public.organization_holidays to authenticated;

-- 기존 전역 휴일표는 과거 자료 보존용으로 남기되 최고관리자만 수정합니다.
drop policy if exists "authenticated read holidays" on public.holidays;
drop policy if exists "admin manages holidays" on public.holidays;
create policy "authenticated read statutory holidays" on public.holidays
for select to authenticated using (true);
create policy "super admin manages statutory holidays" on public.holidays
for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());

-- 기관별 설정과 마감 정보는 같은 기관 또는 최고관리자만 조회합니다.
drop policy if exists "authenticated read workplace summary" on public.workplaces;
drop policy if exists "admin manages workplaces" on public.workplaces;
drop policy if exists "organization workplace read" on public.workplaces;
drop policy if exists "organization admins manage workplaces" on public.workplaces;
create policy "organization workplace read" on public.workplaces
for select to authenticated
using (public.is_super_admin() or org_id = public.current_profile_org_id());
create policy "organization admins manage workplaces" on public.workplaces
for all to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());

drop policy if exists "authenticated read organization settings" on public.organization_settings;
drop policy if exists "admin manages organization settings" on public.organization_settings;
drop policy if exists "organization settings read" on public.organization_settings;
drop policy if exists "organization admins manage settings" on public.organization_settings;
create policy "organization settings read" on public.organization_settings
for select to authenticated
using (public.is_super_admin() or org_id = public.current_profile_org_id());
create policy "organization admins manage settings" on public.organization_settings
for all to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());

drop policy if exists "authenticated closing read" on public.monthly_closings;
drop policy if exists "organization closing read" on public.monthly_closings;
create policy "organization closing read" on public.monthly_closings
for select to authenticated
using (public.is_super_admin() or org_id = public.current_profile_org_id());

-- 호출한 기관관리자의 기관에 속한 활성 사업장 한 건만 변경합니다.
create or replace function public.save_workplace_settings(
  p_workplace_name text,
  p_latitude double precision,
  p_longitude double precision,
  p_allowed_radius_meters integer,
  p_low_accuracy_threshold_meters integer
) returns public.workplaces
language plpgsql security definer set search_path = public as $$
declare
  v_org_id uuid := public.current_profile_org_id();
  v_role text := public.current_profile_role();
  v_workplace public.workplaces;
begin
  if v_org_id is null or v_role <> 'super_admin' then raise exception 'SUPER_ADMIN_REQUIRED'; end if;
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then raise exception 'INVALID_COORDINATES'; end if;
  if p_allowed_radius_meters not between 10 and 5000 or p_low_accuracy_threshold_meters not between 10 and 5000 then raise exception 'INVALID_DISTANCE'; end if;

  update public.workplaces set
    workplace_name = trim(p_workplace_name), latitude = p_latitude, longitude = p_longitude,
    allowed_radius_meters = p_allowed_radius_meters,
    low_accuracy_threshold_meters = p_low_accuracy_threshold_meters,
    updated_at = now()
  where org_id = v_org_id and is_active
  returning * into v_workplace;

  if not found then
    insert into public.workplaces (
      org_id, workplace_name, latitude, longitude, allowed_radius_meters,
      low_accuracy_threshold_meters, is_active
    ) values (
      v_org_id, trim(p_workplace_name), p_latitude, p_longitude,
      p_allowed_radius_meters, p_low_accuracy_threshold_meters, true
    ) returning * into v_workplace;
  end if;
  return v_workplace;
end $$;

revoke all on function public.save_workplace_settings(text,double precision,double precision,integer,integer) from public, anon, authenticated;

-- 기관관리자는 자기 기관의 재직 직원에게만 조회 전용 부관리자 권한을 부여합니다.
create or replace function public.admin_set_report_viewer(
  p_employee_id uuid,
  p_enabled boolean
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_employee public.profiles;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  select * into v_employee
  from public.profiles
  where id = p_employee_id
    and role = 'employee'
    and is_active = true
    and (v_role = 'super_admin' or org_id = v_org_id)
  for update;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;

  update public.profiles
  set can_view_reports = p_enabled, updated_at = now()
  where id = p_employee_id and org_id = v_employee.org_id;

  insert into public.attendance_audit_logs (
    employee_id, action_type, changed_field, before_value, after_value,
    reason, changed_by, changed_by_role, org_id
  ) values (
    p_employee_id, 'report_viewer_changed', 'can_view_reports',
    v_employee.can_view_reports::text, p_enabled::text,
    case when p_enabled then '부관리자 조회 권한 부여' else '부관리자 조회 권한 해제' end,
    auth.uid(), v_role, v_employee.org_id
  );
end $$;

revoke all on function public.admin_set_report_viewer(uuid,boolean) from public, anon;
grant execute on function public.admin_set_report_viewer(uuid,boolean) to authenticated;

notify pgrst, 'reload schema';
commit;
