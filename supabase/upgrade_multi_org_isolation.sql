-- 멀티 조직 전환 2단계: 조직별 데이터 격리와 RLS
-- upgrade_multi_org_foundation.sql 적용 후 실행한다.

begin;

create or replace function public.is_attendance_admin()
returns boolean language sql stable security definer set search_path = public
as $$
  select coalesce(public.current_profile_role() in ('admin','org_admin','team_lead','super_admin'), false)
$$;

alter table public.employee_schedule_overrides add column if not exists org_id uuid references public.organizations(id);
alter table public.attendance_locations add column if not exists org_id uuid references public.organizations(id);
alter table public.location_consents add column if not exists org_id uuid references public.organizations(id);
alter table public.attendance_events add column if not exists org_id uuid references public.organizations(id);
alter table public.attendance_exceptions add column if not exists org_id uuid references public.organizations(id);
alter table public.comp_time_credits add column if not exists org_id uuid references public.organizations(id);
alter table public.comp_time_usage_allocations add column if not exists org_id uuid references public.organizations(id);
alter table public.annual_leave_entitlements add column if not exists org_id uuid references public.organizations(id);

update public.employee_schedule_overrides item set org_id = profile.org_id
from public.profiles profile where profile.id = item.employee_id and item.org_id is null;
update public.attendance_locations item set org_id = profile.org_id
from public.profiles profile where profile.id = item.employee_id and item.org_id is null;
update public.location_consents item set org_id = profile.org_id
from public.profiles profile where profile.id = item.employee_id and item.org_id is null;
update public.attendance_events item set org_id = profile.org_id
from public.profiles profile where profile.id = item.employee_id and item.org_id is null;
update public.attendance_exceptions item set org_id = profile.org_id
from public.profiles profile where profile.id = item.employee_id and item.org_id is null;
update public.comp_time_credits item set org_id = profile.org_id
from public.profiles profile where profile.id = item.employee_id and item.org_id is null;
update public.comp_time_usage_allocations allocation set org_id = credit.org_id
from public.comp_time_credits credit where credit.id = allocation.credit_id and allocation.org_id is null;
update public.annual_leave_entitlements item set org_id = profile.org_id
from public.profiles profile where profile.id = item.employee_id and item.org_id is null;

alter table public.employee_schedule_overrides alter column org_id set not null;
alter table public.attendance_locations alter column org_id set not null;
alter table public.location_consents alter column org_id set not null;
alter table public.attendance_events alter column org_id set not null;
alter table public.attendance_exceptions alter column org_id set not null;
alter table public.comp_time_credits alter column org_id set not null;
alter table public.comp_time_usage_allocations alter column org_id set not null;
alter table public.annual_leave_entitlements alter column org_id set not null;

create index if not exists schedules_org_date_idx on public.employee_schedule_overrides(org_id, work_date);
create index if not exists locations_org_captured_idx on public.attendance_locations(org_id, captured_at desc);
create index if not exists events_org_date_idx on public.attendance_events(org_id, work_date);
create index if not exists exceptions_org_period_idx on public.attendance_exceptions(org_id, start_date, end_date);
create index if not exists comp_credits_org_expiry_idx on public.comp_time_credits(org_id, expires_on);
create index if not exists annual_entitlements_org_period_idx on public.annual_leave_entitlements(org_id, valid_from, valid_to);

drop trigger if exists employee_schedule_overrides_assign_org_id on public.employee_schedule_overrides;
create trigger employee_schedule_overrides_assign_org_id before insert on public.employee_schedule_overrides
for each row execute function public.assign_org_id_from_employee();

drop trigger if exists attendance_locations_assign_org_id on public.attendance_locations;
create trigger attendance_locations_assign_org_id before insert on public.attendance_locations
for each row execute function public.assign_org_id_from_employee();

drop trigger if exists location_consents_assign_org_id on public.location_consents;
create trigger location_consents_assign_org_id before insert on public.location_consents
for each row execute function public.assign_org_id_from_employee();

drop trigger if exists attendance_events_assign_org_id on public.attendance_events;
create trigger attendance_events_assign_org_id before insert on public.attendance_events
for each row execute function public.assign_org_id_from_employee();

drop trigger if exists attendance_exceptions_assign_org_id on public.attendance_exceptions;
create trigger attendance_exceptions_assign_org_id before insert on public.attendance_exceptions
for each row execute function public.assign_org_id_from_employee();

drop trigger if exists comp_time_credits_assign_org_id on public.comp_time_credits;
create trigger comp_time_credits_assign_org_id before insert on public.comp_time_credits
for each row execute function public.assign_org_id_from_employee();

create or replace function public.assign_org_id_from_comp_credit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.org_id is null then
    select org_id into new.org_id
    from public.comp_time_credits
    where id = new.credit_id;
  end if;
  return new;
end;
$$;

drop trigger if exists comp_time_usage_allocations_assign_org_id on public.comp_time_usage_allocations;
create trigger comp_time_usage_allocations_assign_org_id before insert on public.comp_time_usage_allocations
for each row execute function public.assign_org_id_from_comp_credit();

drop trigger if exists annual_leave_entitlements_assign_org_id on public.annual_leave_entitlements;
create trigger annual_leave_entitlements_assign_org_id before insert on public.annual_leave_entitlements
for each row execute function public.assign_org_id_from_employee();

drop policy if exists "profiles own or admin read" on public.profiles;
drop policy if exists "profiles own or org admin read" on public.profiles;
create policy "profiles own or org admin read" on public.profiles for select to authenticated
using (
  id = auth.uid()
  or public.is_super_admin()
  or (public.is_attendance_admin() and org_id = public.current_profile_org_id())
  or (public.can_view_attendance_reports() and org_id = public.current_profile_org_id())
);

drop policy if exists "own or admin attendance read" on public.attendance_records;
create policy "own or org admin attendance read" on public.attendance_records for select to authenticated
using (employee_id = auth.uid() or public.is_super_admin() or (org_id = public.current_profile_org_id() and (public.is_attendance_admin() or public.can_view_attendance_reports())));

drop policy if exists "own or admin correction read" on public.correction_requests;
create policy "own or org admin correction read" on public.correction_requests for select to authenticated
using (employee_id = auth.uid() or public.is_super_admin() or (org_id = public.current_profile_org_id() and (public.is_attendance_admin() or public.can_view_attendance_reports())));

drop policy if exists "admin correction update" on public.correction_requests;
drop policy if exists "org admin correction update" on public.correction_requests;
create policy "org admin correction update" on public.correction_requests for update to authenticated
using (public.is_super_admin() or (public.is_attendance_admin() and org_id = public.current_profile_org_id()))
with check (public.is_super_admin() or (public.is_attendance_admin() and org_id = public.current_profile_org_id()));

drop policy if exists "admin audit read" on public.attendance_audit_logs;
create policy "org admin audit read" on public.attendance_audit_logs for select to authenticated
using (public.is_super_admin() or (org_id = public.current_profile_org_id() and (public.is_attendance_admin() or public.can_view_attendance_reports())));

drop policy if exists "own or admin schedules read" on public.employee_schedule_overrides;
create policy "own or org admin schedules read" on public.employee_schedule_overrides for select to authenticated
using (employee_id = auth.uid() or public.is_super_admin() or (org_id = public.current_profile_org_id() and public.is_attendance_admin()));
drop policy if exists "admin manages schedules" on public.employee_schedule_overrides;
create policy "org admin manages schedules" on public.employee_schedule_overrides for all to authenticated
using (public.is_super_admin() or (org_id = public.current_profile_org_id() and public.is_attendance_admin()))
with check (public.is_super_admin() or (org_id = public.current_profile_org_id() and public.is_attendance_admin()));

drop policy if exists "own raw locations or super admin read" on public.attendance_locations;
create policy "own raw locations or super admin read" on public.attendance_locations for select to authenticated
using (employee_id = auth.uid() or public.is_super_admin());

drop policy if exists "own consent read" on public.location_consents;
create policy "own or org admin consent read" on public.location_consents for select to authenticated
using (employee_id = auth.uid() or public.is_super_admin() or (org_id = public.current_profile_org_id() and public.is_attendance_admin()));

alter table public.attendance_events enable row level security;
drop policy if exists "own or org admin events read" on public.attendance_events;
create policy "own or org admin events read" on public.attendance_events for select to authenticated
using (employee_id = auth.uid() or public.is_super_admin() or (org_id = public.current_profile_org_id() and public.is_attendance_admin()));

drop policy if exists "own or admin exception read" on public.attendance_exceptions;
create policy "own or org admin exception read" on public.attendance_exceptions for select to authenticated
using (employee_id = auth.uid() or public.is_super_admin() or (org_id = public.current_profile_org_id() and (public.is_attendance_admin() or public.can_view_attendance_reports())));

drop policy if exists "own or admin comp credits read" on public.comp_time_credits;
create policy "own or org admin comp credits read" on public.comp_time_credits for select to authenticated
using (employee_id = auth.uid() or public.is_super_admin() or (org_id = public.current_profile_org_id() and (public.is_attendance_admin() or public.can_view_attendance_reports())));

drop policy if exists "own or admin comp allocations read" on public.comp_time_usage_allocations;
create policy "own or org admin comp allocations read" on public.comp_time_usage_allocations for select to authenticated
using (public.is_super_admin() or org_id = public.current_profile_org_id());

drop policy if exists "own or admin annual entitlements read" on public.annual_leave_entitlements;
create policy "own or org admin annual entitlements read" on public.annual_leave_entitlements for select to authenticated
using (employee_id = auth.uid() or public.is_super_admin() or (org_id = public.current_profile_org_id() and (public.is_attendance_admin() or public.can_view_attendance_reports())));

commit;

-- 다음 검사는 모두 0이어야 한다.
-- select count(*) from public.employee_schedule_overrides where org_id is null;
-- select count(*) from public.attendance_locations where org_id is null;
-- select count(*) from public.location_consents where org_id is null;
-- select count(*) from public.attendance_events where org_id is null;
-- select count(*) from public.attendance_exceptions where org_id is null;
-- select count(*) from public.comp_time_credits where org_id is null;
-- select count(*) from public.comp_time_usage_allocations where org_id is null;
-- select count(*) from public.annual_leave_entitlements where org_id is null;
