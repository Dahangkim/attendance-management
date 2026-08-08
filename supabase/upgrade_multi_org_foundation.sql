-- 멀티 조직 전환 1단계: 조직과 도메인 기반을 추가한다.
-- 기존 함수와 organization_settings.id는 이 단계에서 변경하지 않는다.
-- 운영 적용 전 백업본 또는 별도 Supabase 프로젝트에서 먼저 검증해야 한다.

begin;

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  org_code text not null unique check (org_code ~ '^[a-z0-9][a-z0-9-]{1,49}$'),
  org_name text not null check (char_length(trim(org_name)) between 2 and 100),
  short_name text not null,
  organization_type text not null default 'facility'
    check (organization_type in ('corporation', 'facility')),
  parent_org_id uuid references public.organizations(id),
  expected_staff_count integer check (expected_staff_count is null or expected_staff_count >= 0),
  domain text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organizations_domain_normalized_check
    check (domain is null or domain = lower(trim(trailing '.' from domain)))
);

create unique index if not exists organizations_domain_unique_idx
  on public.organizations (lower(domain)) where domain is not null;

-- 초안 SQL이 일부 실행된 테스트 DB에서도 이어서 적용할 수 있게 보완한다.
alter table public.organizations add column if not exists short_name text;
alter table public.organizations add column if not exists organization_type text default 'facility';
alter table public.organizations add column if not exists parent_org_id uuid references public.organizations(id);
alter table public.organizations add column if not exists expected_staff_count integer;
alter table public.organizations add column if not exists domain text;
alter table public.organizations add column if not exists updated_at timestamptz not null default now();

update public.organizations
set short_name = org_name
where short_name is null or trim(short_name) = '';

alter table public.organizations alter column short_name set not null;

-- 기존 단일 기관 기록을 샘플 기관으로 전환한다.
-- 운영 적용 전 아래 샘플 기관값을 실제 기관값으로 바꿔야 한다.
insert into public.organizations (
  org_code, org_name, short_name, organization_type, parent_org_id, expected_staff_count
) values (
  'sample-org', '샘플 기관', '기관', 'facility', null, null
)
on conflict (org_code) do update
set org_name = excluded.org_name,
    short_name = excluded.short_name,
    organization_type = excluded.organization_type,
    expected_staff_count = excluded.expected_staff_count;

alter table public.profiles add column if not exists org_id uuid references public.organizations(id);
alter table public.workplaces add column if not exists org_id uuid references public.organizations(id);
alter table public.organization_settings add column if not exists org_id uuid references public.organizations(id);
alter table public.attendance_records add column if not exists org_id uuid references public.organizations(id);
alter table public.correction_requests add column if not exists org_id uuid references public.organizations(id);
alter table public.attendance_audit_logs add column if not exists org_id uuid references public.organizations(id);
alter table public.monthly_closings add column if not exists org_id uuid references public.organizations(id);

update public.profiles
set org_id = (select id from public.organizations where org_code = 'sample-org')
where org_id is null;

update public.workplaces
set org_id = (select id from public.organizations where org_code = 'sample-org')
where org_id is null;

update public.organization_settings
set org_id = (select id from public.organizations where org_code = 'sample-org')
where org_id is null;

update public.attendance_records record
set org_id = profile.org_id
from public.profiles profile
where profile.id = record.employee_id and record.org_id is null;

update public.correction_requests request
set org_id = profile.org_id
from public.profiles profile
where profile.id = request.employee_id and request.org_id is null;

update public.attendance_audit_logs log
set org_id = profile.org_id
from public.profiles profile
where profile.id = log.employee_id and log.org_id is null;

update public.monthly_closings
set org_id = (select id from public.organizations where org_code = 'sample-org')
where org_id is null;

alter table public.profiles alter column org_id set not null;
alter table public.workplaces alter column org_id set not null;
alter table public.organization_settings alter column org_id set not null;
alter table public.attendance_records alter column org_id set not null;
alter table public.correction_requests alter column org_id set not null;
alter table public.monthly_closings alter column org_id set not null;

create index if not exists profiles_org_id_idx on public.profiles(org_id);
alter table public.profiles drop constraint if exists profiles_employee_number_key;
drop index if exists public.profiles_org_employee_number_unique_idx;
create unique index if not exists profiles_employee_number_global_unique_idx
  on public.profiles(upper(employee_number)) where role = 'employee';

create or replace function public.next_employee_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prefix text := to_char(current_timestamp at time zone 'Asia/Seoul', 'YY');
  v_next integer;
begin
  perform pg_advisory_xact_lock(260001);
  select coalesce(max(substring(employee_number from 3 for 4)::integer), 0) + 1
  into v_next
  from public.profiles
  where employee_number ~ ('^' || v_prefix || '[0-9]{4}$');
  if v_next > 9999 then raise exception 'EMPLOYEE_NUMBER_CAPACITY_EXCEEDED'; end if;
  return v_prefix || lpad(v_next::text, 4, '0');
end $$;

revoke all on function public.next_employee_number() from public, anon, authenticated;
grant execute on function public.next_employee_number() to service_role;
create index if not exists workplaces_org_id_idx on public.workplaces(org_id);
create index if not exists attendance_records_org_date_idx on public.attendance_records(org_id, work_date);
create index if not exists correction_requests_org_date_idx on public.correction_requests(org_id, target_date);
create index if not exists attendance_audit_logs_org_created_idx on public.attendance_audit_logs(org_id, created_at desc);
create index if not exists monthly_closings_org_period_idx on public.monthly_closings(org_id, year, month);

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('employee', 'team_lead', 'org_admin', 'admin', 'super_admin'));

create or replace function public.current_profile_org_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select org_id from public.profiles where id = auth.uid() and is_active = true
$$;

-- 기존 RPC가 org_id 없이 행을 추가해도 해당 직원의 조직을 자동으로 이어받게 한다.
create or replace function public.assign_org_id_from_employee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.org_id is null then
    select org_id into new.org_id
    from public.profiles
    where id = new.employee_id;
  end if;
  return new;
end;
$$;

create or replace function public.assign_org_id_from_actor()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.org_id is null then
    new.org_id := public.current_profile_org_id();
  end if;
  return new;
end;
$$;

create or replace function public.assign_profile_org_id()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if new.org_id is null then
    select organization.id into new.org_id
    from auth.users auth_user
    join public.organizations organization
      on organization.org_code = auth_user.raw_user_meta_data ->> 'org_code'
    where auth_user.id = new.id
      and organization.is_active = true;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_assign_org_id on public.profiles;
create trigger profiles_assign_org_id before insert on public.profiles
for each row execute function public.assign_profile_org_id();

drop trigger if exists attendance_records_assign_org_id on public.attendance_records;
create trigger attendance_records_assign_org_id before insert on public.attendance_records
for each row execute function public.assign_org_id_from_employee();

drop trigger if exists correction_requests_assign_org_id on public.correction_requests;
create trigger correction_requests_assign_org_id before insert on public.correction_requests
for each row execute function public.assign_org_id_from_employee();

drop trigger if exists attendance_audit_logs_assign_org_id on public.attendance_audit_logs;
create trigger attendance_audit_logs_assign_org_id before insert on public.attendance_audit_logs
for each row execute function public.assign_org_id_from_employee();

drop trigger if exists workplaces_assign_org_id on public.workplaces;
create trigger workplaces_assign_org_id before insert on public.workplaces
for each row execute function public.assign_org_id_from_actor();

drop trigger if exists organization_settings_assign_org_id on public.organization_settings;
create trigger organization_settings_assign_org_id before insert on public.organization_settings
for each row execute function public.assign_org_id_from_actor();

drop trigger if exists monthly_closings_assign_org_id on public.monthly_closings;
create trigger monthly_closings_assign_org_id before insert on public.monthly_closings
for each row execute function public.assign_org_id_from_actor();

alter table public.organizations enable row level security;
drop policy if exists "authenticated read organizations" on public.organizations;
create policy "authenticated read organizations"
on public.organizations for select to authenticated
using (is_active);

drop policy if exists "super admin manages organizations" on public.organizations;
create policy "super admin manages organizations"
on public.organizations for all to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());

grant select on public.organizations to authenticated;

commit;

-- 적용 후 아래 검사가 모두 0이어야 다음 단계로 진행할 수 있다.
-- select count(*) from public.profiles where org_id is null;
-- select count(*) from public.workplaces where org_id is null;
-- select count(*) from public.organization_settings where org_id is null;
-- select count(*) from public.attendance_records where org_id is null;
-- select count(*) from public.correction_requests where org_id is null;
-- select count(*) from public.monthly_closings where org_id is null;
