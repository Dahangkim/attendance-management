-- 기관 생성, 승인 흐름, 기관별 근무정책과 야간당직 기반
-- foundation, isolation, branding 적용 후 실행한다.

begin;

-- 기관별 설정을 한 행씩 가질 수 있도록 기존 단일행 기본키를 기관 기준으로 바꾼다.
alter table public.organization_settings drop constraint if exists organization_settings_pkey;
alter table public.organization_settings drop constraint if exists organization_settings_org_id_key;
alter table public.organization_settings add constraint organization_settings_org_id_key unique (org_id);

alter table public.monthly_closings drop constraint if exists monthly_closings_year_month_key;
alter table public.monthly_closings drop constraint if exists monthly_closings_org_period_key;
alter table public.monthly_closings add constraint monthly_closings_org_period_key unique (org_id, year, month);

create unique index if not exists workplaces_one_active_per_org_idx
  on public.workplaces(org_id) where is_active;

create table if not exists public.organization_work_policies (
  org_id uuid primary key references public.organizations(id) on delete restrict,
  attendance_mode text not null default 'fixed'
    check (attendance_mode in ('fixed', 'flexible', 'shift')),
  work_date_boundary_time time not null default '04:00',
  max_open_shift_hours integer not null default 24 check (max_open_shift_hours between 8 and 48),
  overtime_rounding_minutes integer not null default 30 check (overtime_rounding_minutes in (1, 5, 10, 15, 30, 60)),
  require_location boolean not null default true,
  require_office_ip boolean not null default false,
  updated_by uuid references public.profiles(id) on delete restrict,
  updated_at timestamptz not null default now()
);

insert into public.organization_work_policies (org_id)
select id from public.organizations
on conflict (org_id) do nothing;

create table if not exists public.work_shift_templates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete restrict,
  shift_code text not null check (shift_code ~ '^[A-Z0-9_-]{1,20}$'),
  shift_name text not null check (char_length(trim(shift_name)) between 1 and 50),
  start_time time not null,
  end_time time not null,
  crosses_midnight boolean not null default false,
  break_minutes integer not null default 60 check (break_minutes between 0 and 480),
  late_grace_minutes integer not null default 0 check (late_grace_minutes between 0 and 180),
  early_leave_grace_minutes integer not null default 0 check (early_leave_grace_minutes between 0 and 180),
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, shift_code),
  check (crosses_midnight or end_time > start_time)
);

create table if not exists public.employee_shift_assignments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete restrict,
  employee_id uuid not null references public.profiles(id) on delete restrict,
  work_date date not null,
  shift_template_id uuid not null references public.work_shift_templates(id) on delete restrict,
  note text not null default '',
  created_by uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (employee_id, work_date)
);

alter table public.attendance_records add column if not exists shift_template_id uuid references public.work_shift_templates(id) on delete restrict;
alter table public.attendance_records add column if not exists scheduled_start_at timestamptz;
alter table public.attendance_records add column if not exists scheduled_end_at timestamptz;

create table if not exists public.organization_change_requests (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete restrict,
  request_type text not null check (request_type in ('workplace_location', 'office_ip', 'org_admin_account')),
  action text not null default 'update' check (action in ('create', 'update', 'replace', 'deactivate')),
  target_profile_id uuid references public.profiles(id) on delete restrict,
  proposed_values jsonb not null default '{}'::jsonb,
  reason text not null check (char_length(trim(reason)) between 5 and 1000),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  requested_by uuid not null references public.profiles(id) on delete restrict,
  requested_at timestamptz not null default now(),
  reviewed_by uuid references public.profiles(id) on delete restrict,
  reviewed_at timestamptz,
  review_note text not null default '',
  check ((status = 'pending' and reviewed_by is null and reviewed_at is null) or status <> 'pending')
);

create index if not exists organization_change_requests_review_idx
  on public.organization_change_requests(status, requested_at desc);
create index if not exists employee_shift_assignments_org_date_idx
  on public.employee_shift_assignments(org_id, work_date);

-- 부관리자는 조회만 가능하고 근태 승인 권한은 갖지 않는다.
create or replace function public.is_attendance_admin()
returns boolean language sql stable security definer set search_path = public
as $$
  select coalesce(public.current_profile_role() in ('admin','org_admin','super_admin'), false)
$$;

alter table public.organization_work_policies enable row level security;
alter table public.work_shift_templates enable row level security;
alter table public.employee_shift_assignments enable row level security;
alter table public.organization_change_requests enable row level security;

drop policy if exists "organization work policy read" on public.organization_work_policies;
create policy "organization work policy read"
on public.organization_work_policies for select to authenticated
using (org_id = public.current_profile_org_id() or public.is_super_admin());
drop policy if exists "organization admin manages work policy" on public.organization_work_policies;
create policy "organization admin manages work policy"
on public.organization_work_policies for all to authenticated
using ((org_id = public.current_profile_org_id() and public.current_profile_role() in ('admin','org_admin')) or public.is_super_admin())
with check ((org_id = public.current_profile_org_id() and public.current_profile_role() in ('admin','org_admin')) or public.is_super_admin());

drop policy if exists "organization shift templates read" on public.work_shift_templates;
create policy "organization shift templates read"
on public.work_shift_templates for select to authenticated
using (org_id = public.current_profile_org_id() or public.is_super_admin());
drop policy if exists "organization admin manages shift templates" on public.work_shift_templates;
create policy "organization admin manages shift templates"
on public.work_shift_templates for all to authenticated
using ((org_id = public.current_profile_org_id() and public.current_profile_role() in ('admin','org_admin')) or public.is_super_admin())
with check ((org_id = public.current_profile_org_id() and public.current_profile_role() in ('admin','org_admin')) or public.is_super_admin());

drop policy if exists "own or organization shift assignments read" on public.employee_shift_assignments;
create policy "own or organization shift assignments read"
on public.employee_shift_assignments for select to authenticated
using (employee_id = auth.uid() or org_id = public.current_profile_org_id() or public.is_super_admin());
drop policy if exists "organization admin manages shift assignments" on public.employee_shift_assignments;
create policy "organization admin manages shift assignments"
on public.employee_shift_assignments for all to authenticated
using ((org_id = public.current_profile_org_id() and public.current_profile_role() in ('admin','org_admin')) or public.is_super_admin())
with check ((org_id = public.current_profile_org_id() and public.current_profile_role() in ('admin','org_admin')) or public.is_super_admin());

drop policy if exists "organization change requests read" on public.organization_change_requests;
create policy "organization change requests read"
on public.organization_change_requests for select to authenticated
using (org_id = public.current_profile_org_id() or public.is_super_admin());
drop policy if exists "organization admin requests changes" on public.organization_change_requests;
create policy "organization admin requests changes"
on public.organization_change_requests for insert to authenticated
with check (org_id = public.current_profile_org_id() and requested_by = auth.uid() and public.current_profile_role() in ('admin','org_admin') and status = 'pending');
drop policy if exists "super admin reviews changes" on public.organization_change_requests;
create policy "super admin reviews changes"
on public.organization_change_requests for update to authenticated
using (public.is_super_admin()) with check (public.is_super_admin());

grant select on public.organization_work_policies, public.work_shift_templates, public.employee_shift_assignments, public.organization_change_requests to authenticated;
grant insert, update, delete on public.organization_work_policies, public.work_shift_templates, public.employee_shift_assignments to authenticated;
grant insert on public.organization_change_requests to authenticated;

-- 일반 근무시간은 기관 관리자가 직접 바꿀 수 있다. IP 변경은 승인 요청을 거쳐야 한다.
create or replace function public.save_organization_settings(
  p_default_start_time time,
  p_default_end_time time,
  p_break_minutes integer,
  p_late_grace_minutes integer,
  p_early_leave_grace_minutes integer,
  p_office_ip_address text
) returns public.organization_settings
language plpgsql security definer set search_path = public as $$
declare
  v_org_id uuid := public.current_profile_org_id();
  v_role text := public.current_profile_role();
  v_existing_ip text;
  v_settings public.organization_settings;
begin
  if v_role not in ('admin','org_admin') then raise exception 'ORG_ADMIN_REQUIRED'; end if;
  select office_ip_address into v_existing_ip from public.organization_settings where org_id = v_org_id;
  if trim(coalesce(p_office_ip_address,'')) <> trim(coalesce(v_existing_ip,'')) then raise exception 'IP_CHANGE_APPROVAL_REQUIRED'; end if;
  insert into public.organization_settings (
    id, org_id, default_start_time, default_end_time, break_minutes,
    late_grace_minutes, early_leave_grace_minutes, office_ip_address, updated_by
  ) values (
    true, v_org_id, p_default_start_time, p_default_end_time, p_break_minutes,
    p_late_grace_minutes, p_early_leave_grace_minutes, coalesce(v_existing_ip,''), auth.uid()
  ) on conflict (org_id) do update set
    default_start_time = excluded.default_start_time,
    default_end_time = excluded.default_end_time,
    break_minutes = excluded.break_minutes,
    late_grace_minutes = excluded.late_grace_minutes,
    early_leave_grace_minutes = excluded.early_leave_grace_minutes,
    updated_by = auth.uid(), updated_at = now()
  returning * into v_settings;
  return v_settings;
end $$;

create or replace function public.admin_set_employee_active(
  p_employee_id uuid,
  p_active boolean
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_employee public.profiles;
begin
  if v_role not in ('admin','org_admin') then raise exception 'ORG_ADMIN_REQUIRED'; end if;
  select * into v_employee from public.profiles
  where id = p_employee_id and role = 'employee' and org_id = v_org_id
  for update;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_employee.is_active = p_active then return; end if;
  update public.profiles set is_active = p_active,
    can_view_reports = case when p_active then can_view_reports else false end,
    updated_at = now()
  where id = p_employee_id and org_id = v_org_id;
  insert into public.attendance_audit_logs (
    employee_id, action_type, changed_field, before_value, after_value,
    reason, changed_by, changed_by_role, org_id
  ) values (
    p_employee_id,
    case when p_active then 'employee_reactivated' else 'employee_deactivated' end,
    'is_active', v_employee.is_active::text, p_active::text,
    case when p_active then '직원 계정 재활성화' else '퇴사 처리, 로그인 목록 제외' end,
    auth.uid(), v_role, v_org_id
  );
end $$;

revoke all on function public.admin_set_employee_active(uuid,boolean) from public, anon;
grant execute on function public.admin_set_employee_active(uuid,boolean) to authenticated;

notify pgrst, 'reload schema';
commit;
