-- 기관별 근무방식 저장 실패 보완
-- 기존 근태기록은 수정하지 않는다.

begin;

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

alter table public.organization_work_policies enable row level security;

drop policy if exists "organization work policy read" on public.organization_work_policies;
create policy "organization work policy read"
on public.organization_work_policies for select to authenticated
using (org_id = public.current_profile_org_id() or public.is_super_admin());

drop policy if exists "organization admin manages work policy" on public.organization_work_policies;
create policy "organization admin manages work policy"
on public.organization_work_policies for all to authenticated
using (
  (org_id = public.current_profile_org_id() and public.current_profile_role() in ('admin','org_admin'))
  or public.is_super_admin()
)
with check (
  (org_id = public.current_profile_org_id() and public.current_profile_role() in ('admin','org_admin'))
  or public.is_super_admin()
);

grant select, insert, update, delete on public.organization_work_policies to authenticated;

commit;
