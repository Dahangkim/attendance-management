-- 근태관리 현재 통합 설치 SQL
-- 생성일: 2026-08-06
-- 새 Supabase 프로젝트에서는 이 파일 전체를 SQL Editor에서 한 번 실행합니다.
-- 기존 운영 프로젝트에서는 upgrade_secure_clock_and_overnight.sql만 추가 실행합니다.
-- seed.sql과 migrate_super_admin.sql은 기관 계정 정보가 필요하므로 포함하지 않습니다.

-- ============================================================================
-- supabase/schema.sql
-- ============================================================================

-- 근태관리 기본 데이터베이스 구조
-- Supabase SQL Editor에서 전체를 한 번 실행합니다.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete restrict,
  email text not null,
  name text not null,
  role text not null default 'employee' check (role in ('employee', 'admin', 'super_admin')),
  employee_number text not null unique,
  department text not null default '',
  is_active boolean not null default true,
  can_view_reports boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.workplaces (
  id uuid primary key default gen_random_uuid(),
  workplace_name text not null,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  allowed_radius_meters integer not null default 100 check (allowed_radius_meters between 50 and 1000),
  low_accuracy_threshold_meters integer not null default 100 check (low_accuracy_threshold_meters between 30 and 2000),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.organization_settings (
  id boolean primary key default true check (id),
  timezone text not null default 'Asia/Seoul',
  default_start_time time not null default '09:00',
  default_end_time time not null default '18:00',
  break_minutes integer not null default 60 check (break_minutes between 0 and 480),
  late_grace_minutes integer not null default 0 check (late_grace_minutes between 0 and 180),
  early_leave_grace_minutes integer not null default 0 check (early_leave_grace_minutes between 0 and 180),
  office_ip_address text not null default '',
  emergency_support_enabled boolean not null default true,
  work_days smallint[] not null default array[1,2,3,4,5],
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

insert into public.organization_settings (id) values (true) on conflict (id) do nothing;

create table if not exists public.work_type_settings (
  work_type text primary key check (work_type in ('office','direct_in','direct_out','field','education','business_trip','remote','approved_other')),
  label text not null,
  requires_prior_approval boolean not null default false,
  requires_reason boolean not null default false,
  requires_workplace_radius boolean not null default false,
  is_active boolean not null default true,
  updated_at timestamptz not null default now()
);

insert into public.work_type_settings (work_type, label, requires_prior_approval, requires_reason, requires_workplace_radius, is_active) values
  ('office','사무실 근무',false,false,true,true), ('direct_in','직출',true,true,false,false),
  ('direct_out','직퇴',true,true,false,false), ('field','외근',false,true,false,false),
  ('education','교육',true,true,false,false), ('business_trip','출장',true,true,false,false),
  ('remote','재택근무',true,true,false,false), ('approved_other','기타 승인근무',true,true,false,false)
on conflict (work_type) do nothing;

create table if not exists public.holidays (
  holiday_date date primary key,
  holiday_name text not null,
  is_paid_holiday boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.employee_schedule_overrides (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.profiles(id) on delete restrict,
  work_date date not null,
  is_workday boolean not null default true,
  start_time time,
  end_time time,
  break_minutes integer check (break_minutes between 0 and 480),
  reason text not null default '',
  created_by uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (employee_id, work_date)
);

create table if not exists public.attendance_records (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.profiles(id) on delete restrict,
  work_date date not null,
  work_type text not null default 'office' references public.work_type_settings(work_type),
  clock_in_at timestamptz,
  clock_out_at timestamptz,
  clock_in_accuracy numeric(10,2),
  clock_in_distance numeric(10,2),
  clock_in_location_status text not null default 'not_checked' check (clock_in_location_status in ('inside','outside','low_accuracy','permission_denied','unavailable','not_checked')),
  clock_in_ip_address text,
  clock_in_ip_matched boolean not null default false,
  clock_out_accuracy numeric(10,2),
  clock_out_distance numeric(10,2),
  clock_out_location_status text not null default 'not_checked' check (clock_out_location_status in ('inside','outside','low_accuracy','permission_denied','unavailable','not_checked')),
  clock_out_ip_address text,
  clock_out_ip_matched boolean not null default false,
  attendance_status text not null default 'working' check (attendance_status in ('normal','late','absent','missing_in','missing_out','location_review','admin_review','field','business_trip','education','leave','annual_leave','half_day','quarter_day','hourly_leave','sick_leave','holiday_work','working')),
  raw_overtime_minutes integer not null default 0 check (raw_overtime_minutes between 0 and 1440),
  recorded_overtime_minutes integer not null default 0 check (recorded_overtime_minutes between 0 and 240),
  overtime_status text not null default 'none' check (overtime_status in ('none','pending','approved','rejected')),
  approved_overtime_minutes integer not null default 0 check (approved_overtime_minutes between 0 and 240),
  leave_type text not null default 'none' check (leave_type in ('none','annual_leave','half_day','quarter_day','hourly_leave','sick_leave')),
  note text not null default '',
  is_closed boolean not null default false,
  changed boolean not null default false,
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id) on delete restrict,
  deletion_reason text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (employee_id, work_date),
  check (clock_out_at is null or clock_in_at is not null),
  check (clock_out_at is null or clock_out_at >= clock_in_at)
);

-- 원본 좌표는 일반 근태표와 분리해 최소 권한으로 보호합니다.
create table if not exists public.attendance_locations (
  id uuid primary key default gen_random_uuid(),
  attendance_record_id uuid not null references public.attendance_records(id) on delete restrict,
  employee_id uuid not null references public.profiles(id) on delete restrict,
  event_type text not null check (event_type in ('clock_in','clock_out')),
  latitude double precision,
  longitude double precision,
  ip_address text,
  ip_matched boolean not null default false,
  captured_at timestamptz not null default now(),
  unique (attendance_record_id, event_type)
);

alter table public.organization_settings add column if not exists office_ip_address text not null default '';
alter table public.attendance_records add column if not exists clock_in_ip_address text;
alter table public.attendance_records add column if not exists clock_in_ip_matched boolean not null default false;
alter table public.attendance_records add column if not exists clock_out_ip_address text;
alter table public.attendance_records add column if not exists clock_out_ip_matched boolean not null default false;
alter table public.attendance_records add column if not exists deleted_at timestamptz;
alter table public.attendance_records add column if not exists deleted_by uuid references public.profiles(id) on delete restrict;
alter table public.attendance_records add column if not exists deletion_reason text not null default '';
alter table public.attendance_records add column if not exists raw_overtime_minutes integer not null default 0;
alter table public.attendance_records add column if not exists recorded_overtime_minutes integer not null default 0;
alter table public.attendance_records add column if not exists overtime_status text not null default 'none';
alter table public.attendance_records add column if not exists approved_overtime_minutes integer not null default 0;
alter table public.attendance_records add column if not exists leave_type text not null default 'none';
alter table public.attendance_locations add column if not exists ip_address text;
alter table public.attendance_locations add column if not exists ip_matched boolean not null default false;

create table if not exists public.location_consents (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.profiles(id) on delete restrict,
  notice_version text not null,
  notice_text text not null,
  consented_at timestamptz not null default now(),
  withdrawn_at timestamptz,
  unique (employee_id, notice_version)
);

create table if not exists public.correction_requests (
  id uuid primary key default gen_random_uuid(),
  attendance_record_id uuid references public.attendance_records(id) on delete restrict,
  employee_id uuid not null references public.profiles(id) on delete restrict,
  target_date date not null,
  request_type text not null check (request_type in ('clock_in_at','clock_out_at','work_type','note','attendance_status','annual_leave','comp_time','sick_leave')),
  before_value text not null default '',
  requested_value text not null,
  reason text not null check (char_length(reason) between 5 and 2000),
  status text not null default 'pending' check (status in ('pending','approved','rejected','more_info')),
  reviewer_id uuid references public.profiles(id) on delete restrict,
  reviewer_comment text not null default '',
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz
);

create table if not exists public.monthly_closings (
  id uuid primary key default gen_random_uuid(),
  year integer not null check (year between 2020 and 2100),
  month integer not null check (month between 1 and 12),
  closed_by uuid references public.profiles(id) on delete restrict,
  closed_at timestamptz,
  reopened_by uuid references public.profiles(id) on delete restrict,
  reopened_at timestamptz,
  reopen_reason text not null default '',
  status text not null default 'open' check (status in ('open','closed')),
  unique (year, month)
);

create table if not exists public.attendance_audit_logs (
  id uuid primary key default gen_random_uuid(),
  attendance_record_id uuid references public.attendance_records(id) on delete restrict,
  employee_id uuid not null references public.profiles(id) on delete restrict,
  action_type text not null,
  changed_field text not null,
  before_value text not null default '',
  after_value text not null default '',
  reason text not null default '',
  changed_by uuid references public.profiles(id) on delete restrict,
  changed_by_role text,
  correction_request_id uuid references public.correction_requests(id) on delete restrict,
  device_info text,
  created_at timestamptz not null default now()
);

create table if not exists public.attendance_events (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.profiles(id) on delete restrict,
  work_date date not null,
  action_type text not null check (action_type in ('clock_in','clock_out')),
  idempotency_key uuid not null,
  attendance_record_id uuid references public.attendance_records(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (employee_id, work_date, action_type),
  unique (employee_id, idempotency_key)
);

create index if not exists attendance_records_month_idx on public.attendance_records (work_date, employee_id);
create index if not exists correction_requests_status_idx on public.correction_requests (status, requested_at desc);
create index if not exists audit_logs_record_idx on public.attendance_audit_logs (attendance_record_id, created_at desc);
create index if not exists audit_logs_employee_idx on public.attendance_audit_logs (employee_id, created_at desc);

create or replace function public.current_profile_role()
returns text language sql stable security definer set search_path = public
as $$ select role from public.profiles where id = auth.uid() and is_active = true $$;

create or replace function public.is_attendance_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select coalesce(public.current_profile_role() in ('admin','super_admin'), false) $$;

create or replace function public.is_super_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select coalesce(public.current_profile_role() = 'super_admin', false) $$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at before update on public.profiles for each row execute function public.touch_updated_at();
drop trigger if exists workplaces_touch_updated_at on public.workplaces;
create trigger workplaces_touch_updated_at before update on public.workplaces for each row execute function public.touch_updated_at();
drop trigger if exists attendance_touch_updated_at on public.attendance_records;
create trigger attendance_touch_updated_at before update on public.attendance_records for each row execute function public.touch_updated_at();

create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name, employee_number, department)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'name', split_part(coalesce(new.email, '직원'), '@', 1)),
    coalesce(new.raw_user_meta_data ->> 'employee_number', 'PENDING-' || left(new.id::text, 8)),
    coalesce(new.raw_user_meta_data ->> 'department', '')
  ) on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_auth_user();

create or replace function public.distance_meters(lat1 double precision, lon1 double precision, lat2 double precision, lon2 double precision)
returns numeric language sql immutable strict as $$
  select round((6371000 * 2 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
  )))::numeric, 2)
$$;

create or replace function public.clock_attendance(
  p_action text,
  p_work_type text,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy numeric,
  p_location_status text,
  p_ip_address text,
  p_note text,
  p_idempotency_key uuid
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_user public.profiles;
  v_workplace public.workplaces;
  v_settings public.organization_settings;
  v_record public.attendance_records;
  v_now timestamptz := now();
  v_date date := (now() at time zone 'Asia/Seoul')::date;
  v_distance numeric;
  v_location_status text;
  v_ip_matched boolean := false;
  v_attendance_status text;
begin
  if p_action not in ('clock_in','clock_out') then raise exception 'INVALID_ACTION'; end if;
  select * into v_user from public.profiles where id = auth.uid() and is_active = true;
  if not found then raise exception 'INACTIVE_OR_UNKNOWN_USER'; end if;
  if not exists (select 1 from public.work_type_settings where work_type = p_work_type and is_active) then raise exception 'INVALID_WORK_TYPE'; end if;
  select * into v_workplace from public.workplaces where is_active order by created_at limit 1;
  if not found then raise exception 'WORKPLACE_NOT_CONFIGURED'; end if;
  select * into v_settings from public.organization_settings where id = true;
  v_ip_matched := nullif(trim(v_settings.office_ip_address), '') is not null
    and trim(coalesce(p_ip_address, '')) = trim(v_settings.office_ip_address);
  if p_latitude is not null and p_longitude is not null then
    v_distance := public.distance_meters(p_latitude, p_longitude, v_workplace.latitude, v_workplace.longitude);
    if p_accuracy is null or p_accuracy > v_workplace.low_accuracy_threshold_meters then v_location_status := 'low_accuracy';
    elsif v_distance <= v_workplace.allowed_radius_meters then v_location_status := 'inside';
    else v_location_status := 'outside'; end if;
  else
    v_location_status := case when p_location_status in ('permission_denied','unavailable') then p_location_status else 'unavailable' end;
  end if;
  if v_ip_matched then v_location_status := 'inside'; end if;
  if v_location_status <> 'inside' and char_length(trim(coalesce(p_note,''))) < 2 then raise exception 'LOCATION_REASON_REQUIRED'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_date) and month = extract(month from v_date) and status = 'closed') then raise exception 'MONTH_CLOSED'; end if;
  insert into public.attendance_events (employee_id, work_date, action_type, idempotency_key)
  values (v_user.id, v_date, p_action, p_idempotency_key);
  if p_action = 'clock_in' then
    if exists (select 1 from public.attendance_records where employee_id = v_user.id and work_date = v_date and clock_in_at is not null and deleted_at is null) then raise exception 'ALREADY_CLOCKED_IN'; end if;
    v_attendance_status := case
      when p_work_type = 'field' then 'field' when p_work_type = 'business_trip' then 'business_trip'
      when p_work_type = 'education' then 'education'
      when v_location_status <> 'inside' then 'admin_review'
      when (v_now at time zone 'Asia/Seoul')::time > v_settings.default_start_time + make_interval(mins => v_settings.late_grace_minutes) then 'late'
      else 'working' end;
    insert into public.attendance_records (employee_id, work_date, work_type, clock_in_at, clock_in_accuracy, clock_in_distance, clock_in_location_status, clock_in_ip_address, clock_in_ip_matched, attendance_status, note)
    values (v_user.id, v_date, p_work_type, v_now, p_accuracy, v_distance, v_location_status, nullif(trim(p_ip_address), ''), v_ip_matched, v_attendance_status, coalesce(p_note,''))
    on conflict (employee_id, work_date) do update set work_type = excluded.work_type, clock_in_at = excluded.clock_in_at,
      clock_in_accuracy = excluded.clock_in_accuracy, clock_in_distance = excluded.clock_in_distance,
      clock_in_location_status = excluded.clock_in_location_status, clock_in_ip_address = excluded.clock_in_ip_address,
      clock_in_ip_matched = excluded.clock_in_ip_matched, attendance_status = excluded.attendance_status,
      clock_out_at = null, clock_out_accuracy = null, clock_out_distance = null,
      clock_out_location_status = 'not_checked', clock_out_ip_address = null, clock_out_ip_matched = false,
      note = excluded.note, deleted_at = null, deleted_by = null, deletion_reason = '', updated_at = now()
    returning * into v_record;
  else
    select * into v_record from public.attendance_records where employee_id = v_user.id and work_date = v_date and deleted_at is null for update;
    if not found or v_record.clock_in_at is null then raise exception 'CLOCK_IN_REQUIRED'; end if;
    if v_record.clock_out_at is not null then raise exception 'ALREADY_CLOCKED_OUT'; end if;
    v_attendance_status := case
      when v_record.work_type = 'field' then 'field' when v_record.work_type = 'business_trip' then 'business_trip'
      when v_record.work_type = 'education' then 'education'
      when v_record.attendance_status = 'late' then 'late'
      when v_location_status <> 'inside' then 'admin_review'
      when (v_now at time zone 'Asia/Seoul')::time < v_settings.default_end_time - make_interval(mins => v_settings.early_leave_grace_minutes) then 'early_leave'
      else 'normal' end;
    update public.attendance_records set clock_out_at = v_now, clock_out_accuracy = p_accuracy,
      clock_out_distance = v_distance, clock_out_location_status = v_location_status,
      clock_out_ip_address = nullif(trim(p_ip_address), ''), clock_out_ip_matched = v_ip_matched,
      attendance_status = v_attendance_status,
      note = trim(concat_ws(E'\n', nullif(note,''), nullif(coalesce(p_note,''),'')))
    where id = v_record.id returning * into v_record;
  end if;
  update public.attendance_events set attendance_record_id = v_record.id
  where employee_id = v_user.id and idempotency_key = p_idempotency_key;
  insert into public.attendance_locations (attendance_record_id, employee_id, event_type, latitude, longitude, ip_address, ip_matched, captured_at)
  values (v_record.id, v_user.id, p_action, p_latitude, p_longitude, nullif(trim(p_ip_address), ''), v_ip_matched, v_now)
  on conflict (attendance_record_id, event_type) do update set latitude = excluded.latitude, longitude = excluded.longitude, ip_address = excluded.ip_address, ip_matched = excluded.ip_matched, captured_at = excluded.captured_at;
  insert into public.attendance_audit_logs (attendance_record_id, employee_id, action_type, changed_field, after_value, reason, changed_by, changed_by_role)
  values (v_record.id, v_user.id, p_action, p_action || '_at', v_now::text, coalesce(p_note,''), v_user.id, v_user.role);
  return v_record.id;
exception when unique_violation then
  raise exception 'DUPLICATE_CLOCK_REQUEST';
end $$;

create or replace function public.admin_update_attendance(
  p_record_id uuid,
  p_clock_in_time time,
  p_clock_out_time time,
  p_work_type text,
  p_attendance_status text,
  p_note text,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_before text;
  v_after text;
  v_clock_in timestamptz;
  v_clock_out timestamptz;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  if not exists (select 1 from public.work_type_settings where work_type = p_work_type and is_active) then raise exception 'INVALID_WORK_TYPE'; end if;
  if p_attendance_status not in ('normal','late','early_leave','absent','missing_in','missing_out','location_review','admin_review','field','business_trip','education','leave','holiday_work','working') then raise exception 'INVALID_STATUS'; end if;

  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  v_clock_in := case when p_clock_in_time is null then null else (v_record.work_date::text || ' ' || p_clock_in_time::text)::timestamp at time zone 'Asia/Seoul' end;
  v_clock_out := case when p_clock_out_time is null then null else (v_record.work_date::text || ' ' || p_clock_out_time::text)::timestamp at time zone 'Asia/Seoul' end;
  if v_clock_out is not null and (v_clock_in is null or v_clock_out < v_clock_in) then raise exception 'INVALID_TIME_RANGE'; end if;

  v_before := jsonb_build_object('clock_in_at',v_record.clock_in_at,'clock_out_at',v_record.clock_out_at,'work_type',v_record.work_type,'attendance_status',v_record.attendance_status,'note',v_record.note)::text;
  update public.attendance_records
  set clock_in_at = v_clock_in,
      clock_out_at = v_clock_out,
      work_type = p_work_type,
      attendance_status = p_attendance_status,
      note = coalesce(p_note,''),
      changed = true,
      updated_at = now()
  where id = p_record_id
  returning jsonb_build_object('clock_in_at',clock_in_at,'clock_out_at',clock_out_at,'work_type',work_type,'attendance_status',attendance_status,'note',note)::text into v_after;

  insert into public.attendance_audit_logs (attendance_record_id, employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role)
  values (v_record.id, v_record.employee_id, 'admin_update', 'attendance_record', v_before, v_after, trim(p_reason), auth.uid(), v_role);
end $$;

create or replace function public.admin_delete_attendance(p_record_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_before text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  v_before := jsonb_build_object('work_date',v_record.work_date,'clock_in_at',v_record.clock_in_at,'clock_out_at',v_record.clock_out_at,'work_type',v_record.work_type,'attendance_status',v_record.attendance_status,'note',v_record.note)::text;
  delete from public.attendance_events where employee_id = v_record.employee_id and work_date = v_record.work_date;
  update public.attendance_records set deleted_at = now(), deleted_by = auth.uid(), deletion_reason = trim(p_reason), updated_at = now() where id = p_record_id;
  insert into public.attendance_audit_logs (attendance_record_id, employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role)
  values (v_record.id, v_record.employee_id, 'admin_delete', 'attendance_record', v_before, '목록에서 삭제됨', trim(p_reason), auth.uid(), v_role);
end $$;

create or replace function public.review_correction_request(p_request_id uuid, p_decision text, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
declare v_request public.correction_requests; v_record public.attendance_records; v_role text := public.current_profile_role(); v_before text; v_after text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected','more_info') then raise exception 'INVALID_DECISION'; end if;
  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found or v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_REVIEWABLE'; end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_comment,''))) < 2 then raise exception 'COMMENT_REQUIRED'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_request.target_date) and month = extract(month from v_request.target_date) and status = 'closed') and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if p_decision = 'approved' then
    select * into v_record from public.attendance_records where id = v_request.attendance_record_id and deleted_at is null for update;
    if not found and v_request.request_type = 'clock_in_at' then
      insert into public.attendance_records (employee_id, work_date, work_type, attendance_status, note, changed)
      values (v_request.employee_id, v_request.target_date, 'office', 'missing_out', '수정 요청으로 생성된 기록', true)
      on conflict (employee_id, work_date) do update set changed = true, deleted_at = null, deleted_by = null, deletion_reason = '', updated_at = now()
      returning * into v_record;
      update public.correction_requests set attendance_record_id = v_record.id where id = v_request.id;
    elsif not found then
      raise exception 'CLOCK_IN_CORRECTION_REQUIRED_FIRST';
    end if;
    v_before := case v_request.request_type when 'clock_in_at' then coalesce(v_record.clock_in_at::text,'') when 'clock_out_at' then coalesce(v_record.clock_out_at::text,'') when 'work_type' then v_record.work_type when 'note' then v_record.note when 'attendance_status' then v_record.attendance_status end;
    if v_request.request_type = 'clock_in_at' then update public.attendance_records set clock_in_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true where id = v_record.id;
    elsif v_request.request_type = 'clock_out_at' then update public.attendance_records set clock_out_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true where id = v_record.id;
    elsif v_request.request_type = 'work_type' then update public.attendance_records set work_type = v_request.requested_value, changed = true where id = v_record.id;
    elsif v_request.request_type = 'note' then update public.attendance_records set note = v_request.requested_value, changed = true where id = v_record.id;
    elsif v_request.request_type = 'attendance_status' then update public.attendance_records set attendance_status = v_request.requested_value, changed = true where id = v_record.id; end if;
    v_after := v_request.requested_value;
    insert into public.attendance_audit_logs (attendance_record_id, employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role, correction_request_id)
    values (v_record.id, v_request.employee_id, 'correction_approved', v_request.request_type, v_before, v_after, coalesce(nullif(trim(p_comment),''), v_request.reason), auth.uid(), v_role, v_request.id);
  end if;
  update public.correction_requests set status = p_decision, reviewer_id = auth.uid(), reviewer_comment = coalesce(p_comment,''), reviewed_at = now() where id = p_request_id;
end $$;

create or replace function public.recalculate_attendance_month(p_year integer, p_month integer)
returns void language plpgsql security definer set search_path = public as $$
declare v_start date; v_end date; v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if not public.is_attendance_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  v_start := make_date(p_year, p_month, 1); v_end := (v_start + interval '1 month')::date;
  update public.attendance_records
  set attendance_status = case
      when clock_in_at is null and clock_out_at is not null then 'missing_in'
      when clock_in_at is not null and clock_out_at is null and work_date < v_today then 'missing_out'
      else attendance_status end,
      updated_at = now()
  where work_date >= v_start and work_date < v_end and not is_closed and deleted_at is null;
end $$;

create or replace function public.close_attendance_month(p_year integer, p_month integer)
returns void language plpgsql security definer set search_path = public as $$
declare v_start date; v_end date;
begin
  if not public.is_attendance_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  v_start := make_date(p_year, p_month, 1); v_end := (v_start + interval '1 month')::date;
  if exists (select 1 from public.correction_requests where target_date >= v_start and target_date < v_end and status in ('pending','more_info')) then raise exception 'PENDING_REQUESTS_EXIST'; end if;
  perform public.recalculate_attendance_month(p_year, p_month);
  insert into public.monthly_closings (year, month, closed_by, closed_at, status)
  values (p_year, p_month, auth.uid(), now(), 'closed')
  on conflict (year, month) do update set closed_by = excluded.closed_by, closed_at = excluded.closed_at, status = 'closed';
  update public.attendance_records set is_closed = true where work_date >= v_start and work_date < v_end;
  insert into public.attendance_audit_logs (employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role)
  select id, 'month_closed', 'is_closed', 'false', 'true', format('%s년 %s월 월 마감', p_year, p_month), auth.uid(), role from public.profiles where id = auth.uid();
end $$;

create or replace function public.reopen_attendance_month(p_year integer, p_month integer, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_start date; v_end date;
begin
  if not public.is_super_admin() then raise exception 'SUPER_ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REOPEN_REASON_REQUIRED'; end if;
  v_start := make_date(p_year, p_month, 1); v_end := (v_start + interval '1 month')::date;
  update public.monthly_closings set status = 'open', reopened_by = auth.uid(), reopened_at = now(), reopen_reason = p_reason where year = p_year and month = p_month;
  update public.attendance_records set is_closed = false where work_date >= v_start and work_date < v_end;
  insert into public.attendance_audit_logs (employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role)
  select id, 'month_reopened', 'is_closed', 'true', 'false', p_reason, auth.uid(), 'super_admin' from public.profiles where id = auth.uid();
end $$;

create or replace function public.save_workplace_settings(
  p_workplace_name text,
  p_latitude double precision,
  p_longitude double precision,
  p_allowed_radius_meters integer,
  p_low_accuracy_threshold_meters integer
)
returns public.workplaces
language plpgsql
security definer
set search_path = public
as $$
declare
  v_workplace public.workplaces;
begin
  if not public.is_attendance_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then raise exception 'INVALID_COORDINATES'; end if;
  update public.workplaces
  set workplace_name = p_workplace_name, latitude = p_latitude, longitude = p_longitude,
      allowed_radius_meters = p_allowed_radius_meters,
      low_accuracy_threshold_meters = p_low_accuracy_threshold_meters
  where is_active = true
  returning * into v_workplace;
  if not found then
    insert into public.workplaces (workplace_name, latitude, longitude, allowed_radius_meters, low_accuracy_threshold_meters, is_active)
    values (p_workplace_name, p_latitude, p_longitude, p_allowed_radius_meters, p_low_accuracy_threshold_meters, true)
    returning * into v_workplace;
  end if;
  return v_workplace;
end $$;

drop view if exists public.attendance_records_view;
create view public.attendance_records_view with (security_invoker = true) as
select ar.*, p.name as employee_name, p.employee_number, p.department
from public.attendance_records ar join public.profiles p on p.id = ar.employee_id
where ar.deleted_at is null;
grant select on public.attendance_records_view to authenticated;

create or replace view public.correction_requests_view with (security_invoker = true) as
select cr.*, p.name as employee_name, p.employee_number, p.department
from public.correction_requests cr join public.profiles p on p.id = cr.employee_id;

create or replace view public.attendance_audit_logs_view with (security_invoker = true) as
select al.*, employee.name as employee_name, actor.name as changed_by_name, attendance.work_date as target_work_date
from public.attendance_audit_logs al
join public.profiles employee on employee.id = al.employee_id
left join public.profiles actor on actor.id = al.changed_by
left join public.attendance_records attendance on attendance.id = al.attendance_record_id;

alter table public.profiles enable row level security;
alter table public.workplaces enable row level security;
alter table public.organization_settings enable row level security;
alter table public.work_type_settings enable row level security;
alter table public.holidays enable row level security;
alter table public.employee_schedule_overrides enable row level security;
alter table public.attendance_records enable row level security;
alter table public.attendance_locations enable row level security;
alter table public.location_consents enable row level security;
alter table public.correction_requests enable row level security;
alter table public.monthly_closings enable row level security;
alter table public.attendance_audit_logs enable row level security;
alter table public.attendance_events enable row level security;

-- 정책은 같은 프로젝트에서 스키마를 다시 실행해도 충돌하지 않도록 먼저 제거합니다.
drop policy if exists "profiles own or admin read" on public.profiles;
drop policy if exists "super admin manages profiles" on public.profiles;
drop policy if exists "authenticated read workplace summary" on public.workplaces;
drop policy if exists "admin manages workplaces" on public.workplaces;
drop policy if exists "authenticated read organization settings" on public.organization_settings;
drop policy if exists "admin manages organization settings" on public.organization_settings;
drop policy if exists "authenticated read work types" on public.work_type_settings;
drop policy if exists "admin manages work types" on public.work_type_settings;
drop policy if exists "authenticated read holidays" on public.holidays;
drop policy if exists "admin manages holidays" on public.holidays;
drop policy if exists "own or admin schedules read" on public.employee_schedule_overrides;
drop policy if exists "admin manages schedules" on public.employee_schedule_overrides;
drop policy if exists "own or admin attendance read" on public.attendance_records;
drop policy if exists "own raw locations or super admin read" on public.attendance_locations;
drop policy if exists "own consent read" on public.location_consents;
drop policy if exists "own consent insert" on public.location_consents;
drop policy if exists "own consent update" on public.location_consents;
drop policy if exists "own or admin correction read" on public.correction_requests;
drop policy if exists "own correction insert" on public.correction_requests;
drop policy if exists "admin correction update" on public.correction_requests;
drop policy if exists "authenticated closing read" on public.monthly_closings;
drop policy if exists "admin audit read" on public.attendance_audit_logs;

create policy "profiles own or admin read" on public.profiles for select to authenticated using (id = auth.uid() or public.is_attendance_admin());
create policy "super admin manages profiles" on public.profiles for update to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "authenticated read workplace summary" on public.workplaces for select to authenticated using (is_active);
create policy "admin manages workplaces" on public.workplaces for all to authenticated using (public.is_attendance_admin()) with check (public.is_attendance_admin());
create policy "authenticated read organization settings" on public.organization_settings for select to authenticated using (true);
create policy "admin manages organization settings" on public.organization_settings for all to authenticated using (public.is_attendance_admin()) with check (public.is_attendance_admin());
create policy "authenticated read work types" on public.work_type_settings for select to authenticated using (is_active or public.is_attendance_admin());
create policy "admin manages work types" on public.work_type_settings for all to authenticated using (public.is_attendance_admin()) with check (public.is_attendance_admin());
create policy "authenticated read holidays" on public.holidays for select to authenticated using (true);
create policy "admin manages holidays" on public.holidays for all to authenticated using (public.is_attendance_admin()) with check (public.is_attendance_admin());
create policy "own or admin schedules read" on public.employee_schedule_overrides for select to authenticated using (employee_id = auth.uid() or public.is_attendance_admin());
create policy "admin manages schedules" on public.employee_schedule_overrides for all to authenticated using (public.is_attendance_admin()) with check (public.is_attendance_admin());
create policy "own or admin attendance read" on public.attendance_records for select to authenticated using (employee_id = auth.uid() or public.is_attendance_admin());
create policy "own raw locations or super admin read" on public.attendance_locations for select to authenticated using (employee_id = auth.uid() or public.is_super_admin());
create policy "own consent read" on public.location_consents for select to authenticated using (employee_id = auth.uid() or public.is_attendance_admin());
create policy "own consent insert" on public.location_consents for insert to authenticated with check (employee_id = auth.uid());
create policy "own consent update" on public.location_consents for update to authenticated using (employee_id = auth.uid()) with check (employee_id = auth.uid());
create policy "own or admin correction read" on public.correction_requests for select to authenticated using (employee_id = auth.uid() or public.is_attendance_admin());
create policy "own correction insert" on public.correction_requests for insert to authenticated with check (employee_id = auth.uid() and status = 'pending' and reviewer_id is null and reviewed_at is null);
create policy "admin correction update" on public.correction_requests for update to authenticated using (public.is_attendance_admin()) with check (public.is_attendance_admin());
create policy "authenticated closing read" on public.monthly_closings for select to authenticated using (true);
create policy "admin audit read" on public.attendance_audit_logs for select to authenticated using (public.is_attendance_admin());

-- 직접 쓰기는 차단합니다. 출퇴근, 승인, 마감은 security definer 함수만 사용합니다.
revoke insert, update, delete on public.attendance_records from authenticated;
revoke insert, update, delete on public.attendance_locations from authenticated;
revoke insert, update, delete on public.attendance_audit_logs from authenticated;
revoke insert, update, delete on public.attendance_events from authenticated;
revoke insert, update, delete on public.monthly_closings from authenticated;
revoke update, delete on public.correction_requests from authenticated;
grant execute on function public.clock_attendance(text,text,double precision,double precision,numeric,text,text,text,uuid) to authenticated;
grant execute on function public.admin_update_attendance(uuid,time,time,text,text,text,text) to authenticated;
grant execute on function public.admin_delete_attendance(uuid,text) to authenticated;
grant execute on function public.review_correction_request(uuid,text,text) to authenticated;
grant execute on function public.recalculate_attendance_month(integer,integer) to authenticated;
grant execute on function public.close_attendance_month(integer,integer) to authenticated;
grant execute on function public.reopen_attendance_month(integer,integer,text) to authenticated;
revoke all on function public.save_workplace_settings(text,double precision,double precision,integer,integer) from public, anon;
grant execute on function public.save_workplace_settings(text,double precision,double precision,integer,integer) to authenticated;

create or replace function public.save_organization_settings(
  p_default_start_time time,
  p_default_end_time time,
  p_break_minutes integer,
  p_late_grace_minutes integer,
  p_early_leave_grace_minutes integer,
  p_office_ip_address text
)
returns public.organization_settings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.organization_settings;
begin
  if not public.is_attendance_admin() then
    raise exception 'ADMIN_REQUIRED';
  end if;

  insert into public.organization_settings (
    id, default_start_time, default_end_time, break_minutes,
    late_grace_minutes, early_leave_grace_minutes, office_ip_address, updated_by
  ) values (
    true, p_default_start_time, p_default_end_time, p_break_minutes,
    p_late_grace_minutes, p_early_leave_grace_minutes, trim(coalesce(p_office_ip_address,'')), auth.uid()
  )
  on conflict (id) do update
  set default_start_time = excluded.default_start_time,
      default_end_time = excluded.default_end_time,
      break_minutes = excluded.break_minutes,
      late_grace_minutes = excluded.late_grace_minutes,
      early_leave_grace_minutes = excluded.early_leave_grace_minutes,
      office_ip_address = excluded.office_ip_address,
      updated_by = auth.uid(),
      updated_at = now()
  returning * into v_settings;

  return v_settings;
end $$;

revoke all on function public.save_organization_settings(time,time,integer,integer,integer,text) from public, anon;
grant execute on function public.save_organization_settings(time,time,integer,integer,integer,text) to authenticated;

-- 감사 로그는 관리자도 삭제할 수 없습니다.
revoke delete on public.attendance_audit_logs from anon, authenticated;


-- ============================================================================
-- supabase/upgrade_attendance_exceptions_and_clock_fix.sql
-- ============================================================================

begin;

create table if not exists public.attendance_exceptions (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.profiles(id) on delete restrict,
  start_date date not null,
  end_date date not null,
  exception_type text not null check (exception_type in ('business_trip','approved_other')),
  reason text not null default '',
  approved_by uuid not null references public.profiles(id) on delete restrict,
  approved_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles(id) on delete restrict,
  cancellation_reason text not null default '',
  created_at timestamptz not null default now(),
  check (end_date >= start_date)
);

create index if not exists attendance_exceptions_period_idx
  on public.attendance_exceptions (employee_id, start_date, end_date)
  where cancelled_at is null;

alter table public.attendance_exceptions enable row level security;
drop policy if exists "own or admin exception read" on public.attendance_exceptions;
create policy "own or admin exception read" on public.attendance_exceptions
  for select to authenticated
  using (employee_id = auth.uid() or public.is_attendance_admin());

revoke insert, update, delete on public.attendance_exceptions from authenticated;

drop view if exists public.attendance_exceptions_view;
create view public.attendance_exceptions_view with (security_invoker = true) as
select
  ae.*,
  employee.name as employee_name,
  approver.name as approved_by_name
from public.attendance_exceptions ae
join public.profiles employee on employee.id = ae.employee_id
join public.profiles approver on approver.id = ae.approved_by;
grant select on public.attendance_exceptions_view to authenticated;

create or replace function public.admin_create_attendance_exception(
  p_employee_id uuid,
  p_start_date date,
  p_end_date date,
  p_exception_type text,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_id uuid;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_end_date < p_start_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_exception_type not in ('business_trip','approved_other') then raise exception 'INVALID_EXCEPTION_TYPE'; end if;
  if not exists (select 1 from public.profiles where id = p_employee_id and role = 'employee' and is_active = true) then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if exists (
    select 1 from public.attendance_exceptions
    where employee_id = p_employee_id
      and cancelled_at is null
      and start_date <= p_end_date
      and end_date >= p_start_date
  ) then raise exception 'EXCEPTION_OVERLAP'; end if;

  insert into public.attendance_exceptions (employee_id, start_date, end_date, exception_type, reason, approved_by)
  values (p_employee_id, p_start_date, p_end_date, p_exception_type, trim(coalesce(p_reason,'')), auth.uid())
  returning id into v_id;

  insert into public.attendance_audit_logs (employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role)
  values (
    p_employee_id,
    'exception_create',
    'attendance_exception',
    '',
    jsonb_build_object('id',v_id,'start_date',p_start_date,'end_date',p_end_date,'exception_type',p_exception_type)::text,
    trim(coalesce(p_reason,'')),
    auth.uid(),
    v_role
  );
  return v_id;
end $$;

create or replace function public.admin_cancel_attendance_exception(p_exception_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_item public.attendance_exceptions;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_item from public.attendance_exceptions where id = p_exception_id and cancelled_at is null for update;
  if not found then raise exception 'EXCEPTION_NOT_FOUND'; end if;

  update public.attendance_exceptions
  set cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = trim(p_reason)
  where id = p_exception_id;

  insert into public.attendance_audit_logs (employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role)
  values (
    v_item.employee_id,
    'exception_cancel',
    'attendance_exception',
    jsonb_build_object('id',v_item.id,'start_date',v_item.start_date,'end_date',v_item.end_date,'exception_type',v_item.exception_type)::text,
    '취소됨',
    trim(p_reason),
    auth.uid(),
    v_role
  );
end $$;

revoke all on function public.admin_create_attendance_exception(uuid,date,date,text,text) from public, anon;
grant execute on function public.admin_create_attendance_exception(uuid,date,date,text,text) to authenticated;
revoke all on function public.admin_cancel_attendance_exception(uuid,text) from public, anon;
grant execute on function public.admin_cancel_attendance_exception(uuid,text) to authenticated;

create or replace function public.recalculate_attendance_month(p_year integer, p_month integer)
returns void language plpgsql security definer set search_path = public as $$
declare v_start date; v_end date; v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if not public.is_attendance_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  v_start := make_date(p_year, p_month, 1); v_end := (v_start + interval '1 month')::date;
  insert into public.attendance_records (employee_id, work_date, work_type, attendance_status, note)
  select p.id, day::date, 'office', 'absent', '자동 판정, 출퇴근기록 없음'
  from public.profiles p
  cross join generate_series(v_start, least(v_end - 1, v_today - 1), interval '1 day') day
  left join public.employee_schedule_overrides o on o.employee_id = p.id and o.work_date = day::date
  left join public.holidays h on h.holiday_date = day::date
  cross join public.organization_settings s
  where p.role = 'employee' and p.is_active
    and coalesce(o.is_workday, extract(isodow from day)::smallint = any(s.work_days))
    and h.holiday_date is null
    and not exists (
      select 1 from public.attendance_exceptions ae
      where ae.employee_id = p.id
        and ae.cancelled_at is null
        and day::date between ae.start_date and ae.end_date
    )
    and not exists (select 1 from public.attendance_records ar where ar.employee_id = p.id and ar.work_date = day::date)
  on conflict (employee_id, work_date) do nothing;
  update public.attendance_records
  set attendance_status = case
      when clock_in_at is null and clock_out_at is null then 'absent'
      when clock_in_at is null then 'missing_in'
      when clock_out_at is null and work_date < v_today then 'missing_out'
      else attendance_status end
  where work_date >= v_start and work_date < v_end and not is_closed
    and not exists (
      select 1 from public.attendance_exceptions ae
      where ae.employee_id = attendance_records.employee_id
        and ae.cancelled_at is null
        and attendance_records.work_date between ae.start_date and ae.end_date
    );
end $$;

revoke all on function public.recalculate_attendance_month(integer,integer) from public, anon;
grant execute on function public.recalculate_attendance_month(integer,integer) to authenticated;

-- 삭제한 당일 기록을 다시 입력할 때 이전 중복방지 행이 저장을 막지 않도록 정리합니다.
delete from public.attendance_events event
using public.attendance_records record
where event.attendance_record_id = record.id
  and record.deleted_at is not null;

create or replace function public.admin_delete_attendance(p_record_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_before text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  v_before := jsonb_build_object('work_date',v_record.work_date,'clock_in_at',v_record.clock_in_at,'clock_out_at',v_record.clock_out_at,'attendance_status',v_record.attendance_status,'note',v_record.note)::text;
  delete from public.attendance_events where employee_id = v_record.employee_id and work_date = v_record.work_date;
  update public.attendance_records set deleted_at = now(), deleted_by = auth.uid(), deletion_reason = trim(p_reason), updated_at = now() where id = p_record_id;
  insert into public.attendance_audit_logs (attendance_record_id, employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role)
  values (v_record.id, v_record.employee_id, 'admin_delete', 'attendance_record', v_before, '목록에서 삭제됨', trim(p_reason), auth.uid(), v_role);
end $$;

revoke all on function public.admin_delete_attendance(uuid,text) from public, anon;
grant execute on function public.admin_delete_attendance(uuid,text) to authenticated;

notify pgrst, 'reload schema';
commit;



-- ============================================================================
-- supabase/upgrade_ip_edit_delete.sql
-- ============================================================================

begin;

alter table public.organization_settings add column if not exists office_ip_address text not null default '';
alter table public.attendance_records add column if not exists clock_in_ip_address text;
alter table public.attendance_records add column if not exists clock_in_ip_matched boolean not null default false;
alter table public.attendance_records add column if not exists clock_out_ip_address text;
alter table public.attendance_records add column if not exists clock_out_ip_matched boolean not null default false;
alter table public.attendance_records add column if not exists deleted_at timestamptz;
alter table public.attendance_records add column if not exists deleted_by uuid references public.profiles(id) on delete restrict;
alter table public.attendance_records add column if not exists deletion_reason text not null default '';
alter table public.attendance_locations add column if not exists ip_address text;
alter table public.attendance_locations add column if not exists ip_matched boolean not null default false;

create or replace function public.clock_attendance(
  p_action text,
  p_work_type text,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy numeric,
  p_location_status text,
  p_ip_address text,
  p_note text,
  p_idempotency_key uuid
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_user public.profiles;
  v_workplace public.workplaces;
  v_settings public.organization_settings;
  v_record public.attendance_records;
  v_now timestamptz := now();
  v_date date := (now() at time zone 'Asia/Seoul')::date;
  v_distance numeric;
  v_location_status text;
  v_ip_matched boolean := false;
  v_attendance_status text;
begin
  if p_action not in ('clock_in','clock_out') then raise exception 'INVALID_ACTION'; end if;
  select * into v_user from public.profiles where id = auth.uid() and is_active = true;
  if not found then raise exception 'INACTIVE_OR_UNKNOWN_USER'; end if;
  if not exists (select 1 from public.work_type_settings where work_type = p_work_type and is_active) then raise exception 'INVALID_WORK_TYPE'; end if;
  select * into v_workplace from public.workplaces where is_active order by created_at limit 1;
  if not found then raise exception 'WORKPLACE_NOT_CONFIGURED'; end if;
  select * into v_settings from public.organization_settings where id = true;
  v_ip_matched := nullif(trim(v_settings.office_ip_address), '') is not null
    and trim(coalesce(p_ip_address, '')) = trim(v_settings.office_ip_address);

  if p_latitude is not null and p_longitude is not null then
    v_distance := public.distance_meters(p_latitude, p_longitude, v_workplace.latitude, v_workplace.longitude);
    if p_accuracy is null or p_accuracy > v_workplace.low_accuracy_threshold_meters then v_location_status := 'low_accuracy';
    elsif v_distance <= v_workplace.allowed_radius_meters then v_location_status := 'inside';
    else v_location_status := 'outside'; end if;
  else
    v_location_status := case when p_location_status in ('permission_denied','unavailable') then p_location_status else 'unavailable' end;
  end if;
  if v_ip_matched then v_location_status := 'inside'; end if;
  if v_location_status <> 'inside' and char_length(trim(coalesce(p_note,''))) < 2 then raise exception 'LOCATION_REASON_REQUIRED'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_date) and month = extract(month from v_date) and status = 'closed') then raise exception 'MONTH_CLOSED'; end if;

  insert into public.attendance_events (employee_id, work_date, action_type, idempotency_key)
  values (v_user.id, v_date, p_action, p_idempotency_key);

  if p_action = 'clock_in' then
    if exists (select 1 from public.attendance_records where employee_id = v_user.id and work_date = v_date and clock_in_at is not null and deleted_at is null) then raise exception 'ALREADY_CLOCKED_IN'; end if;
    v_attendance_status := case
      when p_work_type = 'field' then 'field'
      when p_work_type = 'business_trip' then 'business_trip'
      when p_work_type = 'education' then 'education'
      when v_location_status <> 'inside' then 'admin_review'
      when (v_now at time zone 'Asia/Seoul')::time > v_settings.default_start_time + make_interval(mins => v_settings.late_grace_minutes) then 'late'
      else 'working' end;
    insert into public.attendance_records (employee_id, work_date, work_type, clock_in_at, clock_in_accuracy, clock_in_distance, clock_in_location_status, clock_in_ip_address, clock_in_ip_matched, attendance_status, note)
    values (v_user.id, v_date, p_work_type, v_now, p_accuracy, v_distance, v_location_status, nullif(trim(p_ip_address), ''), v_ip_matched, v_attendance_status, coalesce(p_note,''))
    on conflict (employee_id, work_date) do update set
      work_type = excluded.work_type,
      clock_in_at = excluded.clock_in_at,
      clock_in_accuracy = excluded.clock_in_accuracy,
      clock_in_distance = excluded.clock_in_distance,
      clock_in_location_status = excluded.clock_in_location_status,
      clock_in_ip_address = excluded.clock_in_ip_address,
      clock_in_ip_matched = excluded.clock_in_ip_matched,
      attendance_status = excluded.attendance_status,
      clock_out_at = null,
      clock_out_accuracy = null,
      clock_out_distance = null,
      clock_out_location_status = 'not_checked',
      clock_out_ip_address = null,
      clock_out_ip_matched = false,
      note = excluded.note,
      deleted_at = null,
      deleted_by = null,
      deletion_reason = '',
      updated_at = now()
    returning * into v_record;
  else
    select * into v_record from public.attendance_records where employee_id = v_user.id and work_date = v_date and deleted_at is null for update;
    if not found or v_record.clock_in_at is null then raise exception 'CLOCK_IN_REQUIRED'; end if;
    if v_record.clock_out_at is not null then raise exception 'ALREADY_CLOCKED_OUT'; end if;
    v_attendance_status := case
      when v_record.work_type = 'field' then 'field'
      when v_record.work_type = 'business_trip' then 'business_trip'
      when v_record.work_type = 'education' then 'education'
      when v_record.attendance_status = 'late' then 'late'
      when v_location_status <> 'inside' then 'admin_review'
      when (v_now at time zone 'Asia/Seoul')::time < v_settings.default_end_time - make_interval(mins => v_settings.early_leave_grace_minutes) then 'early_leave'
      else 'normal' end;
    update public.attendance_records set
      clock_out_at = v_now,
      clock_out_accuracy = p_accuracy,
      clock_out_distance = v_distance,
      clock_out_location_status = v_location_status,
      clock_out_ip_address = nullif(trim(p_ip_address), ''),
      clock_out_ip_matched = v_ip_matched,
      attendance_status = v_attendance_status,
      note = trim(concat_ws(E'\n', nullif(note,''), nullif(coalesce(p_note,''),'')))
    where id = v_record.id returning * into v_record;
  end if;

  update public.attendance_events set attendance_record_id = v_record.id
  where employee_id = v_user.id and idempotency_key = p_idempotency_key;
  insert into public.attendance_locations (attendance_record_id, employee_id, event_type, latitude, longitude, ip_address, ip_matched, captured_at)
  values (v_record.id, v_user.id, p_action, p_latitude, p_longitude, nullif(trim(p_ip_address), ''), v_ip_matched, v_now)
  on conflict (attendance_record_id, event_type) do update set latitude = excluded.latitude, longitude = excluded.longitude, ip_address = excluded.ip_address, ip_matched = excluded.ip_matched, captured_at = excluded.captured_at;
  insert into public.attendance_audit_logs (attendance_record_id, employee_id, action_type, changed_field, after_value, reason, changed_by, changed_by_role)
  values (v_record.id, v_user.id, p_action, p_action || '_at', v_now::text, coalesce(p_note,''), v_user.id, v_user.role);
  return v_record.id;
exception when unique_violation then
  raise exception 'DUPLICATE_CLOCK_REQUEST';
end $$;

create or replace function public.review_correction_request(p_request_id uuid, p_decision text, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
declare v_request public.correction_requests; v_record public.attendance_records; v_role text := public.current_profile_role(); v_before text; v_after text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected','more_info') then raise exception 'INVALID_DECISION'; end if;
  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found or v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_REVIEWABLE'; end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_comment,''))) < 2 then raise exception 'COMMENT_REQUIRED'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_request.target_date) and month = extract(month from v_request.target_date) and status = 'closed') and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if p_decision = 'approved' then
    select * into v_record from public.attendance_records where id = v_request.attendance_record_id and deleted_at is null for update;
    if not found and v_request.request_type = 'clock_in_at' then
      insert into public.attendance_records (employee_id, work_date, work_type, attendance_status, note, changed)
      values (v_request.employee_id, v_request.target_date, 'office', 'missing_out', '수정 요청으로 생성된 기록', true)
      on conflict (employee_id, work_date) do update set changed = true, deleted_at = null, deleted_by = null, deletion_reason = '', updated_at = now()
      returning * into v_record;
      update public.correction_requests set attendance_record_id = v_record.id where id = v_request.id;
    elsif not found then
      raise exception 'CLOCK_IN_CORRECTION_REQUIRED_FIRST';
    end if;
    v_before := case v_request.request_type when 'clock_in_at' then coalesce(v_record.clock_in_at::text,'') when 'clock_out_at' then coalesce(v_record.clock_out_at::text,'') when 'work_type' then v_record.work_type when 'note' then v_record.note when 'attendance_status' then v_record.attendance_status end;
    if v_request.request_type = 'clock_in_at' then update public.attendance_records set clock_in_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true, updated_at = now() where id = v_record.id;
    elsif v_request.request_type = 'clock_out_at' then update public.attendance_records set clock_out_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true, updated_at = now() where id = v_record.id;
    elsif v_request.request_type = 'work_type' then update public.attendance_records set work_type = v_request.requested_value, changed = true, updated_at = now() where id = v_record.id;
    elsif v_request.request_type = 'note' then update public.attendance_records set note = v_request.requested_value, changed = true, updated_at = now() where id = v_record.id;
    elsif v_request.request_type = 'attendance_status' then update public.attendance_records set attendance_status = v_request.requested_value, changed = true, updated_at = now() where id = v_record.id; end if;
    v_after := v_request.requested_value;
    insert into public.attendance_audit_logs (attendance_record_id, employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role, correction_request_id)
    values (v_record.id, v_request.employee_id, 'correction_approved', v_request.request_type, v_before, v_after, coalesce(nullif(trim(p_comment),''), v_request.reason), auth.uid(), v_role, v_request.id);
  end if;
  update public.correction_requests set status = p_decision, reviewer_id = auth.uid(), reviewer_comment = coalesce(p_comment,''), reviewed_at = now() where id = p_request_id;
end $$;

create or replace function public.admin_update_attendance(
  p_record_id uuid,
  p_clock_in_time time,
  p_clock_out_time time,
  p_work_type text,
  p_attendance_status text,
  p_note text,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_before text;
  v_after text;
  v_clock_in timestamptz;
  v_clock_out timestamptz;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  if not exists (select 1 from public.work_type_settings where work_type = p_work_type and is_active) then raise exception 'INVALID_WORK_TYPE'; end if;
  if p_attendance_status not in ('normal','late','early_leave','absent','missing_in','missing_out','location_review','admin_review','field','business_trip','education','leave','holiday_work','working') then raise exception 'INVALID_STATUS'; end if;
  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  v_clock_in := case when p_clock_in_time is null then null else (v_record.work_date::text || ' ' || p_clock_in_time::text)::timestamp at time zone 'Asia/Seoul' end;
  v_clock_out := case when p_clock_out_time is null then null else (v_record.work_date::text || ' ' || p_clock_out_time::text)::timestamp at time zone 'Asia/Seoul' end;
  if v_clock_out is not null and (v_clock_in is null or v_clock_out < v_clock_in) then raise exception 'INVALID_TIME_RANGE'; end if;
  v_before := jsonb_build_object('clock_in_at',v_record.clock_in_at,'clock_out_at',v_record.clock_out_at,'work_type',v_record.work_type,'attendance_status',v_record.attendance_status,'note',v_record.note)::text;
  update public.attendance_records set clock_in_at = v_clock_in, clock_out_at = v_clock_out, work_type = p_work_type, attendance_status = p_attendance_status, note = coalesce(p_note,''), changed = true, updated_at = now()
  where id = p_record_id
  returning jsonb_build_object('clock_in_at',clock_in_at,'clock_out_at',clock_out_at,'work_type',work_type,'attendance_status',attendance_status,'note',note)::text into v_after;
  insert into public.attendance_audit_logs (attendance_record_id, employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role)
  values (v_record.id, v_record.employee_id, 'admin_update', 'attendance_record', v_before, v_after, trim(p_reason), auth.uid(), v_role);
end $$;

create or replace function public.admin_delete_attendance(p_record_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_before text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  v_before := jsonb_build_object('work_date',v_record.work_date,'clock_in_at',v_record.clock_in_at,'clock_out_at',v_record.clock_out_at,'work_type',v_record.work_type,'attendance_status',v_record.attendance_status,'note',v_record.note)::text;
  delete from public.attendance_events where employee_id = v_record.employee_id and work_date = v_record.work_date;
  update public.attendance_records set deleted_at = now(), deleted_by = auth.uid(), deletion_reason = trim(p_reason), updated_at = now() where id = p_record_id;
  insert into public.attendance_audit_logs (attendance_record_id, employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role)
  values (v_record.id, v_record.employee_id, 'admin_delete', 'attendance_record', v_before, '목록에서 삭제됨', trim(p_reason), auth.uid(), v_role);
end $$;

create or replace function public.save_organization_settings(
  p_default_start_time time,
  p_default_end_time time,
  p_break_minutes integer,
  p_late_grace_minutes integer,
  p_early_leave_grace_minutes integer,
  p_office_ip_address text
)
returns public.organization_settings
language plpgsql security definer set search_path = public as $$
declare v_settings public.organization_settings;
begin
  if not public.is_attendance_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  insert into public.organization_settings (id, default_start_time, default_end_time, break_minutes, late_grace_minutes, early_leave_grace_minutes, office_ip_address, updated_by)
  values (true, p_default_start_time, p_default_end_time, p_break_minutes, p_late_grace_minutes, p_early_leave_grace_minutes, trim(coalesce(p_office_ip_address,'')), auth.uid())
  on conflict (id) do update set default_start_time = excluded.default_start_time, default_end_time = excluded.default_end_time, break_minutes = excluded.break_minutes, late_grace_minutes = excluded.late_grace_minutes, early_leave_grace_minutes = excluded.early_leave_grace_minutes, office_ip_address = excluded.office_ip_address, updated_by = auth.uid(), updated_at = now()
  returning * into v_settings;
  return v_settings;
end $$;

drop view if exists public.attendance_records_view;
create view public.attendance_records_view with (security_invoker = true) as
select ar.*, p.name as employee_name, p.employee_number, p.department
from public.attendance_records ar join public.profiles p on p.id = ar.employee_id
where ar.deleted_at is null;
grant select on public.attendance_records_view to authenticated;

revoke all on function public.clock_attendance(text,text,double precision,double precision,numeric,text,text,text,uuid) from public, anon;
grant execute on function public.clock_attendance(text,text,double precision,double precision,numeric,text,text,text,uuid) to authenticated;
revoke all on function public.clock_attendance(text,text,double precision,double precision,numeric,text,text,uuid) from public, anon, authenticated;
revoke all on function public.review_correction_request(uuid,text,text) from public, anon;
grant execute on function public.review_correction_request(uuid,text,text) to authenticated;
revoke all on function public.admin_update_attendance(uuid,time,time,text,text,text,text) from public, anon;
grant execute on function public.admin_update_attendance(uuid,time,time,text,text,text,text) to authenticated;
revoke all on function public.admin_delete_attendance(uuid,text) from public, anon;
grant execute on function public.admin_delete_attendance(uuid,text) to authenticated;
revoke all on function public.save_organization_settings(time,time,integer,integer,integer,text) from public, anon;
grant execute on function public.save_organization_settings(time,time,integer,integer,integer,text) to authenticated;

commit;


-- ============================================================================
-- supabase/upgrade_overtime_leave_comp_time.sql
-- ============================================================================

-- 시간외근무, 연차, 대체휴무, 병가 기능 보완
-- Supabase SQL Editor에서 이 파일 전체를 한 번 실행합니다.

begin;

alter table public.attendance_records add column if not exists raw_overtime_minutes integer not null default 0;
alter table public.attendance_records add column if not exists recorded_overtime_minutes integer not null default 0;
alter table public.attendance_records add column if not exists overtime_status text not null default 'none';
alter table public.attendance_records add column if not exists approved_overtime_minutes integer not null default 0;
alter table public.attendance_records add column if not exists leave_type text not null default 'none';

create table if not exists public.comp_time_credits (
  id uuid primary key default gen_random_uuid(),
  attendance_record_id uuid not null unique references public.attendance_records(id) on delete restrict,
  employee_id uuid not null references public.profiles(id) on delete restrict,
  granted_minutes integer not null check (granted_minutes between 30 and 240),
  remaining_minutes integer not null check (remaining_minutes between 0 and 240),
  expires_on date not null,
  granted_by uuid not null references public.profiles(id) on delete restrict,
  granted_at timestamptz not null default now(),
  reason text not null default ''
);

create table if not exists public.comp_time_usage_allocations (
  id uuid primary key default gen_random_uuid(),
  correction_request_id uuid not null references public.correction_requests(id) on delete restrict,
  credit_id uuid not null references public.comp_time_credits(id) on delete restrict,
  used_minutes integer not null check (used_minutes > 0),
  created_at timestamptz not null default now(),
  unique (correction_request_id, credit_id)
);

update public.attendance_records set attendance_status = 'admin_review' where attendance_status = 'early_leave';

do $$
declare item record;
begin
  for item in
    select conname from pg_constraint
    where conrelid = 'public.attendance_records'::regclass and contype = 'c'
      and (pg_get_constraintdef(oid) ilike '%attendance_status%' or pg_get_constraintdef(oid) ilike '%overtime_status%' or pg_get_constraintdef(oid) ilike '%leave_type%' or pg_get_constraintdef(oid) ilike '%overtime_minutes%')
  loop execute format('alter table public.attendance_records drop constraint %I', item.conname); end loop;
  for item in
    select conname from pg_constraint
    where conrelid = 'public.correction_requests'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%request_type%'
  loop execute format('alter table public.correction_requests drop constraint %I', item.conname); end loop;
end $$;

alter table public.attendance_records add constraint attendance_records_attendance_status_check check (attendance_status in (
  'normal','late','absent','missing_in','missing_out','location_review','admin_review','field','business_trip','education','leave','annual_leave','half_day','quarter_day','hourly_leave','sick_leave','holiday_work','working'
)) not valid;
alter table public.attendance_records add constraint attendance_records_overtime_status_check check (overtime_status in ('none','pending','approved','rejected')) not valid;
alter table public.attendance_records add constraint attendance_records_overtime_minutes_check check (raw_overtime_minutes between 0 and 1440 and recorded_overtime_minutes between 0 and 1440 and approved_overtime_minutes between 0 and 1440) not valid;
alter table public.attendance_records add constraint attendance_records_leave_type_check check (leave_type in ('none','annual_leave','half_day','quarter_day','hourly_leave','sick_leave')) not valid;
alter table public.correction_requests add constraint correction_requests_request_type_check check (request_type in ('clock_in_at','clock_out_at','work_type','note','attendance_status','annual_leave','comp_time','sick_leave')) not valid;

-- 2026년 대한민국 공휴일 예시를 반영합니다. 지역 공휴일은 기관 설정에서 별도로 등록합니다.
insert into public.holidays (holiday_date, holiday_name, is_paid_holiday) values
  ('2026-01-01','1월 1일',true),
  ('2026-02-16','설날 연휴',true), ('2026-02-17','설날',true), ('2026-02-18','설날 연휴',true),
  ('2026-03-01','3.1절',true), ('2026-03-02','3.1절 대체공휴일',true),
  ('2026-05-01','노동절',true), ('2026-05-05','어린이날',true),
  ('2026-05-24','부처님오신날',true), ('2026-05-25','부처님오신날 대체공휴일',true),
  ('2026-06-03','전국동시지방선거',true), ('2026-06-06','현충일',true),
  ('2026-07-17','제헌절',true),
  ('2026-08-15','광복절',true), ('2026-08-17','광복절 대체공휴일',true),
  ('2026-09-24','추석 연휴',true), ('2026-09-25','추석',true), ('2026-09-26','추석 연휴',true),
  ('2026-10-03','개천절',true), ('2026-10-05','개천절 대체공휴일',true), ('2026-10-09','한글날',true),
  ('2026-12-25','기독탄신일',true)
on conflict (holiday_date) do update set holiday_name = excluded.holiday_name, is_paid_holiday = excluded.is_paid_holiday;

create or replace function public.recognized_overtime_minutes(p_raw_minutes integer)
returns integer language sql immutable as $$
  select case when coalesce(p_raw_minutes,0) < 60 then 0 else least(240, 60 + floor((p_raw_minutes - 60) / 30.0)::integer * 30) end
$$;

create or replace function public.calculate_raw_overtime_minutes(p_work_date date, p_clock_in timestamptz, p_clock_out timestamptz)
returns integer language plpgsql stable set search_path = public as $$
declare
  v_settings public.organization_settings;
  v_in timestamp;
  v_out timestamp;
  v_is_holiday boolean;
  v_elapsed_minutes integer;
  v_worked_minutes integer;
begin
  if p_clock_in is null or p_clock_out is null or p_clock_out < p_clock_in then return 0; end if;
  select * into v_settings from public.organization_settings where id = true;
  v_in := p_clock_in at time zone 'Asia/Seoul';
  v_out := p_clock_out at time zone 'Asia/Seoul';
  v_is_holiday := extract(isodow from p_work_date)::smallint <> all(v_settings.work_days)
    or exists (select 1 from public.holidays where holiday_date = p_work_date);
  v_elapsed_minutes := greatest(0, floor(extract(epoch from (v_out - v_in)) / 60)::integer);
  v_worked_minutes := greatest(0, v_elapsed_minutes - case when v_elapsed_minutes >= 360 then v_settings.break_minutes else 0 end);
  if v_is_holiday then
    return v_worked_minutes;
  end if;
  return greatest(0, v_worked_minutes - 480);
end $$;

create or replace function public.refresh_attendance_overtime()
returns trigger language plpgsql set search_path = public as $$
declare v_raw integer;
begin
  if new.clock_in_at is null or new.clock_out_at is null then
    new.raw_overtime_minutes := 0; new.recorded_overtime_minutes := 0;
    if tg_op = 'INSERT' or new.overtime_status <> 'approved' then new.overtime_status := 'none'; new.approved_overtime_minutes := 0; end if;
    return new;
  end if;
  if tg_op = 'INSERT' or new.clock_in_at is distinct from old.clock_in_at or new.clock_out_at is distinct from old.clock_out_at then
    v_raw := public.calculate_raw_overtime_minutes(new.work_date, new.clock_in_at, new.clock_out_at);
    new.raw_overtime_minutes := v_raw;
    new.recorded_overtime_minutes := public.recognized_overtime_minutes(v_raw);
    new.overtime_status := case when new.recorded_overtime_minutes > 0 then 'pending' else 'none' end;
    new.approved_overtime_minutes := 0;
  end if;
  return new;
end $$;

drop trigger if exists attendance_refresh_overtime on public.attendance_records;
create trigger attendance_refresh_overtime before insert or update on public.attendance_records for each row execute function public.refresh_attendance_overtime();

create or replace function public.clock_attendance(
  p_action text, p_work_type text, p_latitude double precision, p_longitude double precision,
  p_accuracy numeric, p_location_status text, p_ip_address text, p_note text, p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_user public.profiles; v_workplace public.workplaces; v_settings public.organization_settings;
  v_record public.attendance_records; v_now timestamptz := now(); v_date date := (now() at time zone 'Asia/Seoul')::date;
  v_distance numeric; v_location_status text; v_ip_matched boolean := false; v_attendance_status text;
  v_is_regular_workday boolean; v_raw_overtime integer; v_recorded_overtime integer;
begin
  if p_action not in ('clock_in','clock_out') then raise exception 'INVALID_ACTION'; end if;
  select * into v_user from public.profiles where id = auth.uid() and is_active = true;
  if not found then raise exception 'INACTIVE_OR_UNKNOWN_USER'; end if;
  if not exists (select 1 from public.work_type_settings where work_type = p_work_type and is_active) then raise exception 'INVALID_WORK_TYPE'; end if;
  select * into v_workplace from public.workplaces where is_active order by created_at limit 1;
  if not found then raise exception 'WORKPLACE_NOT_CONFIGURED'; end if;
  select * into v_settings from public.organization_settings where id = true;
  v_is_regular_workday := extract(isodow from v_date)::smallint = any(v_settings.work_days) and not exists (select 1 from public.holidays where holiday_date = v_date);
  v_ip_matched := nullif(trim(v_settings.office_ip_address), '') is not null and trim(coalesce(p_ip_address, '')) = trim(v_settings.office_ip_address);
  if p_latitude is not null and p_longitude is not null then
    v_distance := public.distance_meters(p_latitude, p_longitude, v_workplace.latitude, v_workplace.longitude);
    if p_accuracy is null or p_accuracy > v_workplace.low_accuracy_threshold_meters then v_location_status := 'low_accuracy';
    elsif v_distance <= v_workplace.allowed_radius_meters then v_location_status := 'inside'; else v_location_status := 'outside'; end if;
  else v_location_status := case when p_location_status in ('permission_denied','unavailable') then p_location_status else 'unavailable' end; end if;
  if v_ip_matched then v_location_status := 'inside'; end if;
  if v_location_status <> 'inside' and char_length(trim(coalesce(p_note,''))) < 2 then raise exception 'LOCATION_REASON_REQUIRED'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_date) and month = extract(month from v_date) and status = 'closed') then raise exception 'MONTH_CLOSED'; end if;
  insert into public.attendance_events (employee_id, work_date, action_type, idempotency_key) values (v_user.id, v_date, p_action, p_idempotency_key);
  if p_action = 'clock_in' then
    if exists (select 1 from public.attendance_records where employee_id = v_user.id and work_date = v_date and clock_in_at is not null and deleted_at is null) then raise exception 'ALREADY_CLOCKED_IN'; end if;
    v_attendance_status := case when v_location_status <> 'inside' then 'admin_review' when not v_is_regular_workday then 'holiday_work' when (v_now at time zone 'Asia/Seoul')::time > v_settings.default_start_time + make_interval(mins => v_settings.late_grace_minutes) then 'late' else 'working' end;
    insert into public.attendance_records (employee_id, work_date, work_type, clock_in_at, clock_in_accuracy, clock_in_distance, clock_in_location_status, clock_in_ip_address, clock_in_ip_matched, attendance_status, note, raw_overtime_minutes, recorded_overtime_minutes, overtime_status, approved_overtime_minutes, leave_type)
    values (v_user.id, v_date, 'office', v_now, p_accuracy, v_distance, v_location_status, nullif(trim(p_ip_address), ''), v_ip_matched, v_attendance_status, coalesce(p_note,''), 0, 0, 'none', 0, 'none')
    on conflict (employee_id, work_date) do update set work_type = 'office', clock_in_at = excluded.clock_in_at, clock_in_accuracy = excluded.clock_in_accuracy, clock_in_distance = excluded.clock_in_distance, clock_in_location_status = excluded.clock_in_location_status, clock_in_ip_address = excluded.clock_in_ip_address, clock_in_ip_matched = excluded.clock_in_ip_matched, attendance_status = excluded.attendance_status, clock_out_at = null, clock_out_accuracy = null, clock_out_distance = null, clock_out_location_status = 'not_checked', clock_out_ip_address = null, clock_out_ip_matched = false, note = excluded.note, raw_overtime_minutes = 0, recorded_overtime_minutes = 0, overtime_status = 'none', approved_overtime_minutes = 0, deleted_at = null, deleted_by = null, deletion_reason = '', updated_at = now()
    returning * into v_record;
  else
    select * into v_record from public.attendance_records where employee_id = v_user.id and work_date = v_date and deleted_at is null for update;
    if not found or v_record.clock_in_at is null then raise exception 'CLOCK_IN_REQUIRED'; end if;
    if v_record.clock_out_at is not null then raise exception 'ALREADY_CLOCKED_OUT'; end if;
    v_raw_overtime := public.calculate_raw_overtime_minutes(v_date, v_record.clock_in_at, v_now);
    v_recorded_overtime := public.recognized_overtime_minutes(v_raw_overtime);
    v_attendance_status := case when v_location_status <> 'inside' then 'admin_review' when not v_is_regular_workday then 'holiday_work' when v_record.attendance_status = 'late' then 'late' when greatest(0, floor(extract(epoch from (v_now - v_record.clock_in_at)) / 60)::integer - case when extract(epoch from (v_now - v_record.clock_in_at)) / 60 >= 360 then v_settings.break_minutes else 0 end) < 480 then 'admin_review' else 'normal' end;
    update public.attendance_records set clock_out_at = v_now, clock_out_accuracy = p_accuracy, clock_out_distance = v_distance, clock_out_location_status = v_location_status, clock_out_ip_address = nullif(trim(p_ip_address), ''), clock_out_ip_matched = v_ip_matched, attendance_status = v_attendance_status, raw_overtime_minutes = v_raw_overtime, recorded_overtime_minutes = v_recorded_overtime, overtime_status = case when v_recorded_overtime > 0 then 'pending' else 'none' end, approved_overtime_minutes = 0, note = trim(concat_ws(E'\n', nullif(note,''), nullif(coalesce(p_note,''),''))) where id = v_record.id returning * into v_record;
  end if;
  update public.attendance_events set attendance_record_id = v_record.id where employee_id = v_user.id and idempotency_key = p_idempotency_key;
  insert into public.attendance_locations (attendance_record_id, employee_id, event_type, latitude, longitude, ip_address, ip_matched, captured_at) values (v_record.id, v_user.id, p_action, p_latitude, p_longitude, nullif(trim(p_ip_address), ''), v_ip_matched, v_now) on conflict (attendance_record_id, event_type) do update set latitude = excluded.latitude, longitude = excluded.longitude, ip_address = excluded.ip_address, ip_matched = excluded.ip_matched, captured_at = excluded.captured_at;
  insert into public.attendance_audit_logs (attendance_record_id, employee_id, action_type, changed_field, after_value, reason, changed_by, changed_by_role) values (v_record.id, v_user.id, p_action, p_action || '_at', v_now::text, coalesce(p_note,''), v_user.id, v_user.role);
  return v_record.id;
exception when unique_violation then raise exception 'DUPLICATE_CLOCK_REQUEST';
end $$;

create or replace function public.admin_review_overtime(p_record_id uuid, p_decision text, p_approved_minutes integer, p_comp_time_minutes integer, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records; v_role text := public.current_profile_role(); v_week_start date; v_week_total integer;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'INVALID_DECISION'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if p_decision = 'approved' then
    if p_approved_minutes not in (60,90,120,150,180,210,240) or p_approved_minutes > v_record.recorded_overtime_minutes then raise exception 'INVALID_OVERTIME_MINUTES'; end if;
    if coalesce(p_comp_time_minutes,0) < 0 or coalesce(p_comp_time_minutes,0) > p_approved_minutes or (coalesce(p_comp_time_minutes,0) <> 0 and coalesce(p_comp_time_minutes,0) % 30 <> 0) then raise exception 'INVALID_COMP_TIME_CREDIT'; end if;
    v_week_start := v_record.work_date - (extract(isodow from v_record.work_date)::integer - 1);
    select coalesce(sum(approved_overtime_minutes),0) into v_week_total from public.attendance_records where employee_id = v_record.employee_id and work_date between v_week_start and v_week_start + 6 and id <> v_record.id and overtime_status = 'approved' and deleted_at is null;
    if v_week_total + p_approved_minutes > 720 then raise exception 'WEEKLY_OVERTIME_LIMIT'; end if;
  end if;
  update public.attendance_records set overtime_status = p_decision, approved_overtime_minutes = case when p_decision = 'approved' then p_approved_minutes else 0 end, changed = true where id = p_record_id;
  if p_decision = 'approved' and coalesce(p_comp_time_minutes,0) > 0 then
    insert into public.comp_time_credits (attendance_record_id, employee_id, granted_minutes, remaining_minutes, expires_on, granted_by, reason)
    values (v_record.id, v_record.employee_id, p_comp_time_minutes, p_comp_time_minutes, v_record.work_date + 30, auth.uid(), trim(p_reason))
    on conflict (attendance_record_id) do update set granted_minutes = excluded.granted_minutes, remaining_minutes = greatest(0, excluded.granted_minutes - (public.comp_time_credits.granted_minutes - public.comp_time_credits.remaining_minutes)), expires_on = excluded.expires_on, granted_by = excluded.granted_by, granted_at = now(), reason = excluded.reason;
  elsif p_decision = 'rejected' then
    update public.comp_time_credits set remaining_minutes = 0, reason = trim(concat_ws(E'\n', reason, '시간외근무 반려로 미사용 잔액 소멸')) where attendance_record_id = v_record.id and remaining_minutes > 0;
  end if;
  insert into public.attendance_audit_logs (attendance_record_id, employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role) values (v_record.id, v_record.employee_id, 'overtime_review', 'approved_overtime_minutes', v_record.approved_overtime_minutes::text, case when p_decision = 'approved' then p_approved_minutes::text else '반려' end, trim(p_reason), auth.uid(), v_role);
end $$;

create or replace function public.review_correction_request(p_request_id uuid, p_decision text, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests; v_record public.attendance_records; v_role text := public.current_profile_role();
  v_before text; v_after text; v_minutes integer; v_available integer; v_leave_type text; v_status text; v_credit record; v_use integer;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected','more_info') then raise exception 'INVALID_DECISION'; end if;
  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found or v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_REVIEWABLE'; end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_comment,''))) < 2 then raise exception 'COMMENT_REQUIRED'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_request.target_date) and month = extract(month from v_request.target_date) and status = 'closed') and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if p_decision = 'approved' and v_request.request_type = 'comp_time' then
    v_minutes := v_request.requested_value::integer;
    if v_minutes < 60 or v_minutes % 60 <> 0 then raise exception 'COMP_TIME_HOURLY_ONLY'; end if;
    select coalesce(sum(remaining_minutes),0) into v_available from public.comp_time_credits where employee_id = v_request.employee_id and remaining_minutes > 0 and expires_on >= v_request.target_date and exists (select 1 from public.attendance_records ar where ar.id = attendance_record_id and ar.work_date < v_request.target_date and ar.deleted_at is null);
    if v_minutes > v_available then raise exception 'INSUFFICIENT_COMP_TIME_BALANCE'; end if;
    v_before := v_available::text; v_after := (v_available - v_minutes)::text;
    for v_credit in select c.* from public.comp_time_credits c join public.attendance_records ar on ar.id = c.attendance_record_id where c.employee_id = v_request.employee_id and c.remaining_minutes > 0 and c.expires_on >= v_request.target_date and ar.work_date < v_request.target_date and ar.deleted_at is null order by c.expires_on, ar.work_date for update of c
    loop
      exit when v_minutes <= 0;
      v_use := least(v_minutes, v_credit.remaining_minutes);
      update public.comp_time_credits set remaining_minutes = remaining_minutes - v_use where id = v_credit.id;
      insert into public.comp_time_usage_allocations (correction_request_id, credit_id, used_minutes) values (v_request.id, v_credit.id, v_use);
      v_minutes := v_minutes - v_use;
    end loop;
  elsif p_decision = 'approved' and v_request.request_type in ('annual_leave','sick_leave') then
    v_minutes := v_request.requested_value::integer;
    if v_request.request_type = 'annual_leave' and v_minutes not in (60,120,240,480) then raise exception 'INVALID_ANNUAL_LEAVE_UNIT'; end if;
    if v_request.request_type = 'sick_leave' then v_minutes := 480; end if;
    v_leave_type := case when v_request.request_type = 'sick_leave' then 'sick_leave' when v_minutes = 480 then 'annual_leave' when v_minutes = 240 then 'half_day' when v_minutes = 120 then 'quarter_day' else 'hourly_leave' end;
    v_status := case when v_request.request_type = 'sick_leave' then 'sick_leave' when v_minutes = 480 then 'annual_leave' when v_minutes = 240 then 'half_day' when v_minutes = 120 then 'quarter_day' else 'hourly_leave' end;
    insert into public.attendance_records (employee_id, work_date, work_type, attendance_status, leave_type, note, changed)
    values (v_request.employee_id, v_request.target_date, 'office', v_status, v_leave_type, trim(v_request.reason), true)
    on conflict (employee_id, work_date) do update set leave_type = excluded.leave_type, attendance_status = case when public.attendance_records.clock_in_at is null then excluded.attendance_status else public.attendance_records.attendance_status end, changed = true, deleted_at = null, deleted_by = null, deletion_reason = '', updated_at = now()
    returning * into v_record;
    update public.correction_requests set attendance_record_id = v_record.id where id = v_request.id;
    v_before := '미승인'; v_after := v_leave_type;
  elsif p_decision = 'approved' then
    select * into v_record from public.attendance_records where id = v_request.attendance_record_id and deleted_at is null for update;
    if not found and v_request.request_type = 'clock_in_at' then
      insert into public.attendance_records (employee_id, work_date, work_type, attendance_status, note, changed) values (v_request.employee_id, v_request.target_date, 'office', 'missing_out', '수정 요청으로 생성된 기록', true) on conflict (employee_id, work_date) do update set changed = true, deleted_at = null, deleted_by = null, deletion_reason = '', updated_at = now() returning * into v_record;
      update public.correction_requests set attendance_record_id = v_record.id where id = v_request.id;
    elsif not found then raise exception 'CLOCK_IN_CORRECTION_REQUIRED_FIRST'; end if;
    v_before := case v_request.request_type when 'clock_in_at' then coalesce(v_record.clock_in_at::text,'') when 'clock_out_at' then coalesce(v_record.clock_out_at::text,'') when 'work_type' then v_record.work_type when 'note' then v_record.note when 'attendance_status' then v_record.attendance_status end;
    if v_request.request_type = 'clock_in_at' then update public.attendance_records set clock_in_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true where id = v_record.id;
    elsif v_request.request_type = 'clock_out_at' then update public.attendance_records set clock_out_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true where id = v_record.id;
    elsif v_request.request_type = 'work_type' then update public.attendance_records set work_type = v_request.requested_value, changed = true where id = v_record.id;
    elsif v_request.request_type = 'note' then update public.attendance_records set note = v_request.requested_value, changed = true where id = v_record.id;
    elsif v_request.request_type = 'attendance_status' then update public.attendance_records set attendance_status = v_request.requested_value, changed = true where id = v_record.id; end if;
    v_after := v_request.requested_value;
  end if;
  if p_decision = 'approved' then
    insert into public.attendance_audit_logs (attendance_record_id, employee_id, action_type, changed_field, before_value, after_value, reason, changed_by, changed_by_role, correction_request_id) values (v_record.id, v_request.employee_id, 'correction_approved', v_request.request_type, coalesce(v_before,''), coalesce(v_after,v_request.requested_value), coalesce(nullif(trim(p_comment),''), v_request.reason), auth.uid(), v_role, v_request.id);
  end if;
  update public.correction_requests set status = p_decision, reviewer_id = auth.uid(), reviewer_comment = coalesce(p_comment,''), reviewed_at = now() where id = p_request_id;
end $$;

drop view if exists public.comp_time_balances_view;
create view public.comp_time_balances_view with (security_invoker = true) as
select p.id as employee_id,
  coalesce((select sum(c.granted_minutes) from public.comp_time_credits c where c.employee_id = p.id),0)::integer as approved_overtime_minutes,
  coalesce((select sum(a.used_minutes) from public.comp_time_usage_allocations a join public.comp_time_credits c on c.id = a.credit_id where c.employee_id = p.id),0)::integer as used_comp_time_minutes,
  coalesce((select sum(c.remaining_minutes) from public.comp_time_credits c where c.employee_id = p.id and c.expires_on >= (now() at time zone 'Asia/Seoul')::date),0)::integer as available_comp_time_minutes
from public.profiles p where p.is_active and p.role = 'employee';

alter table public.comp_time_credits enable row level security;
alter table public.comp_time_usage_allocations enable row level security;
drop policy if exists "own or admin comp credits read" on public.comp_time_credits;
drop policy if exists "own or admin comp allocations read" on public.comp_time_usage_allocations;
create policy "own or admin comp credits read" on public.comp_time_credits for select to authenticated using (employee_id = auth.uid() or public.is_attendance_admin());
create policy "own or admin comp allocations read" on public.comp_time_usage_allocations for select to authenticated using (exists (select 1 from public.comp_time_credits c where c.id = credit_id and (c.employee_id = auth.uid() or public.is_attendance_admin())));
revoke insert, update, delete on public.comp_time_credits from authenticated;
revoke insert, update, delete on public.comp_time_usage_allocations from authenticated;
grant select on public.comp_time_balances_view to authenticated;
revoke all on function public.admin_review_overtime(uuid,text,integer,integer,text) from public, anon;
grant execute on function public.admin_review_overtime(uuid,text,integer,integer,text) to authenticated;
grant execute on function public.recognized_overtime_minutes(integer) to authenticated;
grant execute on function public.calculate_raw_overtime_minutes(date,timestamptz,timestamptz) to authenticated;
notify pgrst, 'reload schema';
commit;

select '시간외근무, 연차, 대체휴무, 병가 기능 보완 완료' as result;


-- ============================================================================
-- supabase/upgrade_report_viewer_and_extra_comp_time.sql
-- ============================================================================

begin;

-- 직원 계정을 유지한 채 조회 전용 부관리자 권한을 부여합니다.
alter table public.profiles
  add column if not exists can_view_reports boolean not null default false;

alter table public.attendance_records
  add column if not exists raw_overtime_minutes integer not null default 0;
alter table public.attendance_records
  add column if not exists recorded_overtime_minutes integer not null default 0;
alter table public.attendance_records
  add column if not exists approved_overtime_minutes integer not null default 0;
alter table public.attendance_records
  add column if not exists overtime_status text not null default 'none';
alter table public.attendance_records
  add column if not exists comp_time_eligible_minutes integer not null default 0;

drop view if exists public.attendance_records_view;
create view public.attendance_records_view with (security_invoker = true) as
select ar.*, p.name as employee_name, p.employee_number, p.department
from public.attendance_records ar
join public.profiles p on p.id = ar.employee_id
where ar.deleted_at is null;
grant select on public.attendance_records_view to authenticated;

-- 이전 대체휴무 보완 SQL을 실행하지 않은 기관 데이터베이스에서도
-- 이 파일 하나만으로 적립과 사용 내역을 준비할 수 있게 합니다.
create table if not exists public.comp_time_credits (
  id uuid primary key default gen_random_uuid(),
  attendance_record_id uuid not null unique references public.attendance_records(id) on delete restrict,
  employee_id uuid not null references public.profiles(id) on delete restrict,
  granted_minutes integer not null,
  remaining_minutes integer not null,
  expires_on date not null,
  granted_by uuid not null references public.profiles(id) on delete restrict,
  granted_at timestamptz not null default now(),
  reason text not null default ''
);

create table if not exists public.comp_time_usage_allocations (
  id uuid primary key default gen_random_uuid(),
  correction_request_id uuid not null references public.correction_requests(id) on delete restrict,
  credit_id uuid not null references public.comp_time_credits(id) on delete restrict,
  used_minutes integer not null check (used_minutes > 0),
  created_at timestamptz not null default now(),
  unique (correction_request_id, credit_id)
);

create index if not exists comp_time_credits_employee_expiry_idx
  on public.comp_time_credits (employee_id, expires_on);

alter table public.comp_time_credits enable row level security;
alter table public.comp_time_usage_allocations enable row level security;

alter table public.comp_time_credits drop constraint if exists comp_time_credits_granted_minutes_check;
alter table public.comp_time_credits drop constraint if exists comp_time_credits_remaining_minutes_check;
alter table public.comp_time_credits
  add constraint comp_time_credits_granted_minutes_check check (granted_minutes >= 0),
  add constraint comp_time_credits_remaining_minutes_check check (remaining_minutes >= 0 and remaining_minutes <= granted_minutes);

create or replace function public.can_view_attendance_reports()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and is_active = true
      and (role in ('admin','super_admin') or can_view_reports)
  )
$$;

revoke all on function public.can_view_attendance_reports() from public, anon;
grant execute on function public.can_view_attendance_reports() to authenticated;

drop policy if exists "profiles own or admin read" on public.profiles;
create policy "profiles own or admin read" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.can_view_attendance_reports());

drop policy if exists "own or admin attendance read" on public.attendance_records;
create policy "own or admin attendance read" on public.attendance_records
  for select to authenticated
  using (employee_id = auth.uid() or public.can_view_attendance_reports());

drop policy if exists "own or admin correction read" on public.correction_requests;
create policy "own or admin correction read" on public.correction_requests
  for select to authenticated
  using (employee_id = auth.uid() or public.can_view_attendance_reports());

drop policy if exists "admin audit read" on public.attendance_audit_logs;
create policy "admin audit read" on public.attendance_audit_logs
  for select to authenticated
  using (public.can_view_attendance_reports());

drop policy if exists "own or admin exception read" on public.attendance_exceptions;
create policy "own or admin exception read" on public.attendance_exceptions
  for select to authenticated
  using (employee_id = auth.uid() or public.can_view_attendance_reports());

drop policy if exists "own or admin comp credits read" on public.comp_time_credits;
create policy "own or admin comp credits read" on public.comp_time_credits
  for select to authenticated
  using (employee_id = auth.uid() or public.can_view_attendance_reports());

drop policy if exists "own or admin comp allocations read" on public.comp_time_usage_allocations;
create policy "own or admin comp allocations read" on public.comp_time_usage_allocations
  for select to authenticated
  using (exists (
    select 1 from public.comp_time_credits c
    where c.id = credit_id
      and (c.employee_id = auth.uid() or public.can_view_attendance_reports())
  ));

revoke insert, update, delete on public.comp_time_credits from authenticated;
revoke insert, update, delete on public.comp_time_usage_allocations from authenticated;

drop view if exists public.comp_time_balances_view;
create view public.comp_time_balances_view with (security_invoker = true) as
select p.id as employee_id,
  coalesce((select sum(c.granted_minutes) from public.comp_time_credits c where c.employee_id = p.id),0)::integer as approved_overtime_minutes,
  coalesce((select sum(a.used_minutes) from public.comp_time_usage_allocations a join public.comp_time_credits c on c.id = a.credit_id where c.employee_id = p.id),0)::integer as used_comp_time_minutes,
  coalesce((select sum(c.remaining_minutes) from public.comp_time_credits c where c.employee_id = p.id and c.expires_on >= (now() at time zone 'Asia/Seoul')::date),0)::integer as available_comp_time_minutes
from public.profiles p
where p.is_active and p.role = 'employee';
grant select on public.comp_time_balances_view to authenticated;

create or replace function public.admin_set_report_viewer(
  p_employee_id uuid,
  p_enabled boolean
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_before boolean;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  select can_view_reports into v_before
  from public.profiles
  where id = p_employee_id and role = 'employee' and is_active = true
  for update;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;

  update public.profiles
  set can_view_reports = p_enabled, updated_at = now()
  where id = p_employee_id;

  insert into public.attendance_audit_logs (
    employee_id, action_type, changed_field, before_value, after_value,
    reason, changed_by, changed_by_role
  ) values (
    p_employee_id, 'report_viewer_changed', 'can_view_reports',
    v_before::text, p_enabled::text,
    case when p_enabled then '부관리자 조회 권한 부여' else '부관리자 조회 권한 해제' end,
    auth.uid(), v_role
  );
end $$;

revoke all on function public.admin_set_report_viewer(uuid,boolean) from public, anon;
grant execute on function public.admin_set_report_viewer(uuid,boolean) to authenticated;

-- 시간외근무는 하루 최대 4시간까지 승인하고, 겹치지 않는 실제 추가근무는
-- 관리자가 선택한 경우에만 1시간 단위 대체휴무로 별도 적립합니다.
create or replace function public.admin_review_overtime(
  p_record_id uuid,
  p_decision text,
  p_approved_minutes integer,
  p_comp_time_minutes integer,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_week_start date;
  v_week_total integer := 0;
  v_raw_minutes integer := 0;
  v_comp_time_limit integer := 0;
  v_after text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'INVALID_DECISION'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if coalesce(v_record.recorded_overtime_minutes,0) <= 0 then raise exception 'NO_RECORDED_OVERTIME'; end if;
  v_raw_minutes := greatest(coalesce(v_record.raw_overtime_minutes,0), coalesce(v_record.recorded_overtime_minutes,0));

  if p_decision = 'approved' then
    if p_approved_minutes not in (60,90,120,150,180,210,240)
       or p_approved_minutes > v_record.recorded_overtime_minutes then
      raise exception 'INVALID_OVERTIME_MINUTES';
    end if;
    if p_comp_time_minutes < 0 or p_comp_time_minutes % 60 <> 0
       or p_approved_minutes + p_comp_time_minutes > v_raw_minutes then
      raise exception 'INVALID_EXTRA_COMP_TIME';
    end if;

    v_week_start := date_trunc('week', v_record.work_date::timestamp)::date;
    select coalesce(sum(approved_overtime_minutes + comp_time_eligible_minutes), 0)::integer into v_week_total
    from public.attendance_records
    where employee_id = v_record.employee_id
      and id <> v_record.id
      and work_date between v_week_start and v_week_start + 6
      and overtime_status = 'approved'
      and deleted_at is null;
    if v_week_total + p_approved_minutes + p_comp_time_minutes > 720 then raise exception 'WEEKLY_OVERTIME_LIMIT'; end if;

    update public.attendance_records
    set overtime_status = 'approved',
        approved_overtime_minutes = p_approved_minutes,
        comp_time_eligible_minutes = p_comp_time_minutes,
        changed = true,
        updated_at = now()
    where id = v_record.id;

    if p_comp_time_minutes > 0 then
      insert into public.comp_time_credits (
        attendance_record_id, employee_id, granted_minutes, remaining_minutes,
        expires_on, granted_by, reason
      ) values (
        v_record.id, v_record.employee_id, p_comp_time_minutes, p_comp_time_minutes,
        v_record.work_date + 30, auth.uid(), trim(p_reason)
      )
      on conflict (attendance_record_id) do update
      set granted_minutes = excluded.granted_minutes,
          remaining_minutes = greatest(0, excluded.granted_minutes - (public.comp_time_credits.granted_minutes - public.comp_time_credits.remaining_minutes)),
          expires_on = excluded.expires_on,
          granted_by = excluded.granted_by,
          granted_at = now(),
          reason = excluded.reason;
    else
      update public.comp_time_credits
      set remaining_minutes = 0,
          reason = trim(concat_ws(E'\n', reason, '관리자 재검토로 추가 대체휴무 적립 취소'))
      where attendance_record_id = v_record.id and remaining_minutes > 0;
    end if;
    v_after := jsonb_build_object('status','approved','minutes',p_approved_minutes,'comp_time_eligible_minutes',p_comp_time_minutes)::text;
  else
    update public.attendance_records
    set overtime_status = 'rejected',
        approved_overtime_minutes = 0,
        comp_time_eligible_minutes = 0,
        changed = true,
        updated_at = now()
    where id = v_record.id;
    update public.comp_time_credits
    set remaining_minutes = 0,
        reason = trim(concat_ws(E'\n', reason, '시간외근무 반려로 미사용 잔액 소멸'))
    where attendance_record_id = v_record.id and remaining_minutes > 0;
    v_after := jsonb_build_object('status','rejected','minutes',0,'comp_time_eligible_minutes',0)::text;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role
  ) values (
    v_record.id, v_record.employee_id, 'overtime_review', 'approved_overtime_minutes',
    jsonb_build_object('status',v_record.overtime_status,'minutes',v_record.approved_overtime_minutes,'comp_time_eligible_minutes',v_record.comp_time_eligible_minutes)::text,
    v_after, trim(p_reason), auth.uid(), v_role
  );
end $$;

revoke all on function public.admin_review_overtime(uuid,text,integer,integer,text) from public, anon;
grant execute on function public.admin_review_overtime(uuid,text,integer,integer,text) to authenticated;

notify pgrst, 'reload schema';
commit;


-- ============================================================================
-- supabase/upgrade_unified_requests_and_admin_review.sql
-- ============================================================================

begin;

-- 휴가, 출장, 시간외근무를 시작일시와 종료일시로 요청할 수 있도록 확장합니다.
alter table public.correction_requests add column if not exists end_date date;
alter table public.correction_requests add column if not exists start_time time;
alter table public.correction_requests add column if not exists end_time time;
alter table public.correction_requests add column if not exists calculated_minutes integer not null default 0;
alter table public.correction_requests add column if not exists approved_minutes integer not null default 0;
alter table public.correction_requests add column if not exists request_subtype text not null default '';

alter table public.attendance_records add column if not exists raw_overtime_minutes integer not null default 0;
alter table public.attendance_records add column if not exists recorded_overtime_minutes integer not null default 0;
alter table public.attendance_records add column if not exists approved_overtime_minutes integer not null default 0;
alter table public.attendance_records add column if not exists overtime_status text not null default 'none';
alter table public.attendance_records add column if not exists comp_time_eligible_minutes integer not null default 0;

-- 기존에 만들어진 보기 화면은 나중에 추가한 시간외근무 열을 자동으로 포함하지 않습니다.
-- 다시 만들어 앱이 계산값과 승인상태를 실제로 읽을 수 있게 합니다.
drop view if exists public.attendance_records_view;
create view public.attendance_records_view with (security_invoker = true) as
select ar.*, p.name as employee_name, p.employee_number, p.department
from public.attendance_records ar
join public.profiles p on p.id = ar.employee_id
where ar.deleted_at is null;
grant select on public.attendance_records_view to authenticated;

update public.correction_requests
set end_date = target_date
where end_date is null;

alter table public.correction_requests alter column end_date drop default;

do $$
declare v_constraint record;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.correction_requests'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%request_type%'
  loop
    execute format('alter table public.correction_requests drop constraint %I', v_constraint.conname);
  end loop;
end $$;

alter table public.correction_requests
  add constraint correction_requests_request_type_check
  check (request_type in (
    'clock_in_at','clock_out_at','annual_leave','comp_time','sick_leave',
    'business_trip','overtime','other_leave','work_type','note','attendance_status'
  )) not valid;

alter table public.correction_requests drop constraint if exists correction_requests_date_range_check;
alter table public.correction_requests
  add constraint correction_requests_date_range_check
  check (end_date is null or end_date >= target_date) not valid;

create or replace function public.calculate_attendance_request_minutes(
  p_request_type text,
  p_start_date date,
  p_end_date date,
  p_start_time time,
  p_end_time time
) returns integer
language plpgsql stable security definer set search_path = public as $$
declare
  v_day date;
  v_from timestamp;
  v_until timestamp;
  v_lunch_from timestamp;
  v_lunch_until timestamp;
  v_minutes integer := 0;
  v_day_minutes integer;
begin
  if p_end_date < p_start_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_start_time is null or p_end_time is null then raise exception 'TIME_REQUIRED'; end if;

  if p_request_type = 'overtime' then
    if p_start_date <> p_end_date or p_end_time <= p_start_time then raise exception 'INVALID_OVERTIME_RANGE'; end if;
    return floor(extract(epoch from (p_end_time - p_start_time)) / 60)::integer;
  end if;

  v_day := p_start_date;
  while v_day <= p_end_date loop
    if extract(isodow from v_day) < 6
       and not exists (select 1 from public.holidays h where h.holiday_date = v_day) then
      v_from := v_day + case when v_day = p_start_date then greatest(p_start_time, time '09:00') else time '09:00' end;
      v_until := v_day + case when v_day = p_end_date then least(p_end_time, time '18:00') else time '18:00' end;
      if v_until > v_from then
        v_day_minutes := floor(extract(epoch from (v_until - v_from)) / 60)::integer;
        v_lunch_from := greatest(v_from, v_day + time '12:00');
        v_lunch_until := least(v_until, v_day + time '13:00');
        if v_lunch_until > v_lunch_from then
          v_day_minutes := v_day_minutes - floor(extract(epoch from (v_lunch_until - v_lunch_from)) / 60)::integer;
        end if;
        v_minutes := v_minutes + greatest(0, least(480, v_day_minutes));
      end if;
    end if;
    v_day := v_day + 1;
  end loop;
  return v_minutes;
end $$;

create or replace function public.prepare_attendance_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.end_date := coalesce(new.end_date, new.target_date);
  if new.request_type in ('clock_in_at','clock_out_at') then
    new.end_date := new.target_date;
    new.calculated_minutes := 0;
  elsif new.request_type in ('annual_leave','comp_time','sick_leave','business_trip','overtime','other_leave') then
    new.calculated_minutes := public.calculate_attendance_request_minutes(
      new.request_type, new.target_date, new.end_date, new.start_time, new.end_time
    );
    if new.calculated_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;
    new.requested_value := new.calculated_minutes::text;
  end if;
  if new.request_type = 'other_leave' and char_length(trim(coalesce(new.request_subtype,''))) < 2 then
    raise exception 'OTHER_LEAVE_NAME_REQUIRED';
  end if;
  return new;
end $$;

drop trigger if exists prepare_attendance_request_trigger on public.correction_requests;
create trigger prepare_attendance_request_trigger
before insert or update of target_date, end_date, start_time, end_time, request_type, request_subtype
on public.correction_requests
for each row execute function public.prepare_attendance_request();

-- 수정된 시각을 기준으로 지각과 확인 필요 상태도 다시 판정합니다.
create or replace function public.derive_attendance_status(p_record public.attendance_records)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_start time := coalesce((select default_start_time from public.organization_settings where id = true), time '09:00');
  v_grace integer := coalesce((select late_grace_minutes from public.organization_settings where id = true), 0);
  v_leave_type text := coalesce(to_jsonb(p_record)->>'leave_type', 'none');
  v_regular boolean;
  v_location_review boolean;
  v_worked integer := 0;
  v_lunch integer := 0;
  v_required integer := 480;
  v_lunch_from timestamptz;
  v_lunch_until timestamptz;
begin
  if p_record.clock_in_at is null then
    return case when v_leave_type in ('annual_leave','half_day','quarter_day','hourly_leave','sick_leave') then v_leave_type else 'missing_in' end;
  end if;
  v_regular := extract(isodow from p_record.work_date) < 6
    and not exists (select 1 from public.holidays h where h.holiday_date = p_record.work_date and h.is_paid_holiday);
  v_location_review :=
    (p_record.clock_in_location_status in ('outside','low_accuracy') and not coalesce(p_record.clock_in_ip_matched,false))
    or (p_record.clock_out_at is not null and p_record.clock_out_location_status in ('outside','low_accuracy') and not coalesce(p_record.clock_out_ip_matched,false));
  if v_location_review then return 'admin_review'; end if;
  if not v_regular then return 'holiday_work'; end if;
  if (p_record.clock_in_at at time zone 'Asia/Seoul')::time > v_start + make_interval(mins => v_grace) then return 'late'; end if;
  if p_record.clock_out_at is null then return 'working'; end if;

  v_worked := floor(extract(epoch from (p_record.clock_out_at - p_record.clock_in_at)) / 60)::integer;
  v_lunch_from := (p_record.work_date + time '12:00') at time zone 'Asia/Seoul';
  v_lunch_until := (p_record.work_date + time '13:00') at time zone 'Asia/Seoul';
  if least(p_record.clock_out_at, v_lunch_until) > greatest(p_record.clock_in_at, v_lunch_from) then
    v_lunch := floor(extract(epoch from (least(p_record.clock_out_at, v_lunch_until) - greatest(p_record.clock_in_at, v_lunch_from))) / 60)::integer;
  end if;
  v_worked := greatest(0, v_worked - v_lunch);
  v_required := case v_leave_type when 'half_day' then 240 when 'quarter_day' then 360 when 'hourly_leave' then 420 when 'annual_leave' then 0 when 'sick_leave' then 0 else 480 end;
  return case when v_worked < v_required then 'admin_review' else 'normal' end;
end $$;

create or replace function public.recalculate_attendance_status_on_time_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.attendance_status := public.derive_attendance_status(new);
  return new;
end $$;

drop trigger if exists recalculate_attendance_status_after_time_edit on public.attendance_records;
create trigger recalculate_attendance_status_after_time_edit
before update of clock_in_at, clock_out_at on public.attendance_records
for each row
when (old.clock_in_at is distinct from new.clock_in_at or old.clock_out_at is distinct from new.clock_out_at)
execute function public.recalculate_attendance_status_on_time_change();

update public.attendance_records ar
set attendance_status = public.derive_attendance_status(ar), updated_at = now()
where ar.deleted_at is null
  and ar.clock_in_at is not null
  and ar.attendance_status is distinct from public.derive_attendance_status(ar);

create or replace function public.admin_confirm_attendance_record(
  p_record_id uuid,
  p_comment text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_comment,''))) < 2 then raise exception 'COMMENT_REQUIRED'; end if;

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if v_record.attendance_status not in ('admin_review','location_review','field','education') then
    raise exception 'RECORD_NOT_REVIEWABLE';
  end if;

  update public.attendance_records
  set attendance_status = case when clock_out_at is null then 'working' else 'normal' end,
      changed = true,
      updated_at = now()
  where id = p_record_id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role
  ) values (
    v_record.id, v_record.employee_id, 'admin_review_completed', 'attendance_status',
    v_record.attendance_status,
    case when v_record.clock_out_at is null then 'working' else 'normal' end,
    trim(p_comment), auth.uid(), v_role
  );
end $$;

-- 관리자 화면의 시간외근무 승인, 반려 버튼이 호출하는 처리 함수입니다.
create or replace function public.admin_review_overtime(
  p_record_id uuid,
  p_decision text,
  p_approved_minutes integer,
  p_comp_time_minutes integer,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_week_start date;
  v_week_total integer := 0;
  v_raw_minutes integer := 0;
  v_after text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'INVALID_DECISION'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if coalesce(v_record.recorded_overtime_minutes,0) <= 0 then raise exception 'NO_RECORDED_OVERTIME'; end if;
  v_raw_minutes := greatest(coalesce(v_record.raw_overtime_minutes,0), coalesce(v_record.recorded_overtime_minutes,0));

  if p_decision = 'approved' then
    if p_approved_minutes not in (60,90,120,150,180,210,240)
       or p_approved_minutes > v_record.recorded_overtime_minutes then
      raise exception 'INVALID_OVERTIME_MINUTES';
    end if;
    if p_comp_time_minutes < 0 or p_comp_time_minutes % 60 <> 0
       or p_approved_minutes + p_comp_time_minutes > v_raw_minutes then
      raise exception 'INVALID_EXTRA_COMP_TIME';
    end if;
    v_week_start := date_trunc('week', v_record.work_date::timestamp)::date;
    select coalesce(sum(approved_overtime_minutes + comp_time_eligible_minutes),0)::integer into v_week_total
    from public.attendance_records
    where employee_id = v_record.employee_id
      and id <> v_record.id
      and work_date between v_week_start and v_week_start + 6
      and overtime_status = 'approved'
      and deleted_at is null;
    if v_week_total + p_approved_minutes + p_comp_time_minutes > 720 then raise exception 'WEEKLY_OVERTIME_LIMIT'; end if;

    update public.attendance_records
    set overtime_status = 'approved',
        approved_overtime_minutes = p_approved_minutes,
        comp_time_eligible_minutes = p_comp_time_minutes,
        changed = true,
        updated_at = now()
    where id = v_record.id;
    if p_comp_time_minutes > 0 then
      insert into public.comp_time_credits (attendance_record_id, employee_id, granted_minutes, remaining_minutes, expires_on, granted_by, reason)
      values (v_record.id, v_record.employee_id, p_comp_time_minutes, p_comp_time_minutes, v_record.work_date + 30, auth.uid(), trim(p_reason))
      on conflict (attendance_record_id) do update
      set granted_minutes = excluded.granted_minutes,
          remaining_minutes = greatest(0, excluded.granted_minutes - (public.comp_time_credits.granted_minutes - public.comp_time_credits.remaining_minutes)),
          expires_on = excluded.expires_on,
          granted_by = excluded.granted_by,
          granted_at = now(),
          reason = excluded.reason;
    else
      update public.comp_time_credits
      set remaining_minutes = 0,
          reason = trim(concat_ws(E'\n', reason, '관리자 재검토로 추가 대체휴무 적립 취소'))
      where attendance_record_id = v_record.id and remaining_minutes > 0;
    end if;
    v_after := jsonb_build_object('status','approved','minutes',p_approved_minutes,'comp_time_eligible_minutes',p_comp_time_minutes)::text;
  else
    update public.attendance_records
    set overtime_status = 'rejected',
        approved_overtime_minutes = 0,
        comp_time_eligible_minutes = 0,
        changed = true,
        updated_at = now()
    where id = v_record.id;
    update public.comp_time_credits
    set remaining_minutes = 0,
        reason = trim(concat_ws(E'\n', reason, '시간외근무 반려로 미사용 잔액 소멸'))
    where attendance_record_id = v_record.id and remaining_minutes > 0;
    v_after := jsonb_build_object('status','rejected','minutes',0)::text;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role
  ) values (
    v_record.id, v_record.employee_id, 'overtime_review', 'approved_overtime_minutes',
    jsonb_build_object('status',v_record.overtime_status,'minutes',v_record.approved_overtime_minutes)::text,
    v_after, trim(p_reason), auth.uid(), v_role
  );
end $$;

create or replace function public.review_correction_request(
  p_request_id uuid,
  p_decision text,
  p_comment text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_before text := '';
  v_after text := '';
  v_approved integer := 0;
  v_week_total integer := 0;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected','more_info') then raise exception 'INVALID_DECISION'; end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_comment,''))) < 2 then raise exception 'COMMENT_REQUIRED'; end if;

  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found or v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_REVIEWABLE'; end if;
  if exists (
    select 1 from public.monthly_closings
    where year = extract(year from v_request.target_date)
      and month = extract(month from v_request.target_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  if p_decision = 'approved' and v_request.request_type in ('clock_in_at','clock_out_at') then
    select * into v_record from public.attendance_records
    where id = v_request.attendance_record_id and deleted_at is null for update;
    if not found and v_request.request_type = 'clock_in_at' then
      insert into public.attendance_records (employee_id, work_date, work_type, attendance_status, note, changed)
      values (v_request.employee_id, v_request.target_date, 'office', 'missing_out', '수정 요청으로 생성된 기록', true)
      on conflict (employee_id, work_date) do update
      set changed = true, deleted_at = null, deleted_by = null, deletion_reason = '', updated_at = now()
      returning * into v_record;
      update public.correction_requests set attendance_record_id = v_record.id where id = v_request.id;
    elsif not found then
      raise exception 'CLOCK_IN_CORRECTION_REQUIRED_FIRST';
    end if;

    if v_request.request_type = 'clock_in_at' then
      v_before := coalesce(v_record.clock_in_at::text,'');
      update public.attendance_records
      set clock_in_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true
      where id = v_record.id returning clock_in_at::text into v_after;
    else
      v_before := coalesce(v_record.clock_out_at::text,'');
      update public.attendance_records
      set clock_out_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true
      where id = v_record.id returning clock_out_at::text into v_after;
    end if;
  elsif p_decision = 'approved' then
    if v_request.request_type = 'overtime' then
      v_approved := least(240, v_request.calculated_minutes);
      select coalesce(sum(approved_minutes), 0)::integer into v_week_total
      from public.correction_requests
      where employee_id = v_request.employee_id
        and request_type = 'overtime'
        and status = 'approved'
        and target_date >= date_trunc('week', v_request.target_date::timestamp)::date
        and target_date < date_trunc('week', v_request.target_date::timestamp)::date + 7;
      if v_week_total + v_approved > 720 then raise exception 'WEEKLY_OVERTIME_LIMIT'; end if;
    else
      v_approved := v_request.calculated_minutes;
    end if;
    v_before := '미승인';
    v_after := jsonb_build_object(
      'start_date', v_request.target_date,
      'end_date', v_request.end_date,
      'start_time', v_request.start_time,
      'end_time', v_request.end_time,
      'minutes', v_request.calculated_minutes,
      'subtype', v_request.request_subtype
    )::text;
    update public.correction_requests
    set approved_minutes = v_approved
    where id = v_request.id;
  end if;

  if p_decision = 'approved' then
    insert into public.attendance_audit_logs (
      attendance_record_id, employee_id, action_type, changed_field,
      before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
    ) values (
      v_request.attendance_record_id, v_request.employee_id, 'request_approved', v_request.request_type,
      v_before, v_after, coalesce(nullif(trim(p_comment),''), v_request.reason), auth.uid(), v_role, v_request.id
    );
  end if;

  update public.correction_requests
  set status = p_decision,
      reviewer_id = auth.uid(),
      reviewer_comment = coalesce(p_comment,''),
      reviewed_at = now()
  where id = p_request_id;
end $$;

create or replace function public.admin_reopen_correction_request(
  p_request_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_role text := public.current_profile_role();
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.status in ('pending','more_info') then raise exception 'REQUEST_ALREADY_OPEN'; end if;
  if v_request.status = 'approved' and v_request.request_type in ('clock_in_at','clock_out_at') then raise exception 'APPLIED_CLOCK_CORRECTION'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_request.target_date) and month = extract(month from v_request.target_date) and status = 'closed') and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  update public.correction_requests
  set status = 'pending', reviewer_id = null, reviewer_comment = '', reviewed_at = null
  where id = p_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
  ) values (
    v_request.attendance_record_id, v_request.employee_id, 'request_reopened', 'request_status',
    v_request.status, 'pending', trim(p_reason), auth.uid(), v_role, v_request.id
  );
end $$;

drop function if exists public.admin_update_attendance_request(uuid,date,date,time,time,text,text,text);

create or replace function public.admin_update_attendance_request(
  p_request_id uuid,
  p_start_date date,
  p_end_date date,
  p_start_time time,
  p_end_time time,
  p_request_type text,
  p_request_subtype text,
  p_requested_value text,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_role text := public.current_profile_role();
  v_before text;
  v_request_type text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.status = 'approved' and v_request.request_type in ('clock_in_at','clock_out_at') then raise exception 'APPLIED_CLOCK_CORRECTION'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_request.target_date) and month = extract(month from v_request.target_date) and status = 'closed') and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  v_request_type := trim(coalesce(p_request_type,''));
  if v_request_type not in ('clock_in_at','clock_out_at','annual_leave','comp_time','sick_leave','business_trip','overtime','other_leave') then raise exception 'INVALID_REQUEST_TYPE'; end if;
  v_before := jsonb_build_object('request_type',v_request.request_type,'start_date',v_request.target_date,'end_date',v_request.end_date,'start_time',v_request.start_time,'end_time',v_request.end_time,'subtype',v_request.request_subtype,'value',v_request.requested_value,'reason',v_request.reason,'status',v_request.status)::text;

  if v_request_type in ('clock_in_at','clock_out_at') then
    update public.correction_requests
    set request_type = v_request_type,
        target_date = p_start_date, end_date = p_start_date,
        start_time = null, end_time = null,
        request_subtype = '', approved_minutes = 0,
        requested_value = trim(coalesce(p_requested_value,'')), reason = trim(p_reason),
        status = 'pending', reviewer_id = null, reviewer_comment = '', reviewed_at = null
    where id = p_request_id;
  else
    update public.correction_requests
    set request_type = v_request_type,
        target_date = p_start_date,
        end_date = case when v_request_type = 'overtime' then p_start_date else coalesce(p_end_date,p_start_date) end,
        start_time = p_start_time, end_time = p_end_time,
        request_subtype = case when v_request_type = 'other_leave' then trim(coalesce(p_request_subtype,'')) else '' end,
        approved_minutes = 0, reason = trim(p_reason),
        status = 'pending', reviewer_id = null, reviewer_comment = '', reviewed_at = null
    where id = p_request_id;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
  )
  select
    attendance_record_id, employee_id, 'request_edited', 'attendance_request',
    v_before,
    jsonb_build_object('request_type',request_type,'start_date',target_date,'end_date',end_date,'start_time',start_time,'end_time',end_time,'subtype',request_subtype,'value',requested_value,'reason',reason,'status',status)::text,
    trim(p_reason), auth.uid(), v_role, id
  from public.correction_requests where id = p_request_id;
end $$;

create or replace function public.employee_resubmit_attendance_request(
  p_request_id uuid,
  p_start_date date,
  p_end_date date,
  p_start_time time,
  p_end_time time,
  p_request_subtype text,
  p_requested_value text,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_before text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_request
  from public.correction_requests
  where id = p_request_id and employee_id = auth.uid()
  for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.status not in ('pending','rejected','more_info') then raise exception 'REQUEST_NOT_RESUBMITTABLE'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_request.target_date) and month = extract(month from v_request.target_date) and status = 'closed') then raise exception 'MONTH_CLOSED'; end if;
  v_before := jsonb_build_object('start_date',v_request.target_date,'end_date',v_request.end_date,'start_time',v_request.start_time,'end_time',v_request.end_time,'subtype',v_request.request_subtype,'value',v_request.requested_value,'reason',v_request.reason,'status',v_request.status)::text;

  if v_request.request_type in ('clock_in_at','clock_out_at') then
    update public.correction_requests
    set target_date = p_start_date, end_date = p_start_date,
        start_time = null, end_time = null,
        requested_value = trim(coalesce(p_requested_value,'')), reason = trim(p_reason),
        status = 'pending', reviewer_id = null, reviewer_comment = '', reviewed_at = null,
        requested_at = now()
    where id = p_request_id;
  else
    update public.correction_requests
    set target_date = p_start_date,
        end_date = case when request_type = 'overtime' then p_start_date else coalesce(p_end_date,p_start_date) end,
        start_time = p_start_time, end_time = p_end_time,
        request_subtype = trim(coalesce(p_request_subtype,'')), reason = trim(p_reason),
        status = 'pending', reviewer_id = null, reviewer_comment = '', reviewed_at = null,
        requested_at = now()
    where id = p_request_id;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
  )
  select attendance_record_id, employee_id, 'request_resubmitted', 'attendance_request', v_before,
    jsonb_build_object('start_date',target_date,'end_date',end_date,'start_time',start_time,'end_time',end_time,'subtype',request_subtype,'value',requested_value,'reason',reason,'status',status)::text,
    trim(p_reason), auth.uid(), 'employee', id
  from public.correction_requests where id = p_request_id;
end $$;

create or replace function public.admin_restore_attendance(
  p_record_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.deleted_at is null then raise exception 'RECORD_NOT_DELETED'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if exists (
    select 1 from public.attendance_records
    where employee_id = v_record.employee_id and work_date = v_record.work_date
      and id <> v_record.id and deleted_at is null
  ) then raise exception 'ACTIVE_RECORD_ALREADY_EXISTS'; end if;

  update public.attendance_records
  set deleted_at = null, deleted_by = null, deletion_reason = '', changed = true, updated_at = now()
  where id = p_record_id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role
  ) values (
    v_record.id, v_record.employee_id, 'admin_restore', 'attendance_record',
    '삭제됨', '기록 복원됨', trim(p_reason), auth.uid(), v_role
  );
end $$;

-- 버튼 기록뿐 아니라 관리자가 출퇴근 시각을 수정한 경우에도 시간외근무를 다시 계산합니다.
create or replace function public.recalculate_overtime_after_attendance_change()
returns trigger language plpgsql set search_path = public as $$
declare
  v_worked integer := 0;
  v_lunch integer := 0;
  v_raw integer := 0;
  v_recognized integer := 0;
  v_lunch_from timestamptz;
  v_lunch_until timestamptz;
begin
  if new.clock_in_at is not null and new.clock_out_at is not null and new.clock_out_at > new.clock_in_at then
    v_worked := floor(extract(epoch from (new.clock_out_at - new.clock_in_at)) / 60)::integer;
    v_lunch_from := (new.work_date + time '12:00') at time zone 'Asia/Seoul';
    v_lunch_until := (new.work_date + time '13:00') at time zone 'Asia/Seoul';
    if least(new.clock_out_at, v_lunch_until) > greatest(new.clock_in_at, v_lunch_from) then
      v_lunch := floor(extract(epoch from (least(new.clock_out_at, v_lunch_until) - greatest(new.clock_in_at, v_lunch_from))) / 60)::integer;
    end if;
    v_raw := greatest(0, v_worked - v_lunch - 480);
    v_recognized := case when v_raw < 60 then 0 else least(240, floor(v_raw / 30.0)::integer * 30) end;
  end if;
  new.raw_overtime_minutes := v_raw;
  new.recorded_overtime_minutes := v_recognized;
  if v_recognized > 0 and (tg_op = 'INSERT' or old.clock_in_at is distinct from new.clock_in_at or old.clock_out_at is distinct from new.clock_out_at) then
    new.overtime_status := 'pending';
    new.approved_overtime_minutes := 0;
  elsif v_recognized = 0 then
    new.overtime_status := 'none';
    new.approved_overtime_minutes := 0;
  end if;
  return new;
end $$;

drop trigger if exists recalculate_overtime_after_attendance_change_trigger on public.attendance_records;
create trigger recalculate_overtime_after_attendance_change_trigger
before insert or update of clock_in_at, clock_out_at
on public.attendance_records
for each row execute function public.recalculate_overtime_after_attendance_change();

-- 기존 기록도 같은 기준으로 한 번 다시 계산합니다.
update public.attendance_records
set clock_in_at = clock_in_at
where deleted_at is null and clock_in_at is not null and clock_out_at is not null;

drop view if exists public.correction_requests_view;
create view public.correction_requests_view with (security_invoker = true) as
select
  cr.*,
  employee.name as employee_name,
  employee.employee_number,
  employee.department,
  reviewer.name as reviewer_name
from public.correction_requests cr
join public.profiles employee on employee.id = cr.employee_id
left join public.profiles reviewer on reviewer.id = cr.reviewer_id;

grant select on public.correction_requests_view to authenticated;
revoke all on function public.calculate_attendance_request_minutes(text,date,date,time,time) from public, anon;
grant execute on function public.calculate_attendance_request_minutes(text,date,date,time,time) to authenticated;
revoke all on function public.admin_confirm_attendance_record(uuid,text) from public, anon;
grant execute on function public.admin_confirm_attendance_record(uuid,text) to authenticated;
revoke all on function public.admin_review_overtime(uuid,text,integer,integer,text) from public, anon;
grant execute on function public.admin_review_overtime(uuid,text,integer,integer,text) to authenticated;
revoke all on function public.admin_reopen_correction_request(uuid,text) from public, anon;
grant execute on function public.admin_reopen_correction_request(uuid,text) to authenticated;
revoke all on function public.admin_update_attendance_request(uuid,date,date,time,time,text,text,text,text) from public, anon;
grant execute on function public.admin_update_attendance_request(uuid,date,date,time,time,text,text,text,text) to authenticated;
revoke all on function public.employee_resubmit_attendance_request(uuid,date,date,time,time,text,text,text) from public, anon;
grant execute on function public.employee_resubmit_attendance_request(uuid,date,date,time,time,text,text,text) to authenticated;
revoke all on function public.admin_restore_attendance(uuid,text) from public, anon;
grant execute on function public.admin_restore_attendance(uuid,text) to authenticated;

notify pgrst, 'reload schema';
commit;

select '통합 요청과 관리자 확인 화면용 데이터베이스 보완 완료' as result;


-- ============================================================================
-- supabase/upgrade_approved_request_editing.sql
-- ============================================================================

begin;

drop function if exists public.admin_update_attendance_request(uuid,date,date,time,time,text,text,text);

create or replace function public.admin_update_attendance_request(
  p_request_id uuid,
  p_start_date date,
  p_end_date date,
  p_start_time time,
  p_end_time time,
  p_request_type text,
  p_request_subtype text,
  p_requested_value text,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_role text := public.current_profile_role();
  v_before text;
  v_request_type text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;

  select * into v_request
  from public.correction_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.status = 'approved' and v_request.request_type in ('clock_in_at','clock_out_at') then raise exception 'APPLIED_CLOCK_CORRECTION'; end if;
  if exists (
    select 1 from public.monthly_closings
    where year = extract(year from v_request.target_date)
      and month = extract(month from v_request.target_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then
    raise exception 'MONTH_CLOSED';
  end if;

  v_request_type := trim(coalesce(p_request_type,''));
  if v_request_type not in (
    'clock_in_at','clock_out_at','annual_leave','comp_time','sick_leave',
    'business_trip','overtime','other_leave'
  ) then
    raise exception 'INVALID_REQUEST_TYPE';
  end if;

  v_before := jsonb_build_object(
    'request_type',v_request.request_type,
    'start_date',v_request.target_date,
    'end_date',v_request.end_date,
    'start_time',v_request.start_time,
    'end_time',v_request.end_time,
    'subtype',v_request.request_subtype,
    'value',v_request.requested_value,
    'reason',v_request.reason,
    'status',v_request.status
  )::text;

  if v_request_type in ('clock_in_at','clock_out_at') then
    update public.correction_requests
    set request_type = v_request_type,
        target_date = p_start_date,
        end_date = p_start_date,
        start_time = null,
        end_time = null,
        request_subtype = '',
        approved_minutes = 0,
        requested_value = trim(coalesce(p_requested_value,'')),
        reason = trim(p_reason),
        status = 'pending',
        reviewer_id = null,
        reviewer_comment = '',
        reviewed_at = null
    where id = p_request_id;
  else
    update public.correction_requests
    set request_type = v_request_type,
        target_date = p_start_date,
        end_date = case when v_request_type = 'overtime' then p_start_date else coalesce(p_end_date,p_start_date) end,
        start_time = p_start_time,
        end_time = p_end_time,
        request_subtype = case when v_request_type = 'other_leave' then trim(coalesce(p_request_subtype,'')) else '' end,
        approved_minutes = 0,
        reason = trim(p_reason),
        status = 'pending',
        reviewer_id = null,
        reviewer_comment = '',
        reviewed_at = null
    where id = p_request_id;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
  )
  select
    attendance_record_id, employee_id, 'request_edited', 'attendance_request',
    v_before,
    jsonb_build_object(
      'request_type',request_type,
      'start_date',target_date,
      'end_date',end_date,
      'start_time',start_time,
      'end_time',end_time,
      'subtype',request_subtype,
      'value',requested_value,
      'reason',reason,
      'status',status
    )::text,
    trim(p_reason), auth.uid(), v_role, id
  from public.correction_requests
  where id = p_request_id;
end $$;

revoke all on function public.admin_update_attendance_request(uuid,date,date,time,time,text,text,text,text) from public, anon;
grant execute on function public.admin_update_attendance_request(uuid,date,date,time,time,text,text,text,text) to authenticated;

notify pgrst, 'reload schema';

commit;


-- ============================================================================
-- supabase/upgrade_admin_leave_classification.sql
-- ============================================================================

begin;

create or replace function public.admin_apply_leave_to_attendance_record(
  p_record_id uuid,
  p_request_type text,
  p_start_time time,
  p_end_time time,
  p_request_subtype text,
  p_comment text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_request_id uuid;
  v_minutes integer;
  v_leave_type text := 'none';
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_request_type not in ('annual_leave','comp_time','sick_leave','other_leave') then raise exception 'INVALID_LEAVE_TYPE'; end if;
  if char_length(trim(coalesce(p_comment,''))) < 5 then raise exception 'COMMENT_REQUIRED'; end if;
  if p_start_time is null or p_end_time is null or p_end_time <= p_start_time then raise exception 'INVALID_TIME_RANGE'; end if;
  if p_request_type = 'other_leave' and char_length(trim(coalesce(p_request_subtype,''))) < 2 then raise exception 'OTHER_LEAVE_NAME_REQUIRED'; end if;

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;

  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if exists (
    select 1
    from public.monthly_closings
    where year = extract(year from v_record.work_date)
      and month = extract(month from v_record.work_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  v_minutes := public.calculate_attendance_request_minutes(
    p_request_type,
    v_record.work_date,
    v_record.work_date,
    p_start_time,
    p_end_time
  );
  if v_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;

  select id into v_request_id
  from public.correction_requests
  where attendance_record_id = v_record.id
    and request_type in ('annual_leave','comp_time','sick_leave','other_leave')
  order by requested_at desc
  limit 1
  for update;

  if v_request_id is null then
    insert into public.correction_requests (
      attendance_record_id, employee_id, target_date, end_date,
      start_time, end_time, calculated_minutes, approved_minutes,
      request_type, request_subtype, before_value, requested_value, reason,
      status, reviewer_id, reviewer_comment, reviewed_at
    ) values (
      v_record.id, v_record.employee_id, v_record.work_date, v_record.work_date,
      p_start_time, p_end_time, v_minutes, v_minutes,
      p_request_type,
      case when p_request_type = 'other_leave' then trim(coalesce(p_request_subtype,'')) else '' end,
      v_record.attendance_status, v_minutes::text, trim(p_comment),
      'approved', auth.uid(), trim(p_comment), now()
    ) returning id into v_request_id;
  else
    update public.correction_requests
    set target_date = v_record.work_date,
        end_date = v_record.work_date,
        start_time = p_start_time,
        end_time = p_end_time,
        calculated_minutes = v_minutes,
        approved_minutes = v_minutes,
        request_type = p_request_type,
        request_subtype = case when p_request_type = 'other_leave' then trim(coalesce(p_request_subtype,'')) else '' end,
        requested_value = v_minutes::text,
        reason = trim(p_comment),
        status = 'approved',
        reviewer_id = auth.uid(),
        reviewer_comment = trim(p_comment),
        reviewed_at = now()
    where id = v_request_id;
  end if;

  if p_request_type = 'annual_leave' then
    v_leave_type := case v_minutes
      when 480 then 'annual_leave'
      when 240 then 'half_day'
      when 120 then 'quarter_day'
      when 60 then 'hourly_leave'
      else 'none'
    end;
  elsif p_request_type = 'sick_leave' then
    v_leave_type := 'sick_leave';
  end if;

  update public.attendance_records
  set attendance_status = case when clock_out_at is null then 'working' else 'normal' end,
      leave_type = v_leave_type,
      changed = true,
      updated_at = now()
  where id = v_record.id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
  ) values (
    v_record.id, v_record.employee_id, 'admin_leave_applied', 'leave_request',
    jsonb_build_object('attendance_status',v_record.attendance_status,'leave_type',v_record.leave_type)::text,
    jsonb_build_object('request_type',p_request_type,'start_time',p_start_time,'end_time',p_end_time,'minutes',v_minutes,'subtype',trim(coalesce(p_request_subtype,'')))::text,
    trim(p_comment), auth.uid(), v_role, v_request_id
  );

  return v_request_id;
end $$;

revoke all on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) from public, anon;
grant execute on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) to authenticated;

notify pgrst, 'reload schema';

commit;


-- ============================================================================
-- supabase/upgrade_leave_exceptions.sql
-- ============================================================================

begin;

alter table public.attendance_exceptions
  add column if not exists correction_request_id uuid references public.correction_requests(id) on delete restrict;

do $$
declare v_constraint record;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.attendance_exceptions'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%exception_type%'
  loop
    execute format('alter table public.attendance_exceptions drop constraint %I', v_constraint.conname);
  end loop;
end $$;

alter table public.attendance_exceptions
  add constraint attendance_exceptions_exception_type_check
  check (exception_type in (
    'business_trip','approved_other','annual_leave','comp_time','sick_leave','other_leave'
  )) not valid;

create or replace function public.admin_create_attendance_exception(
  p_employee_id uuid,
  p_start_date date,
  p_end_date date,
  p_exception_type text,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_id uuid;
  v_request_id uuid;
  v_request_reason text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_end_date < p_start_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_exception_type not in ('business_trip','approved_other','annual_leave','comp_time','sick_leave','other_leave') then raise exception 'INVALID_EXCEPTION_TYPE'; end if;
  if p_exception_type = 'other_leave' and char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'OTHER_LEAVE_NAME_REQUIRED'; end if;
  if not exists (select 1 from public.profiles where id = p_employee_id and role = 'employee' and is_active = true) then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if exists (
    select 1 from public.attendance_exceptions
    where employee_id = p_employee_id
      and cancelled_at is null
      and start_date <= p_end_date
      and end_date >= p_start_date
  ) then raise exception 'EXCEPTION_OVERLAP'; end if;

  if p_exception_type in ('annual_leave','comp_time','sick_leave','other_leave') then
    v_request_reason := case p_exception_type
      when 'annual_leave' then '관리자 직접 등록 종일 연차'
      when 'comp_time' then '관리자 직접 등록 종일 대체휴무'
      when 'sick_leave' then '관리자 직접 등록 종일 병가'
      else '관리자 직접 등록 ' || trim(p_reason)
    end;

    insert into public.correction_requests (
      employee_id, target_date, end_date, start_time, end_time,
      request_type, request_subtype, before_value, requested_value, reason,
      status, reviewer_id, reviewer_comment, reviewed_at
    ) values (
      p_employee_id, p_start_date, p_end_date, time '09:00', time '18:00',
      p_exception_type,
      case when p_exception_type = 'other_leave' then trim(p_reason) else '' end,
      '관리자 직접 등록', '0', v_request_reason,
      'approved', auth.uid(), v_request_reason, now()
    ) returning id into v_request_id;

    update public.correction_requests
    set approved_minutes = calculated_minutes
    where id = v_request_id;
  end if;

  insert into public.attendance_exceptions (
    employee_id, start_date, end_date, exception_type, reason, approved_by, correction_request_id
  ) values (
    p_employee_id, p_start_date, p_end_date, p_exception_type,
    trim(coalesce(p_reason,'')), auth.uid(), v_request_id
  ) returning id into v_id;

  insert into public.attendance_audit_logs (
    employee_id, action_type, changed_field, before_value, after_value,
    reason, changed_by, changed_by_role, correction_request_id
  ) values (
    p_employee_id,
    'exception_create',
    'attendance_exception',
    '',
    jsonb_build_object('id',v_id,'start_date',p_start_date,'end_date',p_end_date,'exception_type',p_exception_type)::text,
    trim(coalesce(p_reason,'')),
    auth.uid(),
    v_role,
    v_request_id
  );
  return v_id;
end $$;

create or replace function public.admin_cancel_attendance_exception(
  p_exception_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_item public.attendance_exceptions;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;

  select * into v_item
  from public.attendance_exceptions
  where id = p_exception_id and cancelled_at is null
  for update;
  if not found then raise exception 'EXCEPTION_NOT_FOUND'; end if;

  update public.attendance_exceptions
  set cancelled_at = now(),
      cancelled_by = auth.uid(),
      cancellation_reason = trim(p_reason)
  where id = p_exception_id;

  if v_item.correction_request_id is not null then
    update public.correction_requests
    set status = 'rejected',
        reviewer_id = auth.uid(),
        reviewer_comment = '예외 일정 취소: ' || trim(p_reason),
        reviewed_at = now(),
        approved_minutes = 0
    where id = v_item.correction_request_id;
  end if;

  insert into public.attendance_audit_logs (
    employee_id, action_type, changed_field, before_value, after_value,
    reason, changed_by, changed_by_role, correction_request_id
  ) values (
    v_item.employee_id,
    'exception_cancel',
    'attendance_exception',
    jsonb_build_object('id',v_item.id,'start_date',v_item.start_date,'end_date',v_item.end_date,'exception_type',v_item.exception_type)::text,
    '취소됨',
    trim(p_reason),
    auth.uid(),
    v_role,
    v_item.correction_request_id
  );
end $$;

revoke all on function public.admin_create_attendance_exception(uuid,date,date,text,text) from public, anon;
grant execute on function public.admin_create_attendance_exception(uuid,date,date,text,text) to authenticated;
revoke all on function public.admin_cancel_attendance_exception(uuid,text) from public, anon;
grant execute on function public.admin_cancel_attendance_exception(uuid,text) to authenticated;

create or replace function public.admin_apply_leave_to_attendance_record(
  p_record_id uuid,
  p_request_type text,
  p_start_time time,
  p_end_time time,
  p_request_subtype text,
  p_comment text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_request_id uuid;
  v_minutes integer;
  v_leave_type text := 'none';
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_request_type not in ('annual_leave','comp_time','sick_leave','other_leave') then raise exception 'INVALID_LEAVE_TYPE'; end if;
  if char_length(trim(coalesce(p_comment,''))) < 5 then raise exception 'COMMENT_REQUIRED'; end if;
  if p_start_time is null or p_end_time is null or p_end_time <= p_start_time then raise exception 'INVALID_TIME_RANGE'; end if;
  if p_request_type = 'other_leave' and char_length(trim(coalesce(p_request_subtype,''))) < 2 then raise exception 'OTHER_LEAVE_NAME_REQUIRED'; end if;

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if exists (
    select 1
    from public.monthly_closings
    where year = extract(year from v_record.work_date)
      and month = extract(month from v_record.work_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  v_minutes := public.calculate_attendance_request_minutes(
    p_request_type, v_record.work_date, v_record.work_date, p_start_time, p_end_time
  );
  if v_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;

  select id into v_request_id
  from public.correction_requests
  where attendance_record_id = v_record.id
    and request_type in ('annual_leave','comp_time','sick_leave','other_leave')
  order by requested_at desc
  limit 1
  for update;

  if v_request_id is null then
    insert into public.correction_requests (
      attendance_record_id, employee_id, target_date, end_date,
      start_time, end_time, calculated_minutes, approved_minutes,
      request_type, request_subtype, before_value, requested_value, reason,
      status, reviewer_id, reviewer_comment, reviewed_at
    ) values (
      v_record.id, v_record.employee_id, v_record.work_date, v_record.work_date,
      p_start_time, p_end_time, v_minutes, v_minutes,
      p_request_type,
      case when p_request_type = 'other_leave' then trim(coalesce(p_request_subtype,'')) else '' end,
      v_record.attendance_status, v_minutes::text, trim(p_comment),
      'approved', auth.uid(), trim(p_comment), now()
    ) returning id into v_request_id;
  else
    update public.correction_requests
    set target_date = v_record.work_date,
        end_date = v_record.work_date,
        start_time = p_start_time,
        end_time = p_end_time,
        calculated_minutes = v_minutes,
        approved_minutes = v_minutes,
        request_type = p_request_type,
        request_subtype = case when p_request_type = 'other_leave' then trim(coalesce(p_request_subtype,'')) else '' end,
        requested_value = v_minutes::text,
        reason = trim(p_comment),
        status = 'approved',
        reviewer_id = auth.uid(),
        reviewer_comment = trim(p_comment),
        reviewed_at = now()
    where id = v_request_id;
  end if;

  if p_request_type = 'annual_leave' then
    v_leave_type := case v_minutes
      when 480 then 'annual_leave'
      when 240 then 'half_day'
      when 120 then 'quarter_day'
      when 60 then 'hourly_leave'
      else 'none'
    end;
  elsif p_request_type = 'sick_leave' then
    v_leave_type := 'sick_leave';
  end if;

  update public.attendance_records
  set attendance_status = case when clock_out_at is null then 'working' else 'normal' end,
      leave_type = v_leave_type,
      changed = true,
      updated_at = now()
  where id = v_record.id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
  ) values (
    v_record.id, v_record.employee_id, 'admin_leave_applied', 'leave_request',
    jsonb_build_object('attendance_status',v_record.attendance_status,'leave_type',v_record.leave_type)::text,
    jsonb_build_object('request_type',p_request_type,'start_time',p_start_time,'end_time',p_end_time,'minutes',v_minutes,'subtype',trim(coalesce(p_request_subtype,'')))::text,
    trim(p_comment), auth.uid(), v_role, v_request_id
  );

  return v_request_id;
end $$;

revoke all on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) from public, anon;
grant execute on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) to authenticated;

notify pgrst, 'reload schema';

commit;


-- ============================================================================
-- supabase/upgrade_admin_manual_attendance_and_request_exceptions.sql
-- ============================================================================

begin;

alter table public.attendance_exceptions
  add column if not exists correction_request_id uuid references public.correction_requests(id) on delete restrict;

create or replace function public.admin_create_attendance_record(
  p_employee_id uuid,
  p_work_date date,
  p_clock_in_time time,
  p_clock_out_time time,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_record public.attendance_records;
  v_record_id uuid;
  v_clock_in timestamptz;
  v_clock_out timestamptz;
  v_was_deleted boolean := false;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_work_date is null or p_clock_in_time is null or p_clock_out_time is null then raise exception 'REQUIRED_VALUE_MISSING'; end if;
  if p_clock_out_time <= p_clock_in_time then raise exception 'INVALID_TIME_RANGE'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  if not exists (
    select 1 from public.profiles
    where id = p_employee_id and role = 'employee' and is_active = true
  ) then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if exists (
    select 1 from public.monthly_closings
    where year = extract(year from p_work_date)
      and month = extract(month from p_work_date)
      and status = 'closed'
  ) then raise exception 'MONTH_CLOSED'; end if;

  v_clock_in := (p_work_date + p_clock_in_time) at time zone 'Asia/Seoul';
  v_clock_out := (p_work_date + p_clock_out_time) at time zone 'Asia/Seoul';

  select * into v_record
  from public.attendance_records
  where employee_id = p_employee_id and work_date = p_work_date
  for update;

  if found and v_record.deleted_at is null then raise exception 'RECORD_ALREADY_EXISTS'; end if;

  if found then
    v_was_deleted := true;
    update public.attendance_records
    set work_type = 'office',
        clock_in_at = v_clock_in,
        clock_out_at = v_clock_out,
        clock_in_accuracy = null,
        clock_in_distance = null,
        clock_in_location_status = 'not_checked',
        clock_in_ip_address = null,
        clock_in_ip_matched = false,
        clock_out_accuracy = null,
        clock_out_distance = null,
        clock_out_location_status = 'not_checked',
        clock_out_ip_address = null,
        clock_out_ip_matched = false,
        attendance_status = 'normal',
        leave_type = 'none',
        note = '관리자 직접 추가: ' || trim(p_reason),
        changed = true,
        deleted_at = null,
        deleted_by = null,
        deletion_reason = '',
        updated_at = now()
    where id = v_record.id
    returning id into v_record_id;
  else
    insert into public.attendance_records (
      employee_id, work_date, work_type, clock_in_at, clock_out_at,
      clock_in_location_status, clock_out_location_status,
      attendance_status, leave_type, note, changed
    ) values (
      p_employee_id, p_work_date, 'office', v_clock_in, v_clock_out,
      'not_checked', 'not_checked',
      'normal', 'none', '관리자 직접 추가: ' || trim(p_reason), true
    ) returning id into v_record_id;
  end if;

  select * into v_record from public.attendance_records where id = v_record_id;
  update public.attendance_records
  set attendance_status = public.derive_attendance_status(v_record),
      updated_at = now()
  where id = v_record_id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role
  ) values (
    v_record_id, p_employee_id, 'admin_create', 'attendance_record',
    case when v_was_deleted then '삭제된 기록' else '기록 없음' end,
    jsonb_build_object(
      'work_date',p_work_date,
      'clock_in_time',p_clock_in_time,
      'clock_out_time',p_clock_out_time,
      'location','관리자 직접 등록, 위치 미확인'
    )::text,
    trim(p_reason), auth.uid(), v_role
  );

  return v_record_id;
end $$;

create or replace function public.sync_approved_request_to_attendance_exception()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_default_start time := coalesce((select default_start_time from public.organization_settings where id = true), time '09:00');
  v_default_end time := coalesce((select default_end_time from public.organization_settings where id = true), time '18:00');
  v_end_date date := coalesce(new.end_date, new.target_date);
  v_exception_type text;
  v_should_create boolean := false;
begin
  if coalesce(new.before_value,'') = '관리자 직접 등록' then return new; end if;

  if new.status = 'approved' then
    if new.request_type = 'business_trip' then
      v_exception_type := 'business_trip';
      v_should_create := true;
    elsif new.request_type in ('annual_leave','comp_time','sick_leave','other_leave')
      and coalesce(new.start_time, v_default_start) <= v_default_start
      and coalesce(new.end_time, v_default_end) >= v_default_end then
      v_exception_type := new.request_type;
      v_should_create := true;
    end if;
  end if;

  if v_should_create then
    if not exists (
      select 1 from public.attendance_exceptions
      where correction_request_id = new.id and cancelled_at is null
    ) and not exists (
      select 1 from public.attendance_exceptions
      where employee_id = new.employee_id
        and cancelled_at is null
        and start_date <= v_end_date
        and end_date >= new.target_date
    ) then
      insert into public.attendance_exceptions (
        employee_id, start_date, end_date, exception_type,
        reason, approved_by, approved_at, correction_request_id
      ) values (
        new.employee_id, new.target_date, v_end_date, v_exception_type,
        case when new.request_type = 'other_leave' and trim(coalesce(new.request_subtype,'')) <> ''
          then trim(new.request_subtype) || ': ' || trim(new.reason)
          else trim(new.reason)
        end,
        coalesce(new.reviewer_id, auth.uid()), coalesce(new.reviewed_at, now()), new.id
      );
    end if;
  else
    update public.attendance_exceptions
    set cancelled_at = coalesce(cancelled_at, now()),
        cancelled_by = coalesce(cancelled_by, auth.uid()),
        cancellation_reason = case when cancellation_reason = '' then '연결된 신청의 승인 상태 변경' else cancellation_reason end
    where correction_request_id = new.id and cancelled_at is null;
  end if;

  return new;
end $$;

drop trigger if exists sync_approved_request_to_attendance_exception_trigger on public.correction_requests;
create trigger sync_approved_request_to_attendance_exception_trigger
after insert or update of status, request_type, target_date, end_date, start_time, end_time
on public.correction_requests
for each row execute function public.sync_approved_request_to_attendance_exception();

insert into public.attendance_exceptions (
  employee_id, start_date, end_date, exception_type,
  reason, approved_by, approved_at, correction_request_id
)
select
  request.employee_id,
  request.target_date,
  coalesce(request.end_date, request.target_date),
  request.request_type,
  case when request.request_type = 'other_leave' and trim(coalesce(request.request_subtype,'')) <> ''
    then trim(request.request_subtype) || ': ' || trim(request.reason)
    else trim(request.reason)
  end,
  request.reviewer_id,
  coalesce(request.reviewed_at, now()),
  request.id
from public.correction_requests request
cross join lateral (
  select
    coalesce((select default_start_time from public.organization_settings where id = true), time '09:00') as default_start,
    coalesce((select default_end_time from public.organization_settings where id = true), time '18:00') as default_end
) settings
where request.status = 'approved'
  and coalesce(request.before_value,'') <> '관리자 직접 등록'
  and request.reviewer_id is not null
  and (
    request.request_type = 'business_trip'
    or (
      request.request_type in ('annual_leave','comp_time','sick_leave','other_leave')
      and coalesce(request.start_time, settings.default_start) <= settings.default_start
      and coalesce(request.end_time, settings.default_end) >= settings.default_end
    )
  )
  and not exists (
    select 1 from public.attendance_exceptions item
    where item.correction_request_id = request.id and item.cancelled_at is null
  )
  and not exists (
    select 1 from public.attendance_exceptions item
    where item.employee_id = request.employee_id
      and item.cancelled_at is null
      and item.start_date <= coalesce(request.end_date, request.target_date)
      and item.end_date >= request.target_date
  );

revoke all on function public.admin_create_attendance_record(uuid,date,time,time,text) from public, anon;
grant execute on function public.admin_create_attendance_record(uuid,date,time,time,text) to authenticated;

notify pgrst, 'reload schema';

commit;


-- ============================================================================
-- supabase/fix_admin_leave_apply_42703.sql
-- ============================================================================

begin;

-- 여러 차례 나누어 설치된 기관 데이터베이스에서 빠질 수 있는 열을 먼저 보완합니다.
alter table public.attendance_records add column if not exists leave_type text not null default 'none';
alter table public.attendance_records add column if not exists is_closed boolean not null default false;
alter table public.attendance_records add column if not exists changed boolean not null default false;
alter table public.attendance_records add column if not exists deleted_at timestamptz;

alter table public.correction_requests add column if not exists end_date date;
alter table public.correction_requests add column if not exists start_time time;
alter table public.correction_requests add column if not exists end_time time;
alter table public.correction_requests add column if not exists calculated_minutes integer not null default 0;
alter table public.correction_requests add column if not exists approved_minutes integer not null default 0;
alter table public.correction_requests add column if not exists request_subtype text not null default '';

alter table public.attendance_audit_logs
  add column if not exists correction_request_id uuid references public.correction_requests(id) on delete restrict;

create or replace function public.admin_apply_leave_to_attendance_record(
  p_record_id uuid,
  p_request_type text,
  p_start_time time,
  p_end_time time,
  p_request_subtype text,
  p_comment text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_request_id uuid;
  v_minutes integer;
  v_leave_type text := 'none';
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_request_type not in ('annual_leave','comp_time','sick_leave','other_leave') then raise exception 'INVALID_LEAVE_TYPE'; end if;
  if char_length(trim(coalesce(p_comment,''))) < 5 then raise exception 'COMMENT_REQUIRED'; end if;
  if p_start_time is null or p_end_time is null or p_end_time <= p_start_time then raise exception 'INVALID_TIME_RANGE'; end if;
  if p_request_type = 'other_leave' and char_length(trim(coalesce(p_request_subtype,''))) < 2 then raise exception 'OTHER_LEAVE_NAME_REQUIRED'; end if;

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;

  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if exists (
    select 1
    from public.monthly_closings
    where year = extract(year from v_record.work_date)
      and month = extract(month from v_record.work_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  v_minutes := public.calculate_attendance_request_minutes(
    p_request_type,
    v_record.work_date,
    v_record.work_date,
    p_start_time,
    p_end_time
  );
  if v_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;

  select id into v_request_id
  from public.correction_requests
  where attendance_record_id = v_record.id
    and request_type in ('annual_leave','comp_time','sick_leave','other_leave')
  order by requested_at desc
  limit 1
  for update;

  if v_request_id is null then
    insert into public.correction_requests (
      attendance_record_id, employee_id, target_date, end_date,
      start_time, end_time, calculated_minutes, approved_minutes,
      request_type, request_subtype, before_value, requested_value, reason,
      status, reviewer_id, reviewer_comment, reviewed_at
    ) values (
      v_record.id, v_record.employee_id, v_record.work_date, v_record.work_date,
      p_start_time, p_end_time, v_minutes, v_minutes,
      p_request_type,
      case when p_request_type = 'other_leave' then trim(coalesce(p_request_subtype,'')) else '' end,
      v_record.attendance_status, v_minutes::text, trim(p_comment),
      'approved', auth.uid(), trim(p_comment), now()
    ) returning id into v_request_id;
  else
    update public.correction_requests
    set target_date = v_record.work_date,
        end_date = v_record.work_date,
        start_time = p_start_time,
        end_time = p_end_time,
        calculated_minutes = v_minutes,
        approved_minutes = v_minutes,
        request_type = p_request_type,
        request_subtype = case when p_request_type = 'other_leave' then trim(coalesce(p_request_subtype,'')) else '' end,
        requested_value = v_minutes::text,
        reason = trim(p_comment),
        status = 'approved',
        reviewer_id = auth.uid(),
        reviewer_comment = trim(p_comment),
        reviewed_at = now()
    where id = v_request_id;
  end if;

  if p_request_type = 'annual_leave' then
    v_leave_type := case v_minutes
      when 480 then 'annual_leave'
      when 240 then 'half_day'
      when 120 then 'quarter_day'
      when 60 then 'hourly_leave'
      else 'none'
    end;
  elsif p_request_type = 'sick_leave' then
    v_leave_type := 'sick_leave';
  end if;

  update public.attendance_records
  set attendance_status = case when clock_out_at is null then 'working' else 'normal' end,
      leave_type = v_leave_type,
      changed = true,
      updated_at = now()
  where id = v_record.id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
  ) values (
    v_record.id, v_record.employee_id, 'admin_leave_applied', 'leave_request',
    jsonb_build_object(
      'attendance_status',v_record.attendance_status,
      'leave_type',coalesce(to_jsonb(v_record)->>'leave_type','none')
    )::text,
    jsonb_build_object('request_type',p_request_type,'start_time',p_start_time,'end_time',p_end_time,'minutes',v_minutes,'subtype',trim(coalesce(p_request_subtype,'')))::text,
    trim(p_comment), auth.uid(), v_role, v_request_id
  );

  return v_request_id;
end $$;

revoke all on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) from public, anon;
grant execute on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) to authenticated;

-- 대체휴무 사용일이 다음 달이어도 발생일의 유효 적립분에서 먼저 차감합니다.
-- 적립분보다 많이 사용한 경우 잔액을 음수로 만들지 않고 미연결 사용 이력만 남깁니다.
create table if not exists public.comp_time_credits (
  id uuid primary key default gen_random_uuid(),
  attendance_record_id uuid not null unique references public.attendance_records(id) on delete restrict,
  employee_id uuid not null references public.profiles(id) on delete restrict,
  granted_minutes integer not null,
  remaining_minutes integer not null,
  expires_on date not null,
  granted_by uuid not null references public.profiles(id) on delete restrict,
  granted_at timestamptz not null default now(),
  reason text not null default ''
);

create table if not exists public.comp_time_usage_allocations (
  id uuid primary key default gen_random_uuid(),
  correction_request_id uuid not null references public.correction_requests(id) on delete restrict,
  credit_id uuid not null references public.comp_time_credits(id) on delete restrict,
  used_minutes integer not null check (used_minutes > 0),
  created_at timestamptz not null default now(),
  unique (correction_request_id, credit_id)
);

create or replace function public.allocate_comp_time_usage_without_negative()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_allocation record;
  v_credit record;
  v_needed integer := 0;
  v_use integer := 0;
begin
  for v_allocation in
    select credit_id, used_minutes
    from public.comp_time_usage_allocations
    where correction_request_id = new.id
  loop
    update public.comp_time_credits
    set remaining_minutes = least(granted_minutes, remaining_minutes + v_allocation.used_minutes)
    where id = v_allocation.credit_id;
  end loop;

  delete from public.comp_time_usage_allocations
  where correction_request_id = new.id;

  if new.status <> 'approved' or new.request_type <> 'comp_time' then
    return new;
  end if;

  v_needed := greatest(
    0,
    coalesce(
      nullif(new.approved_minutes, 0),
      nullif(new.calculated_minutes, 0),
      case when new.requested_value ~ '^[0-9]+$' then new.requested_value::integer else 0 end
    )
  );

  for v_credit in
    select credit.*
    from public.comp_time_credits credit
    join public.attendance_records attendance on attendance.id = credit.attendance_record_id
    where credit.employee_id = new.employee_id
      and credit.remaining_minutes > 0
      and credit.expires_on >= new.target_date
      and attendance.work_date < new.target_date
      and attendance.deleted_at is null
    order by credit.expires_on, attendance.work_date, credit.granted_at
    for update of credit
  loop
    exit when v_needed <= 0;
    v_use := least(v_needed, v_credit.remaining_minutes);

    update public.comp_time_credits
    set remaining_minutes = remaining_minutes - v_use
    where id = v_credit.id;

    insert into public.comp_time_usage_allocations (
      correction_request_id, credit_id, used_minutes
    ) values (
      new.id, v_credit.id, v_use
    );

    v_needed := v_needed - v_use;
  end loop;

  if v_needed > 0 then
    insert into public.attendance_audit_logs (
      attendance_record_id, employee_id, action_type, changed_field,
      before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
    ) values (
      new.attendance_record_id, new.employee_id,
      'comp_time_usage_unallocated', 'comp_time_balance',
      '', v_needed::text,
      '승인된 대체휴무 중 적립 이력과 아직 연결되지 않은 시간입니다. 잔액은 음수로 계산하지 않습니다.',
      coalesce(new.reviewer_id, auth.uid()), public.current_profile_role(), new.id
    );
  end if;

  return new;
end $$;

drop trigger if exists allocate_comp_time_usage_without_negative_trigger on public.correction_requests;
create trigger allocate_comp_time_usage_without_negative_trigger
after insert or update of status, request_type, approved_minutes, calculated_minutes, requested_value
on public.correction_requests
for each row execute function public.allocate_comp_time_usage_without_negative();

notify pgrst, 'reload schema';

commit;


-- ============================================================================
-- supabase/fix_attendance_status_after_time_edit.sql
-- ============================================================================

begin;

-- 출퇴근시각이 수정되면 최초 기록 당시의 상태값을 그대로 두지 않고
-- 수정된 시각, 근무일, 위치, 휴가시간을 기준으로 상태를 다시 계산합니다.
create or replace function public.derive_attendance_status(p_record public.attendance_records)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_default_start_time time := '09:00';
  v_break_minutes integer := 60;
  v_late_grace_minutes integer := 0;
  v_is_regular_workday boolean;
  v_location_review boolean;
  v_elapsed_minutes integer;
  v_worked_minutes integer;
  v_required_minutes integer := 480;
  v_leave_type text := 'none';
begin
  select
    coalesce((select default_start_time from public.organization_settings where id = true), '09:00'::time),
    coalesce((select break_minutes from public.organization_settings where id = true), 60),
    coalesce((select late_grace_minutes from public.organization_settings where id = true), 0)
  into v_default_start_time, v_break_minutes, v_late_grace_minutes;
  v_leave_type := coalesce(to_jsonb(p_record)->>'leave_type', 'none');

  if p_record.clock_in_at is null then
    return case
      when v_leave_type in ('annual_leave','half_day','quarter_day','hourly_leave','sick_leave') then v_leave_type
      when p_record.attendance_status in ('business_trip','leave') then p_record.attendance_status
      else 'missing_in'
    end;
  end if;

  v_is_regular_workday := extract(isodow from p_record.work_date) between 1 and 5
    and not exists (
      select 1 from public.holidays h
      where h.holiday_date = p_record.work_date and h.is_paid_holiday
    );

  v_location_review :=
    (p_record.clock_in_location_status in ('outside','low_accuracy') and not coalesce(p_record.clock_in_ip_matched, false))
    or
    (p_record.clock_out_at is not null and p_record.clock_out_location_status in ('outside','low_accuracy') and not coalesce(p_record.clock_out_ip_matched, false));

  if v_location_review then return 'admin_review'; end if;
  if not v_is_regular_workday then return 'holiday_work'; end if;

  if (p_record.clock_in_at at time zone 'Asia/Seoul')::time
      > v_default_start_time + make_interval(mins => v_late_grace_minutes) then
    return 'late';
  end if;

  if p_record.clock_out_at is null then return 'working'; end if;

  v_required_minutes := case v_leave_type
    when 'half_day' then 240
    when 'quarter_day' then 360
    when 'hourly_leave' then 420
    when 'annual_leave' then 0
    when 'sick_leave' then 0
    else 480
  end;
  v_elapsed_minutes := greatest(0, floor(extract(epoch from (p_record.clock_out_at - p_record.clock_in_at)) / 60)::integer);
  v_worked_minutes := greatest(0, v_elapsed_minutes - case when v_elapsed_minutes >= 360 then v_break_minutes else 0 end);

  return case when v_worked_minutes < v_required_minutes then 'admin_review' else 'normal' end;
end $$;

create or replace function public.recalculate_attendance_status_on_time_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.attendance_status := public.derive_attendance_status(new);
  return new;
end $$;

drop trigger if exists recalculate_attendance_status_after_time_edit on public.attendance_records;
create trigger recalculate_attendance_status_after_time_edit
before update of clock_in_at, clock_out_at on public.attendance_records
for each row
when (old.clock_in_at is distinct from new.clock_in_at or old.clock_out_at is distinct from new.clock_out_at)
execute function public.recalculate_attendance_status_on_time_change();

-- 이미 시각을 고쳤지만 상태가 예전 값으로 남은 기록도 즉시 정정합니다.
update public.attendance_records ar
set attendance_status = public.derive_attendance_status(ar), updated_at = now()
where ar.deleted_at is null
  and ar.clock_in_at is not null
  and ar.attendance_status is distinct from public.derive_attendance_status(ar);

-- 출퇴근기록이 없다는 이유만으로 결근을 확정하지 않습니다.
-- 과거에 자동 생성된 결근 행은 목록에서 숨기되 삭제 사유와 원본 행은 보존합니다.
update public.attendance_records
set deleted_at = coalesce(deleted_at, now()),
    deletion_reason = case when coalesce(deletion_reason, '') = '' then '자동 결근 판정 폐지로 목록에서 제외' else deletion_reason end,
    updated_at = now()
where deleted_at is null
  and attendance_status = 'absent'
  and clock_in_at is null
  and clock_out_at is null
  and note like '자동 판정%';

-- 관리자가 직접 입력한 기존 결근 표시는 단정하지 않고 확인 필요로 전환합니다.
update public.attendance_records
set attendance_status = 'admin_review',
    note = trim(concat_ws(E'\n', nullif(note, ''), '출퇴근기록 없음, 휴가 또는 기타 사유 확인 필요')),
    updated_at = now()
where deleted_at is null and attendance_status = 'absent';

-- 앞으로 월 재계산을 실행해도 빈 날짜에 결근 행을 새로 만들지 않습니다.
create or replace function public.recalculate_attendance_month(p_year integer, p_month integer)
returns void language plpgsql security definer set search_path = public as $$
declare v_start date; v_end date; v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if not public.is_attendance_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  v_start := make_date(p_year, p_month, 1);
  v_end := (v_start + interval '1 month')::date;
  update public.attendance_records
  set attendance_status = case
      when clock_in_at is null and clock_out_at is not null then 'missing_in'
      when clock_in_at is not null and clock_out_at is null and work_date < v_today then 'missing_out'
      else attendance_status end,
      updated_at = now()
  where work_date >= v_start and work_date < v_end and not is_closed and deleted_at is null;
end $$;

-- 외근, 교육, 당일 출장은 하루 근무유형으로 선택하지 않습니다.
update public.work_type_settings set is_active = false where work_type in ('field', 'education', 'business_trip');

-- 삭제된 기록도 월별 변경 이력 엑셀에 포함할 수 있도록 대상 근무일을 제공합니다.
create or replace view public.attendance_audit_logs_view with (security_invoker = true) as
select al.*, employee.name as employee_name, actor.name as changed_by_name, attendance.work_date as target_work_date
from public.attendance_audit_logs al
join public.profiles employee on employee.id = al.employee_id
left join public.profiles actor on actor.id = al.changed_by
left join public.attendance_records attendance on attendance.id = al.attendance_record_id;
grant select on public.attendance_audit_logs_view to authenticated;

revoke all on function public.derive_attendance_status(public.attendance_records) from public, anon;
revoke all on function public.recalculate_attendance_status_on_time_change() from public, anon;
revoke all on function public.recalculate_attendance_month(integer,integer) from public, anon;
grant execute on function public.recalculate_attendance_month(integer,integer) to authenticated;
notify pgrst, 'reload schema';
commit;

select '출퇴근시각 수정 후 근태상태 자동 재계산 적용 완료' as result;


-- ============================================================================
-- supabase/upgrade_employee_management.sql
-- ============================================================================

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


-- ============================================================================
-- supabase/upgrade_secure_clock_and_overnight.sql
-- ============================================================================

begin;

-- 브라우저가 사무실 IP를 임의로 전달하지 못하도록 출퇴근 저장은 서버 전용 함수로 제한합니다.
-- GPS 좌표는 기기에서 전달되므로 관리자 확인 절차를 계속 유지합니다.
-- PC의 자동 위치 오차 문구는 위치 이력과 감사 로그로 확인할 수 있으므로 일반 비고에서는 제거합니다.
update public.attendance_records
set note = trim(regexp_replace(
  note,
  '(^|\n)사무실 PC에서 기록, 위치 측정 오차 [^\n]*',
  '',
  'g'
))
where note like '%사무실 PC에서 기록, 위치 측정 오차%';

create or replace function public.clock_attendance_server(
  p_employee_id uuid,
  p_action text,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy numeric,
  p_location_status text,
  p_ip_address text,
  p_note text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.profiles;
  v_workplace public.workplaces;
  v_settings public.organization_settings;
  v_record public.attendance_records;
  v_now timestamptz := now();
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_work_date date;
  v_distance numeric;
  v_location_status text;
  v_ip_matched boolean := false;
  v_attendance_status text;
  v_is_regular_workday boolean;
  v_raw_overtime integer := 0;
  v_recorded_overtime integer := 0;
  v_record_note text;
begin
  if p_action not in ('clock_in','clock_out') then raise exception 'INVALID_ACTION'; end if;
  if p_employee_id is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_user from public.profiles where id = p_employee_id and is_active = true;
  if not found then raise exception 'INACTIVE_OR_UNKNOWN_USER'; end if;
  select * into v_workplace from public.workplaces where is_active order by created_at limit 1;
  if not found then raise exception 'WORKPLACE_NOT_CONFIGURED'; end if;
  select * into v_settings from public.organization_settings where id = true;

  v_ip_matched := nullif(trim(v_settings.office_ip_address), '') is not null
    and trim(coalesce(p_ip_address, '')) = trim(v_settings.office_ip_address);
  if p_latitude is not null and p_longitude is not null then
    v_distance := public.distance_meters(p_latitude, p_longitude, v_workplace.latitude, v_workplace.longitude);
    if p_accuracy is null or p_accuracy > v_workplace.low_accuracy_threshold_meters then
      v_location_status := 'low_accuracy';
    elsif v_distance <= v_workplace.allowed_radius_meters then
      v_location_status := 'inside';
    else
      v_location_status := 'outside';
    end if;
  else
    v_location_status := case
      when p_location_status in ('permission_denied','unavailable') then p_location_status
      else 'unavailable'
    end;
  end if;
  if v_ip_matched then v_location_status := 'inside'; end if;
  if v_location_status <> 'inside' and char_length(trim(coalesce(p_note,''))) < 2 then
    raise exception 'LOCATION_REASON_REQUIRED';
  end if;
  v_record_note := case
    when coalesce(p_note, '') like '사무실 PC에서 기록, 위치 측정 오차 %' then ''
    else coalesce(p_note, '')
  end;

  if p_action = 'clock_out' then
    select * into v_record
    from public.attendance_records
    where employee_id = p_employee_id
      and clock_in_at is not null
      and clock_out_at is null
      and deleted_at is null
      and work_date between v_today - 1 and v_today
      and clock_in_at >= v_now - interval '24 hours'
    order by clock_in_at desc
    limit 1
    for update;
    if not found then raise exception 'CLOCK_IN_REQUIRED'; end if;
    v_work_date := v_record.work_date;
  else
    v_work_date := v_today;
  end if;

  if exists (
    select 1 from public.monthly_closings
    where year = extract(year from v_work_date)
      and month = extract(month from v_work_date)
      and status = 'closed'
  ) then raise exception 'MONTH_CLOSED'; end if;

  v_is_regular_workday := extract(isodow from v_work_date)::smallint = any(v_settings.work_days)
    and not exists (select 1 from public.holidays where holiday_date = v_work_date);

  insert into public.attendance_events (employee_id, work_date, action_type, idempotency_key)
  values (p_employee_id, v_work_date, p_action, p_idempotency_key);

  if p_action = 'clock_in' then
    if exists (
      select 1 from public.attendance_records
      where employee_id = p_employee_id and work_date = v_work_date
        and clock_in_at is not null and deleted_at is null
    ) then raise exception 'ALREADY_CLOCKED_IN'; end if;
    v_attendance_status := case
      when v_location_status <> 'inside' then 'admin_review'
      when not v_is_regular_workday then 'holiday_work'
      when (v_now at time zone 'Asia/Seoul')::time > v_settings.default_start_time + make_interval(mins => v_settings.late_grace_minutes) then 'late'
      else 'working'
    end;
    insert into public.attendance_records (
      employee_id, work_date, work_type, clock_in_at, clock_in_accuracy, clock_in_distance,
      clock_in_location_status, clock_in_ip_address, clock_in_ip_matched, attendance_status,
      note, raw_overtime_minutes, recorded_overtime_minutes, overtime_status,
      approved_overtime_minutes, leave_type
    ) values (
      p_employee_id, v_work_date, 'office', v_now, p_accuracy, v_distance,
      v_location_status, nullif(trim(p_ip_address), ''), v_ip_matched, v_attendance_status,
      v_record_note, 0, 0, 'none', 0, 'none'
    )
    on conflict (employee_id, work_date) do update set
      work_type = 'office', clock_in_at = excluded.clock_in_at,
      clock_in_accuracy = excluded.clock_in_accuracy, clock_in_distance = excluded.clock_in_distance,
      clock_in_location_status = excluded.clock_in_location_status,
      clock_in_ip_address = excluded.clock_in_ip_address,
      clock_in_ip_matched = excluded.clock_in_ip_matched,
      attendance_status = excluded.attendance_status,
      clock_out_at = null, clock_out_accuracy = null, clock_out_distance = null,
      clock_out_location_status = 'not_checked', clock_out_ip_address = null,
      clock_out_ip_matched = false, note = excluded.note,
      raw_overtime_minutes = 0, recorded_overtime_minutes = 0,
      overtime_status = 'none', approved_overtime_minutes = 0, comp_time_eligible_minutes = 0,
      deleted_at = null, deleted_by = null, deletion_reason = '', updated_at = now()
    returning * into v_record;
  else
    v_raw_overtime := public.calculate_raw_overtime_minutes(v_work_date, v_record.clock_in_at, v_now);
    v_recorded_overtime := public.recognized_overtime_minutes(v_raw_overtime);
    v_attendance_status := case
      when v_location_status <> 'inside' then 'admin_review'
      when not v_is_regular_workday then 'holiday_work'
      when v_record.attendance_status = 'late' then 'late'
      when greatest(0, floor(extract(epoch from (v_now - v_record.clock_in_at)) / 60)::integer
        - case when extract(epoch from (v_now - v_record.clock_in_at)) / 60 >= 360 then v_settings.break_minutes else 0 end) < 480 then 'admin_review'
      else 'normal'
    end;
    update public.attendance_records set
      clock_out_at = v_now,
      clock_out_accuracy = p_accuracy,
      clock_out_distance = v_distance,
      clock_out_location_status = v_location_status,
      clock_out_ip_address = nullif(trim(p_ip_address), ''),
      clock_out_ip_matched = v_ip_matched,
      attendance_status = v_attendance_status,
      raw_overtime_minutes = v_raw_overtime,
      recorded_overtime_minutes = v_recorded_overtime,
      overtime_status = case when v_recorded_overtime > 0 then 'pending' else 'none' end,
      approved_overtime_minutes = 0,
      comp_time_eligible_minutes = 0,
      note = trim(concat_ws(E'\n', nullif(note,''), nullif(v_record_note,'')))
    where id = v_record.id
    returning * into v_record;
  end if;

  update public.attendance_events set attendance_record_id = v_record.id
  where employee_id = p_employee_id and idempotency_key = p_idempotency_key;
  insert into public.attendance_locations (
    attendance_record_id, employee_id, event_type, latitude, longitude,
    ip_address, ip_matched, captured_at
  ) values (
    v_record.id, p_employee_id, p_action, p_latitude, p_longitude,
    nullif(trim(p_ip_address), ''), v_ip_matched, v_now
  )
  on conflict (attendance_record_id, event_type) do update set
    latitude = excluded.latitude,
    longitude = excluded.longitude,
    ip_address = excluded.ip_address,
    ip_matched = excluded.ip_matched,
    captured_at = excluded.captured_at;
  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    after_value, reason, changed_by, changed_by_role
  ) values (
    v_record.id, p_employee_id, p_action, p_action || '_at',
    v_now::text, coalesce(p_note,''), p_employee_id, v_user.role
  );
  return v_record.id;
exception when unique_violation then
  raise exception 'DUPLICATE_CLOCK_REQUEST';
end
$$;

-- 이전 브라우저 직접 RPC는 차단하고 서버 비밀키 역할에만 새 함수를 허용합니다.
revoke all on function public.clock_attendance(text,text,double precision,double precision,numeric,text,text,text,uuid) from public, anon, authenticated;
revoke all on function public.clock_attendance_server(uuid,text,double precision,double precision,numeric,text,text,text,uuid) from public, anon, authenticated;
grant execute on function public.clock_attendance_server(uuid,text,double precision,double precision,numeric,text,text,text,uuid) to service_role;

notify pgrst, 'reload schema';
commit;

-- ============================================================================
-- supabase/upgrade_batch_training_actual_overtime.sql
-- ============================================================================
begin;

-- 종일 외부교육을 출퇴근 기록 예외로 보존합니다.
do $$
declare v_constraint record;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.attendance_exceptions'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%exception_type%'
  loop
    execute format('alter table public.attendance_exceptions drop constraint %I', v_constraint.conname);
  end loop;
end $$;

alter table public.attendance_exceptions
  add constraint attendance_exceptions_exception_type_check
  check (exception_type in (
    'business_trip','external_training','approved_other',
    'annual_leave','comp_time','sick_leave','other_leave'
  )) not valid;

-- 여러 직원의 근무기록을 한 번에 만들고 기존 기록은 이름과 함께 제외합니다.
create or replace function public.admin_create_attendance_records(
  p_employee_ids uuid[],
  p_work_date date,
  p_clock_in_time time,
  p_clock_out_time time,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_employee_id uuid;
  v_employee_name text;
  v_created integer := 0;
  v_skipped_names text[] := array[]::text[];
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if coalesce(array_length(p_employee_ids,1),0) = 0 then raise exception 'EMPLOYEE_REQUIRED'; end if;
  if p_work_date is null or p_clock_in_time is null or p_clock_out_time is null then raise exception 'REQUIRED_VALUE_MISSING'; end if;
  if p_clock_out_time <= p_clock_in_time then raise exception 'INVALID_TIME_RANGE'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;

  foreach v_employee_id in array p_employee_ids loop
    select name into v_employee_name
    from public.profiles
    where id = v_employee_id and role = 'employee' and is_active = true;

    if not found then
      v_skipped_names := array_append(v_skipped_names, '비활성 또는 미확인 직원');
    elsif exists (
      select 1 from public.attendance_records
      where employee_id = v_employee_id and work_date = p_work_date and deleted_at is null
    ) then
      v_skipped_names := array_append(v_skipped_names, v_employee_name);
    else
      perform public.admin_create_attendance_record(
        v_employee_id, p_work_date, p_clock_in_time, p_clock_out_time, p_reason
      );
      v_created := v_created + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'created_count', v_created,
    'skipped_count', coalesce(array_length(v_skipped_names,1),0),
    'skipped_names', to_jsonb(v_skipped_names)
  );
end $$;

-- 출장, 외부교육, 종일 휴가를 여러 직원에게 일괄 등록합니다.
create or replace function public.admin_create_attendance_exceptions(
  p_employee_ids uuid[],
  p_start_date date,
  p_end_date date,
  p_exception_type text,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_employee_id uuid;
  v_employee_name text;
  v_created integer := 0;
  v_skipped_names text[] := array[]::text[];
  v_id uuid;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if coalesce(array_length(p_employee_ids,1),0) = 0 then raise exception 'EMPLOYEE_REQUIRED'; end if;
  if p_end_date < p_start_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_exception_type not in ('business_trip','external_training','approved_other','annual_leave','comp_time','sick_leave','other_leave') then raise exception 'INVALID_EXCEPTION_TYPE'; end if;
  if p_exception_type in ('external_training','other_leave') and char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;

  foreach v_employee_id in array p_employee_ids loop
    select name into v_employee_name
    from public.profiles
    where id = v_employee_id and role = 'employee' and is_active = true;

    if not found then
      v_skipped_names := array_append(v_skipped_names, '비활성 또는 미확인 직원');
    elsif exists (
      select 1 from public.attendance_exceptions
      where employee_id = v_employee_id
        and cancelled_at is null
        and start_date <= p_end_date
        and end_date >= p_start_date
    ) then
      v_skipped_names := array_append(v_skipped_names, v_employee_name);
    elsif p_exception_type = 'external_training' then
      insert into public.attendance_exceptions (
        employee_id, start_date, end_date, exception_type, reason, approved_by
      ) values (
        v_employee_id, p_start_date, p_end_date, p_exception_type,
        trim(coalesce(p_reason,'')), auth.uid()
      ) returning id into v_id;

      insert into public.attendance_audit_logs (
        employee_id, action_type, changed_field, before_value, after_value,
        reason, changed_by, changed_by_role
      ) values (
        v_employee_id, 'exception_create', 'attendance_exception', '',
        jsonb_build_object(
          'id',v_id,'start_date',p_start_date,'end_date',p_end_date,
          'exception_type',p_exception_type
        )::text,
        trim(coalesce(p_reason,'')), auth.uid(), v_role
      );
      v_created := v_created + 1;
    else
      perform public.admin_create_attendance_exception(
        v_employee_id, p_start_date, p_end_date, p_exception_type, p_reason
      );
      v_created := v_created + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'created_count', v_created,
    'skipped_count', coalesce(array_length(v_skipped_names,1),0),
    'skipped_names', to_jsonb(v_skipped_names)
  );
end $$;

-- 출퇴근 사이에 승인된 휴가가 있으면 점심시간과 겹치지 않는 분만 실제 근무에서 제외합니다.
create or replace function public.approved_leave_minutes_during_attendance(
  p_employee_id uuid,
  p_clock_in timestamptz,
  p_clock_out timestamptz
) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(count(*),0)::integer
  from generate_series(
    date_trunc('minute', p_clock_in at time zone 'Asia/Seoul'),
    date_trunc('minute', p_clock_out at time zone 'Asia/Seoul') - interval '1 minute',
    interval '1 minute'
  ) as minute_point
  where minute_point::time >= time '09:00'
    and minute_point::time < time '18:00'
    and not (minute_point::time >= time '12:00' and minute_point::time < time '13:00')
    and exists (
      select 1
      from public.correction_requests request
      where request.employee_id = p_employee_id
        and request.status = 'approved'
        and request.request_type in ('annual_leave','comp_time','sick_leave','other_leave')
        and minute_point::date between request.target_date and coalesce(request.end_date,request.target_date)
        and minute_point::time >= case
          when minute_point::date = request.target_date then coalesce(request.start_time,time '09:00')
          else time '09:00'
        end
        and minute_point::time < case
          when minute_point::date = coalesce(request.end_date,request.target_date) then coalesce(request.end_time,time '18:00')
          else time '18:00'
        end
    )
$$;

-- 실제 근무시간은 출퇴근 간격에서 점심시간과 승인 휴가시간을 제외해 계산합니다.
create or replace function public.recalculate_overtime_after_attendance_change()
returns trigger language plpgsql set search_path = public as $$
declare
  v_settings public.organization_settings;
  v_worked integer := 0;
  v_lunch integer := 0;
  v_leave integer := 0;
  v_actual integer := 0;
  v_raw integer := 0;
  v_recognized integer := 0;
  v_lunch_from timestamptz;
  v_lunch_until timestamptz;
  v_is_holiday boolean := false;
  v_should_reopen boolean := false;
begin
  select * into v_settings from public.organization_settings where id = true;
  if new.clock_in_at is not null and new.clock_out_at is not null and new.clock_out_at > new.clock_in_at then
    v_worked := floor(extract(epoch from (new.clock_out_at - new.clock_in_at)) / 60)::integer;
    v_lunch_from := (new.work_date + time '12:00') at time zone 'Asia/Seoul';
    v_lunch_until := (new.work_date + time '13:00') at time zone 'Asia/Seoul';
    if least(new.clock_out_at, v_lunch_until) > greatest(new.clock_in_at, v_lunch_from) then
      v_lunch := floor(extract(epoch from (least(new.clock_out_at, v_lunch_until) - greatest(new.clock_in_at, v_lunch_from))) / 60)::integer;
    end if;
    v_leave := public.approved_leave_minutes_during_attendance(new.employee_id,new.clock_in_at,new.clock_out_at);
    v_is_holiday := extract(isodow from new.work_date)::smallint <> all(v_settings.work_days)
      or exists (select 1 from public.holidays where holiday_date = new.work_date);
    v_actual := greatest(0, v_worked - case when v_is_holiday then 0 else v_lunch end - v_leave);
    v_raw := case when v_is_holiday then v_actual else greatest(0, v_actual - 480) end;
    v_recognized := case when v_is_holiday then v_raw else public.recognized_overtime_minutes(v_raw) end;
  end if;

  v_should_reopen := tg_op = 'INSERT'
    or old.clock_in_at is distinct from new.clock_in_at
    or old.clock_out_at is distinct from new.clock_out_at
    or new.overtime_status = 'pending';
  new.raw_overtime_minutes := v_raw;
  new.recorded_overtime_minutes := v_recognized;
  if v_recognized > 0 and v_should_reopen then
    new.overtime_status := 'pending';
    new.approved_overtime_minutes := 0;
    new.comp_time_eligible_minutes := 0;
  elsif v_recognized = 0 then
    new.overtime_status := 'none';
    new.approved_overtime_minutes := 0;
    new.comp_time_eligible_minutes := 0;
  end if;
  return new;
end $$;

drop trigger if exists attendance_refresh_overtime on public.attendance_records;
drop trigger if exists recalculate_overtime_after_attendance_change_trigger on public.attendance_records;
create trigger recalculate_overtime_after_attendance_change_trigger
before insert or update of clock_in_at,clock_out_at
on public.attendance_records
for each row execute function public.recalculate_overtime_after_attendance_change();

-- 휴가 승인, 재검토, 시간 변경 시 연결된 실제 근무시간을 다시 계산합니다.
create or replace function public.recalculate_attendance_after_leave_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.request_type not in ('annual_leave','comp_time','sick_leave','other_leave') then return new; end if;
  if tg_op = 'UPDATE'
     and old.status is not distinct from new.status
     and old.target_date is not distinct from new.target_date
     and old.end_date is not distinct from new.end_date
     and old.start_time is not distinct from new.start_time
     and old.end_time is not distinct from new.end_time then
    return new;
  end if;

  update public.comp_time_credits credit
  set remaining_minutes = 0,
      reason = trim(concat_ws(E'\n',credit.reason,'휴가 반영으로 실제 근무시간 재검토'))
  where credit.attendance_record_id in (
    select record.id
    from public.attendance_records record
    where record.employee_id = new.employee_id
      and record.work_date between new.target_date and coalesce(new.end_date,new.target_date)
      and record.deleted_at is null
  ) and credit.remaining_minutes > 0;

  update public.attendance_records record
  set overtime_status = 'pending',
      approved_overtime_minutes = 0,
      comp_time_eligible_minutes = 0,
      clock_out_at = record.clock_out_at,
      changed = true,
      updated_at = now()
  where record.employee_id = new.employee_id
    and record.work_date between new.target_date and coalesce(new.end_date,new.target_date)
    and record.deleted_at is null
    and record.clock_in_at is not null
    and record.clock_out_at is not null;
  return new;
end $$;

drop trigger if exists recalculate_attendance_after_leave_request_trigger on public.correction_requests;
create trigger recalculate_attendance_after_leave_request_trigger
after insert or update of status,target_date,end_date,start_time,end_time
on public.correction_requests
for each row execute function public.recalculate_attendance_after_leave_request();

-- 직원의 시간외 신청 승인값을 실제 퇴근기록과 신청시간 중 작은 값으로 확정합니다.
create or replace function public.sync_overtime_request_to_attendance()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_final integer := 0;
begin
  if new.request_type <> 'overtime' then return new; end if;

  if new.status = 'approved' then
    select * into v_record
    from public.attendance_records
    where deleted_at is null
      and employee_id = new.employee_id
      and work_date = new.target_date
    for update;
    if not found or v_record.clock_out_at is null or coalesce(v_record.recorded_overtime_minutes,0) <= 0 then
      raise exception 'ACTUAL_OVERTIME_REQUIRED';
    end if;
    -- 관리자가 실제 인정시간을 줄여 승인한 경우 그 값을 다시 신청시간으로 덮어쓰지 않습니다.
    v_final := least(
      coalesce(nullif(new.approved_minutes,0),new.calculated_minutes,0),
      v_record.recorded_overtime_minutes
    );
    if v_final <= 0 then raise exception 'ACTUAL_OVERTIME_REQUIRED'; end if;

    update public.correction_requests
    set attendance_record_id = v_record.id,
        approved_minutes = v_final
    where id = new.id;

    if v_record.overtime_status <> 'approved'
       or v_record.approved_overtime_minutes <> v_final
       or v_record.comp_time_eligible_minutes <> 0 then
      update public.attendance_records
      set overtime_status = 'approved',
          approved_overtime_minutes = v_final,
          comp_time_eligible_minutes = 0,
          changed = true,
          updated_at = now()
      where id = v_record.id;

      insert into public.attendance_audit_logs (
        attendance_record_id, employee_id, action_type, changed_field,
        before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
      ) values (
        v_record.id, new.employee_id, 'overtime_review', 'approved_overtime_minutes',
        jsonb_build_object('status',v_record.overtime_status,'minutes',v_record.approved_overtime_minutes)::text,
        jsonb_build_object('status','approved','requested_minutes',new.calculated_minutes,'actual_minutes',v_record.recorded_overtime_minutes,'approved_minutes',v_final)::text,
        coalesce(nullif(trim(new.reviewer_comment),''),new.reason),
        coalesce(new.reviewer_id,auth.uid()), public.current_profile_role(), new.id
      );
    end if;
  elsif tg_op = 'UPDATE' and old.status = 'approved' and new.status <> 'approved' then
    update public.attendance_records
    set overtime_status = case when recorded_overtime_minutes > 0 then 'pending' else 'none' end,
        approved_overtime_minutes = 0,
        comp_time_eligible_minutes = 0,
        changed = true,
        updated_at = now()
    where employee_id = new.employee_id and work_date = new.target_date and deleted_at is null;
  end if;
  return new;
end $$;

drop trigger if exists sync_overtime_request_to_attendance_trigger on public.correction_requests;
create trigger sync_overtime_request_to_attendance_trigger
after insert or update of status
on public.correction_requests
for each row execute function public.sync_overtime_request_to_attendance();

-- 통합 요청 승인 함수에서 시간외근무는 실제 퇴근기록을 먼저 확인합니다.
create or replace function public.review_correction_request(
  p_request_id uuid,
  p_decision text,
  p_comment text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_before text := '';
  v_after text := '';
  v_approved integer := 0;
  v_week_total integer := 0;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected','more_info') then raise exception 'INVALID_DECISION'; end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_comment,''))) < 2 then raise exception 'COMMENT_REQUIRED'; end if;

  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found or v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_REVIEWABLE'; end if;
  if exists (
    select 1 from public.monthly_closings
    where year = extract(year from v_request.target_date)
      and month = extract(month from v_request.target_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  if p_decision = 'approved' and v_request.request_type in ('clock_in_at','clock_out_at') then
    select * into v_record from public.attendance_records
    where id = v_request.attendance_record_id and deleted_at is null for update;
    if not found and v_request.request_type = 'clock_in_at' then
      insert into public.attendance_records (employee_id, work_date, work_type, attendance_status, note, changed)
      values (v_request.employee_id, v_request.target_date, 'office', 'missing_out', '수정 요청으로 생성된 기록', true)
      on conflict (employee_id, work_date) do update
      set changed = true, deleted_at = null, deleted_by = null, deletion_reason = '', updated_at = now()
      returning * into v_record;
      update public.correction_requests set attendance_record_id = v_record.id where id = v_request.id;
    elsif not found then
      raise exception 'CLOCK_IN_CORRECTION_REQUIRED_FIRST';
    end if;

    if v_request.request_type = 'clock_in_at' then
      v_before := coalesce(v_record.clock_in_at::text,'');
      update public.attendance_records
      set clock_in_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true
      where id = v_record.id returning clock_in_at::text into v_after;
    else
      v_before := coalesce(v_record.clock_out_at::text,'');
      update public.attendance_records
      set clock_out_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true
      where id = v_record.id returning clock_out_at::text into v_after;
    end if;
  elsif p_decision = 'approved' then
    if v_request.request_type = 'overtime' then
      select * into v_record
      from public.attendance_records
      where deleted_at is null
        and employee_id = v_request.employee_id
        and work_date = v_request.target_date
      for update;
      if not found or v_record.clock_out_at is null or coalesce(v_record.recorded_overtime_minutes,0) <= 0 then
        raise exception 'ACTUAL_OVERTIME_REQUIRED';
      end if;
      v_approved := least(v_request.calculated_minutes,v_record.recorded_overtime_minutes);
      select coalesce(sum(approved_minutes),0)::integer into v_week_total
      from public.correction_requests
      where employee_id = v_request.employee_id
        and request_type = 'overtime'
        and status = 'approved'
        and id <> v_request.id
        and target_date >= date_trunc('week',v_request.target_date::timestamp)::date
        and target_date < date_trunc('week',v_request.target_date::timestamp)::date + 7;
      if v_week_total + v_approved > 720 then raise exception 'WEEKLY_OVERTIME_LIMIT'; end if;
      update public.correction_requests set attendance_record_id = v_record.id where id = v_request.id;
    else
      v_approved := v_request.calculated_minutes;
    end if;
    v_before := '미승인';
    v_after := jsonb_build_object(
      'start_date',v_request.target_date,'end_date',v_request.end_date,
      'start_time',v_request.start_time,'end_time',v_request.end_time,
      'requested_minutes',v_request.calculated_minutes,'approved_minutes',v_approved,
      'subtype',v_request.request_subtype
    )::text;
    update public.correction_requests set approved_minutes = v_approved where id = v_request.id;
  end if;

  if p_decision = 'approved' then
    insert into public.attendance_audit_logs (
      attendance_record_id, employee_id, action_type, changed_field,
      before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
    ) values (
      coalesce(v_record.id,v_request.attendance_record_id),v_request.employee_id,'request_approved',v_request.request_type,
      v_before,v_after,coalesce(nullif(trim(p_comment),''),v_request.reason),auth.uid(),v_role,v_request.id
    );
  end if;

  update public.correction_requests
  set status = p_decision,
      reviewer_id = auth.uid(),
      reviewer_comment = coalesce(p_comment,''),
      reviewed_at = now()
  where id = p_request_id;
end $$;

-- 기록 화면에서 직접 시간외근무를 재검토할 때도 신청시간 상한을 지킵니다.
create or replace function public.admin_review_overtime(
  p_record_id uuid,
  p_decision text,
  p_approved_minutes integer,
  p_comp_time_minutes integer,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_request public.correction_requests;
  v_role text := public.current_profile_role();
  v_week_start date;
  v_week_total integer := 0;
  v_raw_minutes integer := 0;
  v_comp_time_limit integer := 0;
  v_after text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'INVALID_DECISION'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if coalesce(v_record.recorded_overtime_minutes,0) <= 0 then raise exception 'NO_RECORDED_OVERTIME'; end if;
  v_raw_minutes := greatest(coalesce(v_record.raw_overtime_minutes,0),coalesce(v_record.recorded_overtime_minutes,0));
  v_comp_time_limit := case when v_raw_minutes < 60 then 0 else floor(v_raw_minutes / 30.0)::integer * 30 end;

  select * into v_request
  from public.correction_requests
  where employee_id = v_record.employee_id
    and target_date = v_record.work_date
    and request_type = 'overtime'
  order by requested_at desc
  limit 1
  for update;

  if p_decision = 'approved' then
    if p_approved_minutes not in (60,90,120,150,180,210,240)
       or p_approved_minutes > v_record.recorded_overtime_minutes then
      raise exception 'INVALID_OVERTIME_MINUTES';
    end if;
    if found and p_approved_minutes > v_request.calculated_minutes then raise exception 'OVERTIME_REQUEST_LIMIT'; end if;
    if p_comp_time_minutes < 0
       or (p_comp_time_minutes > 0 and (p_comp_time_minutes < 60 or p_comp_time_minutes % 30 <> 0))
       or p_comp_time_minutes > v_comp_time_limit then raise exception 'INVALID_EXTRA_COMP_TIME'; end if;
    v_week_start := date_trunc('week',v_record.work_date::timestamp)::date;
    select coalesce(sum(approved_overtime_minutes),0)::integer into v_week_total
    from public.attendance_records
    where employee_id = v_record.employee_id
      and id <> v_record.id
      and work_date between v_week_start and v_week_start + 6
      and overtime_status = 'approved'
      and deleted_at is null;
    if v_week_total + p_approved_minutes > 720 then raise exception 'WEEKLY_OVERTIME_LIMIT'; end if;

    update public.attendance_records
    set overtime_status = 'approved', approved_overtime_minutes = p_approved_minutes,
        comp_time_eligible_minutes = p_comp_time_minutes, changed = true, updated_at = now()
    where id = v_record.id;
    if p_comp_time_minutes > 0 then
      insert into public.comp_time_credits (attendance_record_id,employee_id,granted_minutes,remaining_minutes,expires_on,granted_by,reason)
      values (v_record.id,v_record.employee_id,p_comp_time_minutes,p_comp_time_minutes,v_record.work_date + 30,auth.uid(),trim(p_reason))
      on conflict (attendance_record_id) do update
      set granted_minutes = excluded.granted_minutes,
          remaining_minutes = greatest(0,excluded.granted_minutes - (public.comp_time_credits.granted_minutes - public.comp_time_credits.remaining_minutes)),
          expires_on = excluded.expires_on, granted_by = excluded.granted_by,
          granted_at = now(), reason = excluded.reason;
    else
      update public.comp_time_credits
      set remaining_minutes = 0,
          reason = trim(concat_ws(E'\n',reason,'관리자 재검토로 추가 대체휴무 적립 취소'))
      where attendance_record_id = v_record.id and remaining_minutes > 0;
    end if;
    v_after := jsonb_build_object('status','approved','minutes',p_approved_minutes,'comp_time_eligible_minutes',p_comp_time_minutes)::text;
  else
    update public.attendance_records
    set overtime_status = 'rejected', approved_overtime_minutes = 0,
        comp_time_eligible_minutes = 0, changed = true, updated_at = now()
    where id = v_record.id;
    update public.comp_time_credits
    set remaining_minutes = 0,
        reason = trim(concat_ws(E'\n',reason,'시간외근무 반려로 미사용 잔액 소멸'))
    where attendance_record_id = v_record.id and remaining_minutes > 0;
    v_after := jsonb_build_object('status','rejected','minutes',0)::text;
  end if;

  if v_request.id is not null then
    update public.correction_requests
    set status = p_decision,
        approved_minutes = case when p_decision = 'approved' then p_approved_minutes else 0 end,
        reviewer_id = auth.uid(), reviewer_comment = trim(p_reason), reviewed_at = now()
    where id = v_request.id;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role,
    correction_request_id
  ) values (
    v_record.id,v_record.employee_id,'overtime_review','approved_overtime_minutes',
    jsonb_build_object('status',v_record.overtime_status,'minutes',v_record.approved_overtime_minutes,'comp_time_eligible_minutes',v_record.comp_time_eligible_minutes)::text,
    v_after,trim(p_reason),auth.uid(),v_role,v_request.id
  );
end $$;

revoke all on function public.admin_create_attendance_records(uuid[],date,time,time,text) from public, anon;
grant execute on function public.admin_create_attendance_records(uuid[],date,time,time,text) to authenticated;
revoke all on function public.admin_create_attendance_exceptions(uuid[],date,date,text,text) from public, anon;
grant execute on function public.admin_create_attendance_exceptions(uuid[],date,date,text,text) to authenticated;
revoke all on function public.approved_leave_minutes_during_attendance(uuid,timestamptz,timestamptz) from public, anon;
grant execute on function public.approved_leave_minutes_during_attendance(uuid,timestamptz,timestamptz) to authenticated;
revoke all on function public.review_correction_request(uuid,text,text) from public, anon;
grant execute on function public.review_correction_request(uuid,text,text) to authenticated;
revoke all on function public.admin_review_overtime(uuid,text,integer,integer,text) from public, anon;
grant execute on function public.admin_review_overtime(uuid,text,integer,integer,text) to authenticated;

notify pgrst, 'reload schema';
commit;

select '다중 직원 등록, 외부교육, 실제 시간외근무, 중간 휴가 계산 보완 완료' as result;

-- ============================================================================
-- supabase/fix_admin_edit_after_reopen.sql
-- ============================================================================
begin;

-- 일부 기존 기관 데이터베이스에 빠진 시간외근무 인정단위 계산 함수를 함께 복구합니다.
create or replace function public.recognized_overtime_minutes(p_raw_minutes integer)
returns integer
language sql immutable
as $$
  select case
    when coalesce(p_raw_minutes,0) < 60 then 0
    else least(240,60 + floor((p_raw_minutes - 60) / 30.0)::integer * 30)
  end
$$;

create or replace function public.admin_update_attendance(
  p_record_id uuid,
  p_clock_in_time time,
  p_clock_out_time time,
  p_work_type text,
  p_attendance_status text,
  p_note text,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_before text;
  v_after text;
  v_clock_in timestamptz;
  v_clock_out timestamptz;
  v_month_closed boolean := false;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;

  select exists (
    select 1 from public.monthly_closings
    where year = extract(year from v_record.work_date)
      and month = extract(month from v_record.work_date)
      and status = 'closed'
  ) into v_month_closed;
  if v_month_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  -- 월 마감은 열렸지만 과거 기록의 개별 플래그만 남은 경우 자동으로 맞춥니다.
  if v_record.is_closed and not v_month_closed then
    update public.attendance_records set is_closed = false where id = v_record.id;
    v_record.is_closed := false;
  end if;

  -- 기존 근무유형이 현재 비활성 상태여도 시간 수정 자체는 허용합니다.
  if p_work_type is distinct from v_record.work_type
     and not exists (select 1 from public.work_type_settings where work_type = p_work_type and is_active) then
    raise exception 'INVALID_WORK_TYPE';
  end if;
  if p_attendance_status not in (
    'normal','late','early_leave','absent','missing_in','missing_out',
    'location_review','admin_review','field','business_trip','education','leave',
    'annual_leave','half_day','quarter_day','hourly_leave','sick_leave',
    'holiday_work','working'
  ) then raise exception 'INVALID_STATUS'; end if;

  v_clock_in := case when p_clock_in_time is null then null
    else (v_record.work_date::text || ' ' || p_clock_in_time::text)::timestamp at time zone 'Asia/Seoul' end;
  v_clock_out := case when p_clock_out_time is null then null
    else (v_record.work_date::text || ' ' || p_clock_out_time::text)::timestamp at time zone 'Asia/Seoul' end;
  if v_clock_out is not null and v_clock_in is null then raise exception 'CLOCK_IN_REQUIRED'; end if;
  if v_clock_out = v_clock_in then raise exception 'INVALID_TIME_RANGE'; end if;
  if v_clock_out is not null and v_clock_out < v_clock_in then
    v_clock_out := v_clock_out + interval '1 day';
  end if;

  v_before := jsonb_build_object(
    'clock_in_at',v_record.clock_in_at,'clock_out_at',v_record.clock_out_at,
    'work_type',v_record.work_type,'attendance_status',v_record.attendance_status,
    'note',v_record.note
  )::text;
  update public.attendance_records
  set clock_in_at = v_clock_in,
      clock_out_at = v_clock_out,
      work_type = p_work_type,
      attendance_status = p_attendance_status,
      note = coalesce(p_note,''),
      changed = true,
      updated_at = now()
  where id = p_record_id
  returning jsonb_build_object(
    'clock_in_at',clock_in_at,'clock_out_at',clock_out_at,
    'work_type',work_type,'attendance_status',attendance_status,'note',note
  )::text into v_after;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,
    before_value,after_value,reason,changed_by,changed_by_role
  ) values (
    v_record.id,v_record.employee_id,'admin_update','attendance_record',
    v_before,v_after,trim(p_reason),auth.uid(),v_role
  );
end $$;

revoke all on function public.admin_update_attendance(uuid,time,time,text,text,text,text) from public, anon;
grant execute on function public.admin_update_attendance(uuid,time,time,text,text,text,text) to authenticated;
revoke all on function public.recognized_overtime_minutes(integer) from public, anon;
grant execute on function public.recognized_overtime_minutes(integer) to authenticated;

notify pgrst, 'reload schema';
commit;

select '월 마감 해제 후 근태 수정 보완 완료' as result;


-- supabase/upgrade_leave_balances_and_special_leave.sql
-- 연차와 대체휴무 잔액, 특별휴가 보완
-- 기존 승인 이력은 보존하고 이후 승인부터 잔액 부족을 차단합니다.

begin;

alter table public.correction_requests drop constraint if exists correction_requests_request_type_check;
alter table public.correction_requests
  add constraint correction_requests_request_type_check
  check (request_type in (
    'clock_in_at','clock_out_at','annual_leave','comp_time','special_leave','sick_leave',
    'business_trip','overtime','other_leave','work_type','note','attendance_status'
  )) not valid;

alter table public.attendance_exceptions drop constraint if exists attendance_exceptions_exception_type_check;
alter table public.attendance_exceptions
  add constraint attendance_exceptions_exception_type_check
  check (exception_type in (
    'business_trip','external_training','approved_other','annual_leave','comp_time',
    'special_leave','sick_leave','other_leave'
  )) not valid;

create table if not exists public.annual_leave_entitlements (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.profiles(id) on delete restrict,
  valid_from date not null,
  valid_to date not null,
  base_minutes integer not null default 0 check (base_minutes >= 0 and base_minutes % 60 = 0),
  carryover_minutes integer not null default 0 check (carryover_minutes >= 0 and carryover_minutes % 60 = 0),
  adjustment_minutes integer not null default 0 check (adjustment_minutes % 60 = 0),
  reason text not null default '',
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id) on delete restrict,
  delete_reason text not null default '',
  check (valid_to >= valid_from),
  check (base_minutes + carryover_minutes + adjustment_minutes >= 0)
);

alter table public.annual_leave_entitlements add column if not exists deleted_at timestamptz;
alter table public.annual_leave_entitlements add column if not exists deleted_by uuid references public.profiles(id) on delete restrict;
alter table public.annual_leave_entitlements add column if not exists delete_reason text not null default '';

create index if not exists annual_leave_entitlements_employee_period_idx
  on public.annual_leave_entitlements (employee_id, valid_from, valid_to);

alter table public.comp_time_credits alter column attendance_record_id drop not null;
alter table public.comp_time_credits add column if not exists source_type text not null default 'overtime';
alter table public.comp_time_credits add column if not exists source_date date;
update public.comp_time_credits credit
set source_date = attendance.work_date
from public.attendance_records attendance
where attendance.id = credit.attendance_record_id and credit.source_date is null;
update public.comp_time_credits set source_date = granted_at::date where source_date is null;
alter table public.comp_time_credits alter column source_date set not null;

alter table public.comp_time_credits drop constraint if exists comp_time_credits_source_type_check;
alter table public.comp_time_credits
  add constraint comp_time_credits_source_type_check
  check (source_type in ('overtime','opening_balance','admin_adjustment')) not valid;

alter table public.annual_leave_entitlements enable row level security;
drop policy if exists "own or admin annual entitlements read" on public.annual_leave_entitlements;
create policy "own or admin annual entitlements read" on public.annual_leave_entitlements
for select to authenticated using (
  employee_id = auth.uid()
  or public.is_attendance_admin()
  or public.can_view_attendance_reports()
);
revoke insert, update, delete on public.annual_leave_entitlements from authenticated;

drop view if exists public.annual_leave_balances_view;
create view public.annual_leave_balances_view with (security_invoker = true) as
select
  entitlement.id as entitlement_id,
  entitlement.employee_id,
  profile.name as employee_name,
  entitlement.valid_from,
  entitlement.valid_to,
  entitlement.base_minutes,
  entitlement.carryover_minutes,
  entitlement.adjustment_minutes,
  (entitlement.base_minutes + entitlement.carryover_minutes + entitlement.adjustment_minutes)::integer as granted_minutes,
  coalesce(usage.used_minutes,0)::integer as used_minutes,
  coalesce(usage.scheduled_minutes,0)::integer as scheduled_minutes,
  greatest(0,
    entitlement.base_minutes + entitlement.carryover_minutes + entitlement.adjustment_minutes
    - coalesce(usage.used_minutes,0) - coalesce(usage.scheduled_minutes,0)
  )::integer as remaining_minutes,
  entitlement.reason,
  entitlement.created_at,
  entitlement.updated_at
from public.annual_leave_entitlements entitlement
join public.profiles profile on profile.id = entitlement.employee_id
left join lateral (
  select
    coalesce(sum(case when request.target_date < (now() at time zone 'Asia/Seoul')::date
      then coalesce(nullif(request.approved_minutes,0),request.calculated_minutes) else 0 end),0)::integer as used_minutes,
    coalesce(sum(case when request.target_date >= (now() at time zone 'Asia/Seoul')::date
      then coalesce(nullif(request.approved_minutes,0),request.calculated_minutes) else 0 end),0)::integer as scheduled_minutes
  from public.correction_requests request
  where request.employee_id = entitlement.employee_id
    and request.request_type = 'annual_leave'
    and request.status = 'approved'
    and request.target_date >= entitlement.valid_from
    and coalesce(request.end_date,request.target_date) <= entitlement.valid_to
) usage on true
where entitlement.deleted_at is null;

grant select on public.annual_leave_balances_view to authenticated;

drop view if exists public.comp_time_credit_details_view;
create view public.comp_time_credit_details_view with (security_invoker = true) as
select
  credit.id,
  credit.employee_id,
  profile.name as employee_name,
  credit.attendance_record_id,
  credit.source_type,
  credit.source_date,
  credit.granted_minutes,
  coalesce((select sum(allocation.used_minutes) from public.comp_time_usage_allocations allocation where allocation.credit_id = credit.id),0)::integer as used_minutes,
  credit.remaining_minutes,
  credit.expires_on,
  credit.reason,
  credit.granted_at,
  credit.granted_by,
  actor.name as granted_by_name
from public.comp_time_credits credit
join public.profiles profile on profile.id = credit.employee_id
left join public.profiles actor on actor.id = credit.granted_by;
grant select on public.comp_time_credit_details_view to authenticated;

drop view if exists public.comp_time_balances_view;
create view public.comp_time_balances_view with (security_invoker = true) as
select profile.id as employee_id,
  coalesce((select sum(credit.granted_minutes) from public.comp_time_credits credit where credit.employee_id = profile.id),0)::integer as total_granted_comp_time_minutes,
  coalesce((select sum(credit.granted_minutes) from public.comp_time_credits credit where credit.employee_id = profile.id),0)::integer as approved_overtime_minutes,
  coalesce((select sum(allocation.used_minutes) from public.comp_time_usage_allocations allocation join public.comp_time_credits credit on credit.id = allocation.credit_id where credit.employee_id = profile.id),0)::integer as used_comp_time_minutes,
  coalesce((select sum(credit.remaining_minutes) from public.comp_time_credits credit where credit.employee_id = profile.id and credit.expires_on >= (now() at time zone 'Asia/Seoul')::date),0)::integer as available_comp_time_minutes,
  coalesce((select sum(credit.remaining_minutes) from public.comp_time_credits credit where credit.employee_id = profile.id and credit.expires_on < (now() at time zone 'Asia/Seoul')::date),0)::integer as expired_comp_time_minutes,
  (select min(credit.expires_on) from public.comp_time_credits credit where credit.employee_id = profile.id and credit.remaining_minutes > 0 and credit.expires_on >= (now() at time zone 'Asia/Seoul')::date) as next_expiry_on,
  coalesce((select sum(credit.remaining_minutes) from public.comp_time_credits credit where credit.employee_id = profile.id and credit.remaining_minutes > 0 and credit.expires_on between (now() at time zone 'Asia/Seoul')::date and (now() at time zone 'Asia/Seoul')::date + 7),0)::integer as expiring_soon_minutes
from public.profiles profile
where profile.is_active and profile.role = 'employee';
grant select on public.comp_time_balances_view to authenticated;

drop view if exists public.monthly_overtime_after_comp_view;
create view public.monthly_overtime_after_comp_view with (security_invoker = true) as
with approved as (
  select record.employee_id,to_char(record.work_date,'YYYY-MM') as source_month,
    sum(record.approved_overtime_minutes)::integer as approved_overtime_minutes
  from public.attendance_records record
  where record.deleted_at is null and record.overtime_status = 'approved'
  group by record.employee_id,to_char(record.work_date,'YYYY-MM')
), used_from_source as (
  select credit.employee_id,to_char(credit.source_date,'YYYY-MM') as source_month,
    sum(allocation.used_minutes)::integer as comp_time_used_from_source_minutes
  from public.comp_time_usage_allocations allocation
  join public.comp_time_credits credit on credit.id = allocation.credit_id
  where credit.source_type = 'overtime'
  group by credit.employee_id,to_char(credit.source_date,'YYYY-MM')
)
select coalesce(approved.employee_id,used_from_source.employee_id) as employee_id,
  coalesce(approved.source_month,used_from_source.source_month) as source_month,
  coalesce(approved.approved_overtime_minutes,0)::integer as approved_overtime_minutes,
  coalesce(used_from_source.comp_time_used_from_source_minutes,0)::integer as comp_time_used_from_source_minutes,
  greatest(0,coalesce(approved.approved_overtime_minutes,0) - coalesce(used_from_source.comp_time_used_from_source_minutes,0))::integer as overtime_after_comp_minutes
from approved
full join used_from_source
  on used_from_source.employee_id = approved.employee_id
 and used_from_source.source_month = approved.source_month;
grant select on public.monthly_overtime_after_comp_view to authenticated;

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
  v_id uuid;
  v_before text := '';
  v_after text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_valid_to < p_valid_from then raise exception 'INVALID_DATE_RANGE'; end if;
  if coalesce(p_base_minutes,0) < 0 or coalesce(p_carryover_minutes,0) < 0
     or (coalesce(p_base_minutes,0) + coalesce(p_carryover_minutes,0) + coalesce(p_adjustment_minutes,0)) < 0
     or coalesce(p_base_minutes,0) % 60 <> 0 or coalesce(p_carryover_minutes,0) % 60 <> 0
     or coalesce(p_adjustment_minutes,0) % 60 <> 0 then raise exception 'INVALID_LEAVE_MINUTES'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  if not exists (select 1 from public.profiles where id = p_employee_id and role = 'employee') then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if exists (
    select 1 from public.annual_leave_entitlements
    where employee_id = p_employee_id
      and deleted_at is null
      and id <> coalesce(p_entitlement_id,'00000000-0000-0000-0000-000000000000'::uuid)
      and valid_from <= p_valid_to and valid_to >= p_valid_from
  ) then raise exception 'ANNUAL_LEAVE_PERIOD_OVERLAP'; end if;

  if p_entitlement_id is null then
    insert into public.annual_leave_entitlements (
      employee_id,valid_from,valid_to,base_minutes,carryover_minutes,
      adjustment_minutes,reason,created_by
    ) values (
      p_employee_id,p_valid_from,p_valid_to,p_base_minutes,p_carryover_minutes,
      p_adjustment_minutes,trim(p_reason),auth.uid()
    ) returning id into v_id;
  else
    select to_jsonb(entitlement)::text into v_before
    from public.annual_leave_entitlements entitlement
    where id = p_entitlement_id and deleted_at is null for update;
    if not found then raise exception 'ENTITLEMENT_NOT_FOUND'; end if;
    update public.annual_leave_entitlements
    set employee_id = p_employee_id,valid_from = p_valid_from, valid_to = p_valid_to,
        base_minutes = p_base_minutes, carryover_minutes = p_carryover_minutes,
        adjustment_minutes = p_adjustment_minutes, reason = trim(p_reason), updated_at = now()
    where id = p_entitlement_id returning id into v_id;
  end if;

  select to_jsonb(entitlement)::text into v_after
  from public.annual_leave_entitlements entitlement where id = v_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role
  ) values (
    p_employee_id,'annual_leave_entitlement_saved','annual_leave_balance',
    v_before,v_after,trim(p_reason),auth.uid(),v_role
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
  v_entitlement public.annual_leave_entitlements;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_entitlement
  from public.annual_leave_entitlements
  where id = p_entitlement_id and deleted_at is null
  for update;
  if not found then raise exception 'ENTITLEMENT_NOT_FOUND'; end if;
  update public.annual_leave_entitlements
  set deleted_at = now(),deleted_by = auth.uid(),delete_reason = trim(p_reason),updated_at = now()
  where id = p_entitlement_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role
  ) values (
    v_entitlement.employee_id,'annual_leave_entitlement_deleted','annual_leave_balance',
    to_jsonb(v_entitlement)::text,'삭제 처리',trim(p_reason),auth.uid(),v_role
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
  v_id uuid;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_minutes < 30 or p_minutes % 30 <> 0 then raise exception 'INVALID_COMP_TIME_MINUTES'; end if;
  if p_source_date is null or p_expires_on < p_source_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_source_type not in ('opening_balance','admin_adjustment') then raise exception 'INVALID_SOURCE_TYPE'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  insert into public.comp_time_credits (
    attendance_record_id,employee_id,granted_minutes,remaining_minutes,
    expires_on,granted_by,reason,source_type,source_date
  ) values (
    null,p_employee_id,p_minutes,p_minutes,p_expires_on,auth.uid(),trim(p_reason),p_source_type,p_source_date
  ) returning id into v_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role
  ) values (
    p_employee_id,'comp_time_credit_added','comp_time_balance','',
    jsonb_build_object('minutes',p_minutes,'source_date',p_source_date,'expires_on',p_expires_on,'source_type',p_source_type)::text,
    trim(p_reason),auth.uid(),v_role
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
  v_credit public.comp_time_credits;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_credit from public.comp_time_credits where id = p_credit_id for update;
  if not found then raise exception 'CREDIT_NOT_FOUND'; end if;
  if p_new_expires_on <= v_credit.expires_on then raise exception 'EXPIRY_MUST_EXTEND'; end if;
  update public.comp_time_credits set expires_on = p_new_expires_on where id = p_credit_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role
  ) values (
    v_credit.employee_id,'comp_time_expiry_extended','comp_time_expiry',
    v_credit.expires_on::text,p_new_expires_on::text,trim(p_reason),auth.uid(),v_role
  );
end $$;

create or replace function public.prepare_attendance_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.end_date := coalesce(new.end_date,new.target_date);
  if new.request_type in ('clock_in_at','clock_out_at') then
    new.end_date := new.target_date;
    new.calculated_minutes := 0;
  elsif new.request_type in ('annual_leave','comp_time','special_leave','sick_leave','business_trip','overtime','other_leave') then
    new.calculated_minutes := public.calculate_attendance_request_minutes(
      new.request_type,new.target_date,new.end_date,new.start_time,new.end_time
    );
    if new.calculated_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;
    new.requested_value := new.calculated_minutes::text;
  end if;
  if new.request_type in ('special_leave','other_leave')
     and char_length(trim(coalesce(new.request_subtype,''))) < 2 then
    raise exception 'LEAVE_NAME_REQUIRED';
  end if;
  return new;
end $$;

create or replace function public.approved_leave_minutes_during_attendance(
  p_employee_id uuid,
  p_clock_in timestamptz,
  p_clock_out timestamptz
) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(count(*),0)::integer
  from generate_series(
    date_trunc('minute',p_clock_in at time zone 'Asia/Seoul'),
    date_trunc('minute',p_clock_out at time zone 'Asia/Seoul') - interval '1 minute',
    interval '1 minute'
  ) minute_point
  where minute_point::time >= time '09:00'
    and minute_point::time < time '18:00'
    and not (minute_point::time >= time '12:00' and minute_point::time < time '13:00')
    and exists (
      select 1 from public.correction_requests request
      where request.employee_id = p_employee_id
        and request.status = 'approved'
        and request.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
        and minute_point::date between request.target_date and coalesce(request.end_date,request.target_date)
        and minute_point::time >= case when minute_point::date = request.target_date then coalesce(request.start_time,time '09:00') else time '09:00' end
        and minute_point::time < case when minute_point::date = coalesce(request.end_date,request.target_date) then coalesce(request.end_time,time '18:00') else time '18:00' end
    )
$$;

create or replace function public.validate_leave_balance_before_approval()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_needed integer := 0;
  v_available integer := 0;
  v_entitlement public.annual_leave_entitlements;
begin
  if new.status <> 'approved' or new.request_type not in ('annual_leave','comp_time') then return new; end if;
  v_needed := greatest(0,coalesce(nullif(new.approved_minutes,0),new.calculated_minutes));
  if v_needed <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;

  if new.request_type = 'annual_leave' then
    select * into v_entitlement
    from public.annual_leave_entitlements
    where employee_id = new.employee_id
      and deleted_at is null
      and valid_from <= new.target_date
      and valid_to >= coalesce(new.end_date,new.target_date)
    order by valid_to limit 1 for update;
    if not found then raise exception 'ANNUAL_LEAVE_ENTITLEMENT_REQUIRED'; end if;
    select (
      v_entitlement.base_minutes + v_entitlement.carryover_minutes + v_entitlement.adjustment_minutes
      - coalesce(sum(coalesce(nullif(request.approved_minutes,0),request.calculated_minutes)),0)
    )::integer into v_available
    from public.correction_requests request
    where request.employee_id = new.employee_id
      and request.request_type = 'annual_leave'
      and request.status = 'approved'
      and request.id <> new.id
      and request.target_date >= v_entitlement.valid_from
      and coalesce(request.end_date,request.target_date) <= v_entitlement.valid_to;
    if v_available < v_needed then raise exception 'ANNUAL_LEAVE_BALANCE_INSUFFICIENT:%',v_available; end if;
  else
    select coalesce(sum(credit.remaining_minutes),0)::integer into v_available
    from public.comp_time_credits credit
    where credit.employee_id = new.employee_id
      and credit.remaining_minutes > 0
      and credit.source_date < new.target_date
      and credit.expires_on >= new.target_date;
    if v_available < v_needed then raise exception 'COMP_TIME_BALANCE_INSUFFICIENT:%',v_available; end if;
  end if;
  return new;
end $$;

drop trigger if exists validate_leave_balance_before_approval_trigger on public.correction_requests;
create trigger validate_leave_balance_before_approval_trigger
before insert or update of status,request_type,target_date,end_date,calculated_minutes,approved_minutes
on public.correction_requests
for each row execute function public.validate_leave_balance_before_approval();

create or replace function public.allocate_comp_time_usage_without_negative()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_allocation record;
  v_credit record;
  v_needed integer := 0;
  v_use integer := 0;
begin
  for v_allocation in select credit_id,used_minutes from public.comp_time_usage_allocations where correction_request_id = new.id loop
    update public.comp_time_credits
    set remaining_minutes = least(granted_minutes,remaining_minutes + v_allocation.used_minutes)
    where id = v_allocation.credit_id;
  end loop;
  delete from public.comp_time_usage_allocations where correction_request_id = new.id;
  if new.status <> 'approved' or new.request_type <> 'comp_time' then return new; end if;
  v_needed := greatest(0,coalesce(nullif(new.approved_minutes,0),new.calculated_minutes));
  for v_credit in
    select credit.* from public.comp_time_credits credit
    where credit.employee_id = new.employee_id
      and credit.remaining_minutes > 0
      and credit.source_date < new.target_date
      and credit.expires_on >= new.target_date
    order by credit.expires_on,credit.source_date,credit.granted_at
    for update
  loop
    exit when v_needed <= 0;
    v_use := least(v_needed,v_credit.remaining_minutes);
    update public.comp_time_credits set remaining_minutes = remaining_minutes - v_use where id = v_credit.id;
    insert into public.comp_time_usage_allocations (correction_request_id,credit_id,used_minutes)
    values (new.id,v_credit.id,v_use);
    v_needed := v_needed - v_use;
  end loop;
  if v_needed > 0 then raise exception 'COMP_TIME_BALANCE_INSUFFICIENT:%',v_needed; end if;
  return new;
end $$;

drop trigger if exists allocate_comp_time_usage_without_negative_trigger on public.correction_requests;
create trigger allocate_comp_time_usage_without_negative_trigger
after insert or update of status,request_type,approved_minutes,calculated_minutes,requested_value
on public.correction_requests
for each row execute function public.allocate_comp_time_usage_without_negative();

-- 이전 설치 순서 때문에 승인됐지만 적립원장과 연결되지 않은 대체휴무를 가능한 범위에서 다시 연결합니다.
do $$
declare
  v_request record;
begin
  for v_request in
    select request.id
    from public.correction_requests request
    where request.request_type = 'comp_time'
      and request.status = 'approved'
      and not exists (
        select 1 from public.comp_time_usage_allocations allocation
        where allocation.correction_request_id = request.id
      )
    order by request.target_date,request.requested_at
  loop
    begin
      update public.correction_requests
      set approved_minutes = approved_minutes
      where id = v_request.id;
    exception when others then
      null;
    end;
  end loop;
end $$;

create or replace function public.sync_approved_request_to_attendance_exception()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_default_start time := time '09:00';
  v_default_end time := time '18:00';
  v_end_date date := coalesce(new.end_date,new.target_date);
  v_exception_type text;
  v_should_create boolean := false;
begin
  select coalesce(settings.default_start_time,time '09:00'),
         coalesce(settings.default_end_time,time '18:00')
  into v_default_start,v_default_end
  from public.organization_settings settings
  where settings.org_id = new.org_id;
  v_default_start := coalesce(v_default_start,time '09:00');
  v_default_end := coalesce(v_default_end,time '18:00');
  if coalesce(new.before_value,'') = '관리자 직접 등록' then return new; end if;
  if new.status = 'approved' then
    if new.request_type = 'business_trip' then v_exception_type := 'business_trip'; v_should_create := true;
    elsif new.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
      and coalesce(new.start_time,v_default_start) <= v_default_start
      and coalesce(new.end_time,v_default_end) >= v_default_end then
      v_exception_type := new.request_type; v_should_create := true;
    end if;
  end if;
  if v_should_create then
    if not exists (select 1 from public.attendance_exceptions where correction_request_id = new.id and cancelled_at is null)
       and not exists (select 1 from public.attendance_exceptions where employee_id = new.employee_id and cancelled_at is null and start_date <= v_end_date and end_date >= new.target_date) then
      insert into public.attendance_exceptions (
        employee_id,start_date,end_date,exception_type,reason,approved_by,approved_at,correction_request_id
      ) values (
        new.employee_id,new.target_date,v_end_date,v_exception_type,
        case when new.request_type in ('special_leave','other_leave') then trim(new.request_subtype) || ': ' || trim(new.reason) else trim(new.reason) end,
        coalesce(new.reviewer_id,auth.uid()),coalesce(new.reviewed_at,now()),new.id
      );
    end if;
  else
    update public.attendance_exceptions
    set cancelled_at = coalesce(cancelled_at,now()),cancelled_by = coalesce(cancelled_by,auth.uid()),
        cancellation_reason = case when cancellation_reason = '' then '연결된 신청의 승인 상태 변경' else cancellation_reason end
    where correction_request_id = new.id and cancelled_at is null;
  end if;
  return new;
end $$;

create or replace function public.recalculate_attendance_after_leave_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.request_type not in ('annual_leave','comp_time','special_leave','sick_leave','other_leave') then return new; end if;
  if tg_op = 'UPDATE' and old.status is not distinct from new.status
     and old.target_date is not distinct from new.target_date
     and old.end_date is not distinct from new.end_date
     and old.start_time is not distinct from new.start_time
     and old.end_time is not distinct from new.end_time then return new; end if;
  update public.comp_time_credits credit
  set remaining_minutes = 0,reason = trim(concat_ws(E'\n',credit.reason,'휴가 반영으로 실제 근무시간 재검토'))
  where credit.attendance_record_id in (
    select record.id from public.attendance_records record
    where record.employee_id = new.employee_id
      and record.work_date between new.target_date and coalesce(new.end_date,new.target_date)
      and record.deleted_at is null
  ) and credit.remaining_minutes > 0;
  update public.attendance_records record
  set overtime_status = 'pending',approved_overtime_minutes = 0,comp_time_eligible_minutes = 0,
      clock_out_at = record.clock_out_at,changed = true,updated_at = now()
  where record.employee_id = new.employee_id
    and record.work_date between new.target_date and coalesce(new.end_date,new.target_date)
    and record.deleted_at is null and record.clock_in_at is not null and record.clock_out_at is not null;
  return new;
end $$;

-- 외부교육은 예외 메모가 아니라 날짜별 09:00부터 18:00까지의 근무기록으로 만듭니다.
-- 같은 날짜에 이미 근태기록이 있으면 기존 기록을 덮어쓰지 않고 건너뜁니다.
create or replace function public.admin_create_attendance_exceptions(
  p_employee_ids uuid[],
  p_start_date date,
  p_end_date date,
  p_exception_type text,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_employee_id uuid;
  v_employee_name text;
  v_work_date date;
  v_record_id uuid;
  v_created integer := 0;
  v_skipped_names text[] := array[]::text[];
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if coalesce(array_length(p_employee_ids,1),0) = 0 then raise exception 'EMPLOYEE_REQUIRED'; end if;
  if p_end_date < p_start_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_exception_type not in ('business_trip','external_training','approved_other','annual_leave','comp_time','special_leave','sick_leave','other_leave') then raise exception 'INVALID_EXCEPTION_TYPE'; end if;
  if p_exception_type in ('external_training','special_leave','other_leave') and char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;

  foreach v_employee_id in array p_employee_ids loop
    select name into v_employee_name from public.profiles
    where id = v_employee_id and role = 'employee' and is_active = true;
    if not found then
      v_skipped_names := array_append(v_skipped_names,'비활성 또는 미확인 직원');
      continue;
    end if;

    if p_exception_type = 'external_training' then
      for v_work_date in select generate_series(p_start_date,p_end_date,interval '1 day')::date loop
        if exists (select 1 from public.attendance_records where employee_id = v_employee_id and work_date = v_work_date and deleted_at is null) then
          v_skipped_names := array_append(v_skipped_names,v_employee_name || ' ' || v_work_date::text);
          continue;
        end if;
        insert into public.attendance_records (
          employee_id,work_date,work_type,clock_in_at,clock_out_at,
          clock_in_location_status,clock_out_location_status,attendance_status,note,changed
        ) values (
          v_employee_id,v_work_date,'education',
          (v_work_date + time '09:00') at time zone 'Asia/Seoul',
          (v_work_date + time '18:00') at time zone 'Asia/Seoul',
          'not_checked','not_checked','normal','',true
        )
        on conflict (employee_id,work_date) do update
        set work_type = 'education',
            clock_in_at = excluded.clock_in_at,
            clock_out_at = excluded.clock_out_at,
            clock_in_location_status = 'not_checked',
            clock_out_location_status = 'not_checked',
            attendance_status = 'normal',
            note = '',
            changed = true,
            deleted_at = null,
            updated_at = now()
        where attendance_records.deleted_at is not null
        returning id into v_record_id;
        if v_record_id is null then
          v_skipped_names := array_append(v_skipped_names,v_employee_name || ' ' || v_work_date::text);
          continue;
        end if;
        insert into public.attendance_audit_logs (
          attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
          reason,changed_by,changed_by_role
        ) values (
          v_record_id,v_employee_id,'external_training_record_create','attendance_record','',
          jsonb_build_object('work_date',v_work_date,'clock_in_time','09:00','clock_out_time','18:00')::text,
          trim(coalesce(p_reason,'')),auth.uid(),v_role
        );
        v_created := v_created + 1;
      end loop;
    elsif exists (
      select 1 from public.attendance_exceptions
      where employee_id = v_employee_id and cancelled_at is null
        and start_date <= p_end_date and end_date >= p_start_date
    ) then
      v_skipped_names := array_append(v_skipped_names,v_employee_name);
    else
      perform public.admin_create_attendance_exception(v_employee_id,p_start_date,p_end_date,p_exception_type,p_reason);
      v_created := v_created + 1;
    end if;
  end loop;
  return jsonb_build_object(
    'created_count',v_created,
    'skipped_count',coalesce(array_length(v_skipped_names,1),0),
    'skipped_names',to_jsonb(v_skipped_names)
  );
end $$;

-- 관리자 확인 화면에서 특별휴가도 기존 근태기록에 직접 반영할 수 있게 합니다.
create or replace function public.admin_apply_leave_to_attendance_record(
  p_record_id uuid,
  p_request_type text,
  p_start_time time,
  p_end_time time,
  p_request_subtype text,
  p_comment text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_request_id uuid;
  v_minutes integer;
  v_leave_type text := 'none';
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_request_type not in ('annual_leave','comp_time','special_leave','sick_leave','other_leave') then raise exception 'INVALID_LEAVE_TYPE'; end if;
  if char_length(trim(coalesce(p_comment,''))) < 5 then raise exception 'COMMENT_REQUIRED'; end if;
  if p_start_time is null or p_end_time is null or p_end_time <= p_start_time then raise exception 'INVALID_TIME_RANGE'; end if;
  if p_request_type in ('special_leave','other_leave') and char_length(trim(coalesce(p_request_subtype,''))) < 2 then raise exception 'LEAVE_NAME_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_record.work_date) and month = extract(month from v_record.work_date) and status = 'closed') and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  v_minutes := public.calculate_attendance_request_minutes(p_request_type,v_record.work_date,v_record.work_date,p_start_time,p_end_time);
  if v_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;
  insert into public.correction_requests (
    attendance_record_id,employee_id,target_date,end_date,start_time,end_time,calculated_minutes,approved_minutes,
    request_type,request_subtype,before_value,requested_value,reason,status,reviewer_id,reviewer_comment,reviewed_at
  ) values (
    v_record.id,v_record.employee_id,v_record.work_date,v_record.work_date,p_start_time,p_end_time,v_minutes,v_minutes,
    p_request_type,case when p_request_type in ('special_leave','other_leave') then trim(coalesce(p_request_subtype,'')) else '' end,
    v_record.attendance_status,v_minutes::text,trim(p_comment),'approved',auth.uid(),trim(p_comment),now()
  ) returning id into v_request_id;
  if p_request_type = 'annual_leave' then
    v_leave_type := case v_minutes when 480 then 'annual_leave' when 240 then 'half_day' when 120 then 'quarter_day' when 60 then 'hourly_leave' else 'none' end;
  elsif p_request_type = 'sick_leave' then v_leave_type := 'sick_leave';
  end if;
  update public.attendance_records set attendance_status = case when clock_out_at is null then 'working' else 'normal' end,leave_type = v_leave_type,changed = true,updated_at = now() where id = v_record.id;
  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,reason,changed_by,changed_by_role,correction_request_id
  ) values (
    v_record.id,v_record.employee_id,'admin_leave_applied','leave_request',v_record.attendance_status,
    jsonb_build_object('request_type',p_request_type,'start_time',p_start_time,'end_time',p_end_time,'minutes',v_minutes,'subtype',trim(coalesce(p_request_subtype,'')))::text,
    trim(p_comment),auth.uid(),v_role,v_request_id
  );
  return v_request_id;
end $$;

-- 기존 외부교육 예외 일정도 같은 기준으로 전환합니다.
insert into public.attendance_records (
  employee_id,work_date,work_type,clock_in_at,clock_out_at,
  clock_in_location_status,clock_out_location_status,attendance_status,note,changed
)
select distinct on (exception.employee_id,day_value::date)
  exception.employee_id,day_value::date,'education',
  (day_value::date + time '09:00') at time zone 'Asia/Seoul',
  (day_value::date + time '18:00') at time zone 'Asia/Seoul',
  'not_checked','not_checked','normal','',true
from public.attendance_exceptions exception
cross join lateral generate_series(exception.start_date,exception.end_date,interval '1 day') day_value
where exception.exception_type = 'external_training'
  and exception.cancelled_at is null
order by exception.employee_id,day_value::date,exception.approved_at desc
on conflict (employee_id,work_date) do update
set work_type = 'education',
    clock_in_at = excluded.clock_in_at,
    clock_out_at = excluded.clock_out_at,
    clock_in_location_status = 'not_checked',
    clock_out_location_status = 'not_checked',
    attendance_status = 'normal',
    note = '',
    changed = true,
    deleted_at = null,
    updated_at = now()
where attendance_records.deleted_at is not null;

update public.attendance_exceptions
set cancelled_at = now(),cancelled_by = coalesce(cancelled_by,approved_by),
    cancellation_reason = case when cancellation_reason = '' then '외부교육을 09:00부터 18:00까지의 근무기록으로 전환' else cancellation_reason end
where exception_type = 'external_training' and cancelled_at is null;

revoke all on function public.admin_save_annual_leave_entitlement(uuid,uuid,date,date,integer,integer,integer,text) from public,anon;
grant execute on function public.admin_save_annual_leave_entitlement(uuid,uuid,date,date,integer,integer,integer,text) to authenticated;
revoke all on function public.admin_delete_annual_leave_entitlement(uuid,text) from public,anon;
grant execute on function public.admin_delete_annual_leave_entitlement(uuid,text) to authenticated;
revoke all on function public.admin_add_comp_time_credit(uuid,integer,date,date,text,text) from public,anon;
grant execute on function public.admin_add_comp_time_credit(uuid,integer,date,date,text,text) to authenticated;
revoke all on function public.admin_extend_comp_time_credit(uuid,date,text) from public,anon;
grant execute on function public.admin_extend_comp_time_credit(uuid,date,text) to authenticated;
revoke all on function public.admin_create_attendance_exceptions(uuid[],date,date,text,text) from public,anon;
grant execute on function public.admin_create_attendance_exceptions(uuid[],date,date,text,text) to authenticated;
revoke all on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) from public,anon;
grant execute on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) to authenticated;

notify pgrst, 'reload schema';
commit;

select '연차와 대체휴무 잔액, 특별휴가 보완 완료' as result;

-- supabase/fix_comp_time_recognition_rule.sql round-up refresh
-- 대체휴무 적립 기준 보완
-- 시간외근무 승인시간과 별도로 실제 추가근무 전체를 대체휴무로 인정할 수 있습니다.
-- 최초 1시간부터 인정하고 이후에는 30분 단위로 적립합니다.

begin;

-- 실제 유급 근무가 8시간을 넘은 분량을 계산합니다.
-- 최초 1시간은 모두 채워야 하고, 그 이후에는 30분 구간을 1분이라도 넘으면 다음 30분까지 인정합니다.
create or replace function public.recognized_overtime_minutes(p_raw_minutes integer)
returns integer
language sql immutable
as $$
  select case
    when coalesce(p_raw_minutes,0) < 60 then 0
    else least(240,60 + ceil((p_raw_minutes - 60) / 30.0)::integer * 30)
  end
$$;

alter table public.comp_time_credits
  drop constraint if exists comp_time_credits_granted_minutes_check;
alter table public.comp_time_credits
  drop constraint if exists comp_time_credits_remaining_minutes_check;
alter table public.comp_time_credits
  add constraint comp_time_credits_granted_minutes_check
    check (granted_minutes >= 0),
  add constraint comp_time_credits_remaining_minutes_check
    check (remaining_minutes >= 0 and remaining_minutes <= granted_minutes);

create or replace function public.admin_review_overtime(
  p_record_id uuid,
  p_decision text,
  p_approved_minutes integer,
  p_comp_time_minutes integer,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_request public.correction_requests;
  v_has_request boolean := false;
  v_role text := public.current_profile_role();
  v_week_start date;
  v_week_total integer := 0;
  v_raw_minutes integer := 0;
  v_comp_time_limit integer := 0;
  v_after text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'INVALID_DECISION'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if coalesce(v_record.recorded_overtime_minutes,0) <= 0 then raise exception 'NO_RECORDED_OVERTIME'; end if;

  v_raw_minutes := greatest(
    coalesce(v_record.raw_overtime_minutes,0),
    coalesce(v_record.recorded_overtime_minutes,0)
  );
  v_comp_time_limit := case
    when v_raw_minutes < 60 then 0
    else 60 + ceil((v_raw_minutes - 60) / 30.0)::integer * 30
  end;

  select * into v_request
  from public.correction_requests
  where employee_id = v_record.employee_id
    and target_date = v_record.work_date
    and request_type = 'overtime'
  order by requested_at desc
  limit 1
  for update;
  v_has_request := found;

  if p_decision = 'approved' then
    if p_approved_minutes not in (60,90,120,150,180,210,240)
       or p_approved_minutes > v_record.recorded_overtime_minutes then
      raise exception 'INVALID_OVERTIME_MINUTES';
    end if;
    if v_has_request and p_approved_minutes > v_request.calculated_minutes then
      raise exception 'OVERTIME_REQUEST_LIMIT';
    end if;

    if p_comp_time_minutes < 0
       or (p_comp_time_minutes > 0 and (p_comp_time_minutes < 60 or p_comp_time_minutes % 30 <> 0))
       or p_comp_time_minutes > v_comp_time_limit then
      raise exception 'INVALID_EXTRA_COMP_TIME';
    end if;

    v_week_start := date_trunc('week',v_record.work_date::timestamp)::date;
    select coalesce(sum(approved_overtime_minutes),0)::integer into v_week_total
    from public.attendance_records
    where employee_id = v_record.employee_id
      and id <> v_record.id
      and work_date between v_week_start and v_week_start + 6
      and overtime_status = 'approved'
      and deleted_at is null;
    if v_week_total + p_approved_minutes > 720 then raise exception 'WEEKLY_OVERTIME_LIMIT'; end if;

    update public.attendance_records
    set overtime_status = 'approved',
        approved_overtime_minutes = p_approved_minutes,
        comp_time_eligible_minutes = p_comp_time_minutes,
        changed = true,
        updated_at = now()
    where id = v_record.id;

    if p_comp_time_minutes > 0 then
      insert into public.comp_time_credits (
        attendance_record_id,employee_id,granted_minutes,remaining_minutes,
        expires_on,granted_by,reason
      ) values (
        v_record.id,v_record.employee_id,p_comp_time_minutes,p_comp_time_minutes,
        v_record.work_date + 30,auth.uid(),trim(p_reason)
      )
      on conflict (attendance_record_id) do update
      set granted_minutes = excluded.granted_minutes,
          remaining_minutes = greatest(
            0,
            excluded.granted_minutes
              - (public.comp_time_credits.granted_minutes - public.comp_time_credits.remaining_minutes)
          ),
          expires_on = excluded.expires_on,
          granted_by = excluded.granted_by,
          granted_at = now(),
          reason = excluded.reason;
    else
      update public.comp_time_credits
      set remaining_minutes = 0,
          reason = trim(concat_ws(E'\n',reason,'관리자 재검토로 대체휴무 적립 취소'))
      where attendance_record_id = v_record.id and remaining_minutes > 0;
    end if;

    v_after := jsonb_build_object(
      'status','approved',
      'minutes',p_approved_minutes,
      'comp_time_eligible_minutes',p_comp_time_minutes
    )::text;
  else
    update public.attendance_records
    set overtime_status = 'rejected',
        approved_overtime_minutes = 0,
        comp_time_eligible_minutes = 0,
        changed = true,
        updated_at = now()
    where id = v_record.id;
    update public.comp_time_credits
    set remaining_minutes = 0,
        reason = trim(concat_ws(E'\n',reason,'시간외근무 반려로 미사용 잔액 소멸'))
    where attendance_record_id = v_record.id and remaining_minutes > 0;
    v_after := jsonb_build_object('status','rejected','minutes',0)::text;
  end if;

  if v_has_request then
    update public.correction_requests
    set status = p_decision,
        approved_minutes = case when p_decision = 'approved' then p_approved_minutes else 0 end,
        reviewer_id = auth.uid(),
        reviewer_comment = trim(p_reason),
        reviewed_at = now()
    where id = v_request.id;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,
    before_value,after_value,reason,changed_by,changed_by_role,
    correction_request_id
  ) values (
    v_record.id,v_record.employee_id,'overtime_review','approved_overtime_minutes',
    jsonb_build_object(
      'status',v_record.overtime_status,
      'minutes',v_record.approved_overtime_minutes,
      'comp_time_eligible_minutes',v_record.comp_time_eligible_minutes
    )::text,
    v_after,trim(p_reason),auth.uid(),v_role,
    case when v_has_request then v_request.id else null end
  );
end $$;

-- 저장된 출퇴근기록도 새 인정단위로 다시 계산합니다.
update public.attendance_records
set clock_out_at = clock_out_at
where deleted_at is null and clock_in_at is not null and clock_out_at is not null;

revoke all on function public.recognized_overtime_minutes(integer) from public, anon;
grant execute on function public.recognized_overtime_minutes(integer) to authenticated;

revoke all on function public.admin_review_overtime(uuid,text,integer,integer,text) from public, anon;
grant execute on function public.admin_review_overtime(uuid,text,integer,integer,text) to authenticated;

notify pgrst, 'reload schema';
commit;

select '대체휴무 적립 기준 보완 완료' as result;

begin;
create or replace function public.clock_attendance_server_api(
  p_payload jsonb
) returns uuid
language sql
security definer
set search_path = public
as $$
  select public.clock_attendance_server(
    (p_payload ->> 'p_employee_id')::uuid,
    p_payload ->> 'p_action',
    (p_payload ->> 'p_latitude')::double precision,
    (p_payload ->> 'p_longitude')::double precision,
    (p_payload ->> 'p_accuracy')::numeric,
    p_payload ->> 'p_location_status',
    p_payload ->> 'p_ip_address',
    p_payload ->> 'p_note',
    (p_payload ->> 'p_idempotency_key')::uuid
  )
$$;
alter function public.clock_attendance_server_api(jsonb) owner to postgres;
revoke all on function public.clock_attendance_server_api(jsonb) from public, anon, authenticated;
grant execute on function public.clock_attendance_server_api(jsonb) to service_role;
notify pgrst, 'reload schema';
commit;

select '출퇴근 서버 API 연결 보완 완료' as result;

begin;

-- 관리자가 출근 또는 퇴근시각을 비우면 해당 버튼을 다시 누를 수 있어야 합니다.
-- 실제 시각만 비우고 중복 방지 이벤트를 남겨 두면 재기록이 거부되므로 함께 정리합니다.
create or replace function public.cleanup_attendance_events_after_time_clear()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.clock_in_at is not null and new.clock_in_at is null then
    delete from public.attendance_events
    where employee_id = new.employee_id
      and work_date = new.work_date
      and action_type in ('clock_in','clock_out');
  elsif old.clock_out_at is not null and new.clock_out_at is null then
    delete from public.attendance_events
    where employee_id = new.employee_id
      and work_date = new.work_date
      and action_type = 'clock_out';
  end if;
  return new;
end
$$;

alter function public.cleanup_attendance_events_after_time_clear() owner to postgres;
revoke all on function public.cleanup_attendance_events_after_time_clear() from public, anon, authenticated;

drop trigger if exists attendance_cleanup_events_after_time_clear on public.attendance_records;
create trigger attendance_cleanup_events_after_time_clear
after update of clock_in_at, clock_out_at on public.attendance_records
for each row
when (old.clock_in_at is distinct from new.clock_in_at or old.clock_out_at is distinct from new.clock_out_at)
execute function public.cleanup_attendance_events_after_time_clear();

notify pgrst, 'reload schema';
commit;

select '출퇴근시각 삭제 후 재기록 보완 완료' as result;

-- ============================================================================
-- 기관별 긴급지원 기능과 보호 설정 승인 전용 보안
-- ============================================================================
begin;

alter table public.organization_settings add column if not exists emergency_support_enabled boolean not null default true;

create or replace function public.enforce_emergency_support_feature_toggle()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_enabled boolean;
begin
  if new.request_type <> 'emergency_support' then return new; end if;
  select coalesce(settings.emergency_support_enabled,true) into v_enabled
  from public.profiles profile
  left join public.organization_settings settings on settings.org_id = profile.org_id
  where profile.id = new.employee_id;
  if coalesce(v_enabled,true) = false then raise exception 'EMERGENCY_SUPPORT_DISABLED'; end if;
  return new;
end $$;

drop trigger if exists enforce_emergency_support_feature_toggle on public.correction_requests;
create trigger enforce_emergency_support_feature_toggle before insert on public.correction_requests
for each row execute function public.enforce_emergency_support_feature_toggle();

create or replace function public.save_organization_settings(
  p_default_start_time time, p_default_end_time time, p_break_minutes integer,
  p_late_grace_minutes integer, p_early_leave_grace_minutes integer,
  p_office_ip_address text, p_emergency_support_enabled boolean
) returns public.organization_settings
language plpgsql security definer set search_path = public as $$
declare
  v_org_id uuid := public.current_profile_org_id();
  v_role text := public.current_profile_role();
  v_existing_ip text;
  v_settings public.organization_settings;
begin
  if v_org_id is null or v_role not in ('admin','org_admin') then raise exception 'ORG_ADMIN_REQUIRED'; end if;
  select office_ip_address into v_existing_ip from public.organization_settings where org_id = v_org_id;
  if trim(coalesce(p_office_ip_address,'')) <> trim(coalesce(v_existing_ip,'')) then raise exception 'IP_CHANGE_APPROVAL_REQUIRED'; end if;
  insert into public.organization_settings (
    id,org_id,default_start_time,default_end_time,break_minutes,late_grace_minutes,
    early_leave_grace_minutes,office_ip_address,emergency_support_enabled,updated_by
  ) values (
    true,v_org_id,p_default_start_time,p_default_end_time,p_break_minutes,p_late_grace_minutes,
    p_early_leave_grace_minutes,coalesce(v_existing_ip,''),coalesce(p_emergency_support_enabled,true),auth.uid()
  ) on conflict (org_id) do update set
    default_start_time=excluded.default_start_time,default_end_time=excluded.default_end_time,
    break_minutes=excluded.break_minutes,late_grace_minutes=excluded.late_grace_minutes,
    early_leave_grace_minutes=excluded.early_leave_grace_minutes,
    emergency_support_enabled=excluded.emergency_support_enabled,updated_by=auth.uid(),updated_at=now()
  returning * into v_settings;
  return v_settings;
end $$;

revoke all on function public.save_organization_settings(time,time,integer,integer,integer,text,boolean) from public,anon;
grant execute on function public.save_organization_settings(time,time,integer,integer,integer,text,boolean) to authenticated;

drop policy if exists "organization admins manage workplaces" on public.workplaces;
drop policy if exists "super admin manages workplaces" on public.workplaces;
create policy "super admin manages workplaces" on public.workplaces for all to authenticated
using (public.is_super_admin()) with check (public.is_super_admin());
drop policy if exists "organization admins manage settings" on public.organization_settings;
drop policy if exists "super admin manages organization settings" on public.organization_settings;
create policy "super admin manages organization settings" on public.organization_settings for all to authenticated
using (public.is_super_admin()) with check (public.is_super_admin());
revoke insert,update,delete on public.workplaces from authenticated;
revoke insert,update,delete on public.organization_settings from authenticated;
revoke all on function public.save_workplace_settings(text,double precision,double precision,integer,integer) from public,anon,authenticated;

notify pgrst, 'reload schema';
commit;

-- ============================================================================
-- 긴급지원 등록과 출퇴근시각 삭제 최종 보완
-- ============================================================================
begin;

-- 보완 SQL이 나중에 실행되어도 긴급지원 유형이 다시 제외되지 않게 합니다.
do $$
declare v_constraint record;
begin
  for v_constraint in
    select conname from pg_constraint
    where conrelid = 'public.correction_requests'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%request_type%'
  loop
    execute format('alter table public.correction_requests drop constraint %I', v_constraint.conname);
  end loop;
end $$;

alter table public.correction_requests
  add constraint correction_requests_request_type_check
  check (request_type in (
    'clock_in_at','clock_out_at','annual_leave','comp_time','sick_leave','special_leave',
    'business_trip','overtime','emergency_support','other_leave','work_type','note','attendance_status'
  )) not valid;

create or replace function public.calculate_emergency_support_minutes(
  p_start_date date, p_end_date date, p_start_time time, p_end_time time
) returns integer
language plpgsql immutable security definer set search_path = public as $$
declare v_minutes integer;
begin
  if p_start_date is null or p_end_date is null or p_start_time is null or p_end_time is null then
    raise exception 'TIME_REQUIRED';
  end if;
  v_minutes := floor(extract(epoch from ((p_end_date + p_end_time) - (p_start_date + p_start_time))) / 60)::integer;
  if v_minutes <= 0 or v_minutes > 1440 then raise exception 'INVALID_EMERGENCY_SUPPORT_RANGE'; end if;
  return v_minutes;
end $$;

create or replace function public.emergency_support_time_overlaps(
  p_employee_id uuid, p_start_date date, p_end_date date,
  p_start_time time, p_end_time time, p_exclude_request_id uuid default null
) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.correction_requests request
    where request.employee_id = p_employee_id
      and request.request_type = 'emergency_support'
      and request.status not in ('rejected','cancelled')
      and request.end_date is not null and request.end_time is not null
      and request.id is distinct from p_exclude_request_id
      and (request.target_date + request.start_time) < (p_end_date + p_end_time)
      and (p_start_date + p_start_time) < (request.end_date + request.end_time)
  );
$$;

create or replace function public.admin_create_emergency_support_work(
  p_employee_id uuid, p_start_date date, p_end_date date,
  p_start_time time, p_end_time time, p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_employee_org_id uuid;
  v_minutes integer;
  v_request_id uuid;
  v_record_id uuid;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select org_id into v_employee_org_id from public.profiles
  where id = p_employee_id and role in ('employee','team_lead') and is_active = true;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_employee_org_id is distinct from v_org_id then
    raise exception 'ORGANIZATION_ACCESS_DENIED';
  end if;
  if exists (
    select 1 from public.monthly_closings
    where org_id = v_employee_org_id
      and year = extract(year from p_start_date)
      and month = extract(month from p_start_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  v_minutes := public.calculate_emergency_support_minutes(p_start_date,p_end_date,p_start_time,p_end_time);
  if public.emergency_support_time_overlaps(p_employee_id,p_start_date,p_end_date,p_start_time,p_end_time,null) then
    raise exception 'EMERGENCY_SUPPORT_TIME_OVERLAP';
  end if;

  -- 일반 출퇴근과 긴급지원은 별개이며, 같은 날짜 기록은 변경이력 연결에만 사용합니다.
  select id into v_record_id from public.attendance_records
  where employee_id = p_employee_id and org_id = v_employee_org_id
    and work_date = p_start_date and deleted_at is null
  order by created_at desc limit 1;

  insert into public.correction_requests (
    attendance_record_id,employee_id,target_date,end_date,start_time,end_time,
    request_type,request_subtype,before_value,requested_value,calculated_minutes,
    approved_minutes,reason,status,reviewer_id,reviewer_comment,reviewed_at,org_id
  ) values (
    v_record_id,p_employee_id,p_start_date,p_end_date,p_start_time,p_end_time,
    'emergency_support','긴급 내담자 지원','관리자 직접 등록',v_minutes::text,v_minutes,
    v_minutes,trim(p_reason),'approved',auth.uid(),'관리자 직접 확인 등록',now(),v_employee_org_id
  ) returning id into v_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,correction_request_id,org_id
  ) values (
    v_record_id,p_employee_id,'emergency_support_created','emergency_support','없음',
    jsonb_build_object('status','approved','start_date',p_start_date,'end_date',p_end_date,
      'start_time',p_start_time,'end_time',p_end_time,'minutes',v_minutes)::text,
    trim(p_reason),auth.uid(),v_role,v_request_id,v_employee_org_id
  );
  return v_request_id;
end $$;

create or replace function public.admin_update_attendance(
  p_record_id uuid, p_clock_in_time time, p_clock_out_time time,
  p_work_type text, p_attendance_status text, p_note text, p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_before text;
  v_after text;
  v_clock_in timestamptz;
  v_clock_out timestamptz;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records
  where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_record.org_id is distinct from v_org_id then
    raise exception 'ORGANIZATION_ACCESS_DENIED';
  end if;
  if exists (
    select 1 from public.monthly_closings
    where org_id = v_record.org_id
      and year = extract(year from v_record.work_date)
      and month = extract(month from v_record.work_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  v_clock_in := case when p_clock_in_time is null then null
    else (v_record.work_date + p_clock_in_time) at time zone 'Asia/Seoul' end;
  v_clock_out := case when p_clock_out_time is null then null
    else (v_record.work_date + p_clock_out_time) at time zone 'Asia/Seoul' end;
  if v_clock_out is not null and v_clock_in is null then raise exception 'CLOCK_IN_REQUIRED'; end if;
  if v_clock_out = v_clock_in then raise exception 'INVALID_TIME_RANGE'; end if;
  if v_clock_out is not null and v_clock_out < v_clock_in then v_clock_out := v_clock_out + interval '1 day'; end if;

  v_before := jsonb_build_object('clock_in_at',v_record.clock_in_at,'clock_out_at',v_record.clock_out_at,
    'work_type',v_record.work_type,'attendance_status',v_record.attendance_status,'note',v_record.note)::text;
  update public.attendance_records set
    clock_in_at = v_clock_in, clock_out_at = v_clock_out,
    clock_in_accuracy = case when v_clock_in is null then null else clock_in_accuracy end,
    clock_in_distance = case when v_clock_in is null then null else clock_in_distance end,
    clock_in_location_status = case when v_clock_in is null then 'not_checked' else clock_in_location_status end,
    clock_in_ip_address = case when v_clock_in is null then null else clock_in_ip_address end,
    clock_in_ip_matched = case when v_clock_in is null then false else clock_in_ip_matched end,
    clock_out_accuracy = case when v_clock_out is null then null else clock_out_accuracy end,
    clock_out_distance = case when v_clock_out is null then null else clock_out_distance end,
    clock_out_location_status = case when v_clock_out is null then 'not_checked' else clock_out_location_status end,
    clock_out_ip_address = case when v_clock_out is null then null else clock_out_ip_address end,
    clock_out_ip_matched = case when v_clock_out is null then false else clock_out_ip_matched end,
    work_type = p_work_type,
    attendance_status = case
      when v_clock_in is null and exists (
        select 1 from public.correction_requests r
        where r.employee_id = v_record.employee_id and r.request_type = 'emergency_support'
          and r.status = 'approved' and r.target_date = v_record.work_date
      ) then 'holiday_work'
      when v_clock_in is null and exists (
        select 1 from public.correction_requests r
        where r.employee_id = v_record.employee_id
          and r.request_type in ('annual_leave','comp_time','sick_leave','special_leave','other_leave')
          and r.status = 'approved' and r.target_date <= v_record.work_date
          and coalesce(r.end_date,r.target_date) >= v_record.work_date
      ) then 'leave'
      when v_clock_in is null then 'missing_in'
      when v_clock_out is null and v_record.work_date < (now() at time zone 'Asia/Seoul')::date then 'missing_out'
      when v_clock_out is null then 'working'
      else p_attendance_status
    end,
    note = coalesce(p_note,''), changed = true, is_closed = false, updated_at = now()
  where id = p_record_id
  returning jsonb_build_object('clock_in_at',clock_in_at,'clock_out_at',clock_out_at,
    'work_type',work_type,'attendance_status',attendance_status,'note',note)::text into v_after;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,org_id
  ) values (
    v_record.id,v_record.employee_id,'admin_update','attendance_record',v_before,v_after,
    trim(p_reason),auth.uid(),v_role,v_record.org_id
  );
end $$;

-- 이전 버전에서 시각만 삭제되어 남은 위치 정보를 한 번 정리한다.
update public.attendance_records set
  clock_in_accuracy = null,
  clock_in_distance = null,
  clock_in_location_status = 'not_checked',
  clock_in_ip_address = null,
  clock_in_ip_matched = false
where clock_in_at is null
  and (clock_in_accuracy is not null or clock_in_distance is not null
    or clock_in_location_status <> 'not_checked' or clock_in_ip_address is not null
    or clock_in_ip_matched is true);

update public.attendance_records set
  clock_out_accuracy = null,
  clock_out_distance = null,
  clock_out_location_status = 'not_checked',
  clock_out_ip_address = null,
  clock_out_ip_matched = false
where clock_out_at is null
  and (clock_out_accuracy is not null or clock_out_distance is not null
    or clock_out_location_status <> 'not_checked' or clock_out_ip_address is not null
    or clock_out_ip_matched is true);

create or replace function public.cleanup_attendance_events_after_time_clear()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.clock_in_at is not null and new.clock_in_at is null then
    delete from public.attendance_events
    where employee_id = new.employee_id and work_date = new.work_date
      and action_type in ('clock_in','clock_out');
  elsif old.clock_out_at is not null and new.clock_out_at is null then
    delete from public.attendance_events
    where employee_id = new.employee_id and work_date = new.work_date and action_type = 'clock_out';
  end if;
  return new;
end $$;

drop trigger if exists attendance_cleanup_events_after_time_clear on public.attendance_records;
create trigger attendance_cleanup_events_after_time_clear
after update of clock_in_at,clock_out_at on public.attendance_records
for each row
when (old.clock_in_at is distinct from new.clock_in_at or old.clock_out_at is distinct from new.clock_out_at)
execute function public.cleanup_attendance_events_after_time_clear();

revoke all on function public.calculate_emergency_support_minutes(date,date,time,time) from public,anon;
revoke all on function public.emergency_support_time_overlaps(uuid,date,date,time,time,uuid) from public,anon;
revoke all on function public.admin_create_emergency_support_work(uuid,date,date,time,time,text) from public,anon;
revoke all on function public.admin_update_attendance(uuid,time,time,text,text,text,text) from public,anon;
revoke all on function public.cleanup_attendance_events_after_time_clear() from public,anon,authenticated;
grant execute on function public.calculate_emergency_support_minutes(date,date,time,time) to authenticated;
grant execute on function public.admin_create_emergency_support_work(uuid,date,date,time,time,text) to authenticated;
grant execute on function public.admin_update_attendance(uuid,time,time,text,text,text,text) to authenticated;

notify pgrst, 'reload schema';
commit;

select '긴급지원 등록과 출퇴근시각 삭제 보완 완료' as result;


-- ============================================================================
-- 로그인 비밀번호 전환 상태 보완
-- ============================================================================

begin;

alter table public.profiles
  add column if not exists must_change_password boolean not null default false;

create or replace function public.complete_required_password_change()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  update public.profiles
  set must_change_password = false,
      updated_at = now()
  where id = auth.uid();
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
end
$$;

revoke all on function public.complete_required_password_change() from public, anon;
grant execute on function public.complete_required_password_change() to authenticated;

notify pgrst, 'reload schema';

commit;

select '로그인 비밀번호 전환 상태 보완 완료' as result;

-- ============================================================================
-- supabase/repair_weekly_overtime_notice_and_emergency_cancel.sql
-- ============================================================================

begin;

alter table public.attendance_records drop constraint if exists attendance_records_overtime_minutes_check;
alter table public.attendance_records
  add constraint attendance_records_overtime_minutes_check
  check (raw_overtime_minutes between 0 and 1440 and recorded_overtime_minutes between 0 and 1440 and approved_overtime_minutes between 0 and 1440) not valid;

create or replace function public.recalculate_overtime_after_attendance_change()
returns trigger language plpgsql set search_path = public as $$
declare
  v_settings public.organization_settings;
  v_policy public.organization_work_policies;
  v_worked integer := 0; v_lunch integer := 0; v_leave integer := 0;
  v_actual integer := 0; v_raw integer := 0; v_recognized integer := 0;
  v_lunch_from timestamptz; v_lunch_until timestamptz;
  v_is_holiday boolean := false; v_should_reopen boolean := false;
begin
  select * into v_settings from public.organization_settings where org_id = new.org_id;
  if not found then raise exception 'ORGANIZATION_SETTINGS_REQUIRED'; end if;
  select * into v_policy from public.organization_work_policies where org_id = new.org_id;
  if new.clock_in_at is not null and new.clock_out_at is not null and new.clock_out_at > new.clock_in_at then
    v_worked := floor(extract(epoch from (new.clock_out_at - new.clock_in_at)) / 60)::integer;
    v_lunch_from := (new.work_date + time '12:00') at time zone 'Asia/Seoul';
    v_lunch_until := (new.work_date + time '13:00') at time zone 'Asia/Seoul';
    if least(new.clock_out_at,v_lunch_until) > greatest(new.clock_in_at,v_lunch_from) then
      v_lunch := floor(extract(epoch from (least(new.clock_out_at,v_lunch_until) - greatest(new.clock_in_at,v_lunch_from))) / 60)::integer;
    end if;
    v_leave := public.approved_leave_minutes_during_attendance(new.employee_id,new.clock_in_at,new.clock_out_at);
    v_is_holiday := extract(isodow from new.work_date)::smallint <> all(v_settings.work_days)
      or exists (select 1 from public.organization_holidays where org_id = new.org_id and holiday_date = new.work_date);
    v_actual := greatest(0,v_worked - case when v_is_holiday then 0 else v_lunch end - v_leave);
    v_raw := case when v_is_holiday then v_actual else greatest(0,v_actual - 480) end;
    v_recognized := case
      when v_is_holiday and coalesce(v_policy.holiday_work_counts_as_overtime,true)
        then least(1440,ceil(v_raw::numeric / coalesce(v_policy.overtime_rounding_minutes,30))::integer * coalesce(v_policy.overtime_rounding_minutes,30))
      when v_is_holiday then 0
      else public.recognized_overtime_minutes(v_raw)
    end;
  end if;
  v_should_reopen := tg_op = 'INSERT' or old.clock_in_at is distinct from new.clock_in_at
    or old.clock_out_at is distinct from new.clock_out_at or new.overtime_status = 'pending';
  new.raw_overtime_minutes := v_raw;
  new.recorded_overtime_minutes := v_recognized;
  if v_recognized > 0 and v_should_reopen then
    new.overtime_status := 'pending'; new.approved_overtime_minutes := 0; new.comp_time_eligible_minutes := 0;
  elsif v_recognized = 0 then
    new.overtime_status := 'none'; new.approved_overtime_minutes := 0; new.comp_time_eligible_minutes := 0;
  end if;
  return new;
end $$;

update public.attendance_records
set clock_out_at = clock_out_at
where clock_in_at is not null and clock_out_at is not null and deleted_at is null;

do $$
declare
  item record;
  original_definition text;
  repaired_definition text;
begin
  for item in
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('admin_review_overtime','review_correction_request')
  loop
    original_definition := pg_get_functiondef(item.oid);
    repaired_definition := original_definition;
    repaired_definition := replace(repaired_definition,
      'if v_week_total + p_approved_minutes > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;', '');
    repaired_definition := replace(repaired_definition,
      'if v_week_total + p_approved_minutes + p_comp_time_minutes > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;', '');
    repaired_definition := replace(repaired_definition,
      'if v_week_total + v_approved > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;', '');
    if repaired_definition <> original_definition then execute repaired_definition; end if;
  end loop;
end $$;

create or replace function public.admin_cancel_emergency_support_work(
  p_request_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_request from public.correction_requests
  where id = p_request_id and request_type = 'emergency_support' for update;
  if not found then raise exception 'EMERGENCY_SUPPORT_NOT_FOUND'; end if;
  if v_request.status <> 'approved' then raise exception 'APPROVED_EMERGENCY_SUPPORT_REQUIRED'; end if;
  if v_role <> 'super_admin' and v_request.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if exists (
    select 1 from public.monthly_closings
    where org_id = v_request.org_id and year = extract(year from v_request.target_date)
      and month = extract(month from v_request.target_date) and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  update public.correction_requests
  set status = 'cancelled', approved_minutes = 0, reviewer_id = auth.uid(),
      reviewer_comment = '관리자 승인 취소: ' || trim(p_reason), reviewed_at = now()
  where id = p_request_id;
  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,correction_request_id,org_id
  ) values (
    v_request.attendance_record_id,v_request.employee_id,'emergency_support_approval_cancelled','emergency_support',
    jsonb_build_object('status',v_request.status,'minutes',v_request.approved_minutes,'start_date',v_request.target_date,'end_date',v_request.end_date,'start_time',v_request.start_time,'end_time',v_request.end_time)::text,
    jsonb_build_object('status','cancelled','minutes',0)::text,
    trim(p_reason),auth.uid(),v_role,v_request.id,v_request.org_id
  );
end $$;

revoke all on function public.admin_cancel_emergency_support_work(uuid,text) from public,anon;
grant execute on function public.admin_cancel_emergency_support_work(uuid,text) to authenticated;
notify pgrst, 'reload schema';
commit;

select '주간 시간외 안내 전환과 승인 긴급지원 취소 보완 완료' as result;

-- ============================================================================
-- supabase/repair_auth_information_leaks.sql
-- ============================================================================

begin;

create or replace function public.complete_required_password_change()
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  update public.profiles set must_change_password = false, updated_at = now() where id = auth.uid();
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
end $$;

revoke all on function public.complete_required_password_change() from public,anon;
grant execute on function public.complete_required_password_change() to authenticated;
revoke all on function public.emergency_support_time_overlaps(uuid,date,date,time,time,uuid)
from public,anon,authenticated;

notify pgrst, 'reload schema';
commit;

select '로그인 정보노출과 내부 긴급지원 함수 권한 보완 완료' as result;

-- ============================================================================
-- supabase/repair_weekly_overtime_server_override.sql
-- ============================================================================

begin;

-- 이전 버전의 절대 차단을 제거하고 아래의 서버 확인 절차로 대체합니다.
do $$
declare item record; original_definition text; repaired_definition text;
begin
  for item in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('admin_review_overtime','review_correction_request')
  loop
    original_definition := pg_get_functiondef(item.oid);
    repaired_definition := replace(original_definition,
      'if v_week_total + p_approved_minutes > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;', '');
    repaired_definition := replace(repaired_definition,
      'if v_week_total + p_approved_minutes + p_comp_time_minutes > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;', '');
    repaired_definition := replace(repaired_definition,
      'if v_week_total + v_approved > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;', '');
    if repaired_definition <> original_definition then execute repaired_definition; end if;
  end loop;
end $$;

create table if not exists public.weekly_overtime_override_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  employee_id uuid not null references public.profiles(id) on delete restrict,
  week_start date not null,
  proposed_total_minutes integer not null check (proposed_total_minutes > 720 and proposed_total_minutes <= 10080),
  reason text not null check (char_length(trim(reason)) >= 5),
  acknowledged_by uuid not null references public.profiles(id) on delete restrict,
  acknowledged_at timestamptz not null default now(),
  consumed_at timestamptz,
  consumed_for_type text not null default '',
  consumed_for_id uuid
);

alter table public.weekly_overtime_override_acknowledgements enable row level security;
revoke all on table public.weekly_overtime_override_acknowledgements from public,anon,authenticated;

create or replace function public.acknowledge_weekly_overtime_override(
  p_employee_id uuid,
  p_work_date date,
  p_proposed_total_minutes integer,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_employee_org_id uuid;
  v_week_start date := date_trunc('week',p_work_date::timestamp)::date;
  v_id uuid;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_proposed_total_minutes <= 720 then raise exception 'WEEKLY_OVERRIDE_NOT_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'WEEKLY_OVERRIDE_REASON_REQUIRED'; end if;
  select org_id into v_employee_org_id from public.profiles where id = p_employee_id and is_active = true;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_employee_org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;

  insert into public.weekly_overtime_override_acknowledgements (
    org_id,employee_id,week_start,proposed_total_minutes,reason,acknowledged_by
  ) values (
    v_employee_org_id,p_employee_id,v_week_start,p_proposed_total_minutes,trim(p_reason),auth.uid()
  ) returning id into v_id;

  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,reason,
    changed_by,changed_by_role,org_id
  ) values (
    p_employee_id,'weekly_overtime_override_acknowledged','weekly_overtime_minutes',
    '720',p_proposed_total_minutes::text,trim(p_reason),auth.uid(),v_role,v_employee_org_id
  );
  return v_id;
end $$;

create or replace function public.consume_weekly_overtime_override(
  p_employee_id uuid,
  p_work_date date,
  p_proposed_total_minutes integer,
  p_type text,
  p_target_id uuid
) returns void
language plpgsql security definer set search_path = public as $$
declare v_ack_id uuid;
begin
  if p_proposed_total_minutes <= 720 then return; end if;
  select id into v_ack_id
  from public.weekly_overtime_override_acknowledgements
  where employee_id = p_employee_id
    and week_start = date_trunc('week',p_work_date::timestamp)::date
    and proposed_total_minutes = p_proposed_total_minutes
    and acknowledged_by = auth.uid()
    and consumed_at is null
    and acknowledged_at >= now() - interval '10 minutes'
  order by acknowledged_at desc
  limit 1 for update;
  if not found then raise exception 'WEEKLY_OVERTIME_OVERRIDE_REQUIRED'; end if;
  update public.weekly_overtime_override_acknowledgements
  set consumed_at = now(), consumed_for_type = p_type, consumed_for_id = p_target_id
  where id = v_ack_id;
end $$;

create or replace function public.enforce_weekly_override_on_overtime_approval()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_week_start date; v_total integer;
begin
  if new.overtime_status <> 'approved'
     or (tg_op = 'UPDATE' and old.overtime_status = 'approved' and old.approved_overtime_minutes = new.approved_overtime_minutes) then
    return new;
  end if;
  v_week_start := date_trunc('week',new.work_date::timestamp)::date;
  select coalesce(sum(approved_overtime_minutes),0)::integer into v_total
  from public.attendance_records
  where employee_id = new.employee_id and id <> new.id and deleted_at is null
    and overtime_status = 'approved' and work_date between v_week_start and v_week_start + 6;
  select v_total + coalesce(sum(approved_minutes),0)::integer into v_total
  from public.correction_requests
  where employee_id = new.employee_id and request_type = 'emergency_support' and status = 'approved'
    and target_date between v_week_start and v_week_start + 6;
  v_total := v_total + coalesce(new.approved_overtime_minutes,0);
  perform public.consume_weekly_overtime_override(new.employee_id,new.work_date,v_total,'overtime',new.id);
  return new;
end $$;

create or replace function public.enforce_weekly_override_on_emergency_approval()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_week_start date; v_total integer;
begin
  if new.request_type <> 'emergency_support' or new.status <> 'approved'
     or (tg_op = 'UPDATE' and old.status = 'approved' and old.approved_minutes = new.approved_minutes) then
    return new;
  end if;
  v_week_start := date_trunc('week',new.target_date::timestamp)::date;
  select coalesce(sum(approved_overtime_minutes),0)::integer into v_total
  from public.attendance_records
  where employee_id = new.employee_id and deleted_at is null and overtime_status = 'approved'
    and work_date between v_week_start and v_week_start + 6;
  select v_total + coalesce(sum(approved_minutes),0)::integer into v_total
  from public.correction_requests
  where employee_id = new.employee_id and id <> new.id
    and request_type = 'emergency_support' and status = 'approved'
    and target_date between v_week_start and v_week_start + 6;
  v_total := v_total + coalesce(new.approved_minutes,new.calculated_minutes,0);
  perform public.consume_weekly_overtime_override(new.employee_id,new.target_date,v_total,'emergency_support',new.id);
  return new;
end $$;

drop trigger if exists enforce_weekly_override_on_overtime_approval_trigger on public.attendance_records;
create trigger enforce_weekly_override_on_overtime_approval_trigger
before insert or update of overtime_status,approved_overtime_minutes on public.attendance_records
for each row execute function public.enforce_weekly_override_on_overtime_approval();

drop trigger if exists enforce_weekly_override_on_emergency_approval_trigger on public.correction_requests;
create trigger enforce_weekly_override_on_emergency_approval_trigger
before insert or update of status,approved_minutes on public.correction_requests
for each row execute function public.enforce_weekly_override_on_emergency_approval();

revoke all on function public.acknowledge_weekly_overtime_override(uuid,date,integer,text) from public,anon;
grant execute on function public.acknowledge_weekly_overtime_override(uuid,date,integer,text) to authenticated;
revoke all on function public.consume_weekly_overtime_override(uuid,date,integer,text,uuid) from public,anon,authenticated;
revoke all on function public.enforce_weekly_override_on_overtime_approval() from public,anon,authenticated;
revoke all on function public.enforce_weekly_override_on_emergency_approval() from public,anon,authenticated;

-- 관리자 로그인 성공 이력: GPS 없이 시각, IP, 기기 정보만 1년간 보관합니다.
create table if not exists public.admin_login_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references public.organizations(id) on delete restrict,
  profile_id uuid not null references public.profiles(id) on delete restrict,
  role text not null check (role in ('org_admin', 'admin', 'super_admin')),
  ip_address text not null check (char_length(ip_address) between 2 and 64),
  device_info text not null default '' check (char_length(device_info) <= 500),
  created_at timestamptz not null default now()
);
create index if not exists admin_login_logs_created_idx on public.admin_login_logs (created_at desc);
create index if not exists admin_login_logs_org_created_idx on public.admin_login_logs (org_id, created_at desc);
alter table public.admin_login_logs enable row level security;
drop policy if exists "admin login history read" on public.admin_login_logs;
create policy "admin login history read" on public.admin_login_logs
  for select to authenticated
  using (
    public.current_profile_role() = 'super_admin'
    or (public.current_profile_role() in ('admin', 'org_admin') and profile_id = auth.uid())
  );
revoke all on public.admin_login_logs from public, anon;
grant select on public.admin_login_logs to authenticated;

notify pgrst, 'reload schema';
commit;

select '주 12시간 초과 승인 서버 확인과 감사기록 보완 완료' as result;


-- ============================================================================
-- supabase/repair_overtime_request_regular_hours.sql
-- ============================================================================

begin;

create or replace function public.calculate_overtime_request_minutes(
  p_org_id uuid,p_work_date date,p_start_time time,p_end_time time
) returns integer
language plpgsql stable security definer set search_path = public as $$
declare
  v_settings public.organization_settings;
  v_total integer;
  v_before_work integer := 0;
  v_after_work integer := 0;
  v_is_holiday boolean;
begin
  if p_start_time is null or p_end_time is null or p_end_time <= p_start_time then raise exception 'INVALID_OVERTIME_RANGE'; end if;
  select * into v_settings from public.organization_settings where org_id = p_org_id;
  if not found then raise exception 'ORGANIZATION_SETTINGS_REQUIRED'; end if;
  v_total := floor(extract(epoch from (p_end_time - p_start_time)) / 60)::integer;
  v_is_holiday := extract(isodow from p_work_date)::smallint <> all(v_settings.work_days)
    or exists (select 1 from public.organization_holidays where org_id = p_org_id and holiday_date = p_work_date);
  if v_is_holiday then return v_total; end if;
  v_before_work := greatest(0,floor(extract(epoch from (least(p_end_time,v_settings.default_start_time) - p_start_time)) / 60)::integer);
  v_after_work := greatest(0,floor(extract(epoch from (p_end_time - greatest(p_start_time,v_settings.default_end_time))) / 60)::integer);
  return v_before_work + v_after_work;
end $$;

create or replace function public.prepare_attendance_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.end_date := coalesce(new.end_date,new.target_date);
  if new.request_type in ('clock_in_at','clock_out_at') then
    new.end_date := new.target_date;
    new.calculated_minutes := 0;
  elsif new.request_type = 'overtime' then
    new.end_date := new.target_date;
    new.calculated_minutes := public.calculate_overtime_request_minutes(new.org_id,new.target_date,new.start_time,new.end_time);
    if new.calculated_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;
    new.requested_value := new.calculated_minutes::text;
  elsif new.request_type in ('annual_leave','comp_time','special_leave','sick_leave','business_trip','other_leave') then
    new.calculated_minutes := public.calculate_attendance_request_minutes(new.request_type,new.target_date,new.end_date,new.start_time,new.end_time);
    if new.calculated_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;
    new.requested_value := new.calculated_minutes::text;
  end if;
  if new.request_type in ('special_leave','other_leave') and char_length(trim(coalesce(new.request_subtype,''))) < 2 then raise exception 'LEAVE_NAME_REQUIRED'; end if;
  return new;
end $$;

revoke all on function public.calculate_overtime_request_minutes(uuid,date,time,time) from public,anon,authenticated;
notify pgrst, 'reload schema';
commit;

select '시간외근무 신청 정규 근무시간 제외 계산 보완 완료' as result;


-- ============================================================================
-- supabase/repair_org_admin_leave_application.sql
-- ============================================================================

begin;

create or replace function public.admin_apply_leave_to_attendance_record(
  p_record_id uuid,p_request_type text,p_start_time time,p_end_time time,p_request_subtype text,p_comment text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_request_id uuid;
  v_minutes integer;
  v_leave_type text := 'none';
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_request_type not in ('annual_leave','comp_time','special_leave','sick_leave','other_leave') then raise exception 'INVALID_LEAVE_TYPE'; end if;
  if char_length(trim(coalesce(p_comment,''))) < 5 then raise exception 'COMMENT_REQUIRED'; end if;
  if p_start_time is null or p_end_time is null or p_end_time <= p_start_time then raise exception 'INVALID_TIME_RANGE'; end if;
  if p_request_type in ('special_leave','other_leave') and char_length(trim(coalesce(p_request_subtype,''))) < 2 then raise exception 'LEAVE_NAME_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_record.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if exists (
    select 1 from public.monthly_closings closing
    where closing.org_id = v_record.org_id
      and closing.year = extract(year from v_record.work_date)
      and closing.month = extract(month from v_record.work_date)
      and closing.status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  v_minutes := public.calculate_attendance_request_minutes(p_request_type,v_record.work_date,v_record.work_date,p_start_time,p_end_time);
  if v_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;
  insert into public.correction_requests (
    attendance_record_id,employee_id,target_date,end_date,start_time,end_time,calculated_minutes,approved_minutes,
    request_type,request_subtype,before_value,requested_value,reason,status,reviewer_id,reviewer_comment,reviewed_at,org_id
  ) values (
    v_record.id,v_record.employee_id,v_record.work_date,v_record.work_date,p_start_time,p_end_time,v_minutes,v_minutes,
    p_request_type,case when p_request_type in ('special_leave','other_leave') then trim(coalesce(p_request_subtype,'')) else '' end,
    v_record.attendance_status,v_minutes::text,trim(p_comment),'approved',auth.uid(),trim(p_comment),now(),v_record.org_id
  ) returning id into v_request_id;
  if p_request_type = 'annual_leave' then
    v_leave_type := case v_minutes when 480 then 'annual_leave' when 240 then 'half_day' when 120 then 'quarter_day' when 60 then 'hourly_leave' else 'none' end;
  elsif p_request_type = 'sick_leave' then v_leave_type := 'sick_leave'; end if;
  update public.attendance_records
  set attendance_status = case when clock_out_at is null then 'working' else 'normal' end,
      leave_type = v_leave_type,changed = true,updated_at = now()
  where id = v_record.id;
  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,reason,
    changed_by,changed_by_role,correction_request_id,org_id
  ) values (
    v_record.id,v_record.employee_id,'admin_leave_applied','leave_request',v_record.attendance_status,
    jsonb_build_object('request_type',p_request_type,'start_time',p_start_time,'end_time',p_end_time,'minutes',v_minutes,'subtype',trim(coalesce(p_request_subtype,'')))::text,
    trim(p_comment),auth.uid(),v_role,v_request_id,v_record.org_id
  );
  return v_request_id;
end $$;

revoke all on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) from public,anon;
grant execute on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) to authenticated;
notify pgrst, 'reload schema';
commit;

select '기관관리자 휴가와 대체휴무 반영 권한 보완 완료' as result;

-- ============================================================================
-- supabase/repair_org_admin_leave_reversal.sql
-- ============================================================================
begin;

create or replace function public.admin_reopen_correction_request(
  p_request_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_request.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if v_request.status in ('pending','more_info') then raise exception 'REQUEST_ALREADY_OPEN'; end if;
  if v_request.status = 'approved' and v_request.request_type in ('clock_in_at','clock_out_at') then raise exception 'APPLIED_CLOCK_CORRECTION'; end if;
  if exists (
    select 1 from public.monthly_closings closing
    where closing.org_id = v_request.org_id
      and closing.year = extract(year from v_request.target_date)
      and closing.month = extract(month from v_request.target_date)
      and closing.status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  update public.correction_requests
  set status = 'pending', approved_minutes = 0,
      reviewer_id = null, reviewer_comment = '', reviewed_at = null
  where id = p_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role,
    correction_request_id, org_id
  ) values (
    v_request.attendance_record_id, v_request.employee_id, 'request_reopened', 'request_status',
    v_request.status, 'pending', trim(p_reason), auth.uid(), v_role,
    v_request.id, v_request.org_id
  );
end $$;

create or replace function public.review_correction_request(
  p_request_id uuid,
  p_decision text,
  p_comment text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_before text := '';
  v_after text := '';
  v_approved integer := 0;
  v_week_total integer := 0;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected','more_info') then raise exception 'INVALID_DECISION'; end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_comment,''))) < 2 then raise exception 'COMMENT_REQUIRED'; end if;

  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found or v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_REVIEWABLE'; end if;
  if v_role <> 'super_admin' and v_request.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if exists (
    select 1 from public.monthly_closings closing
    where closing.org_id = v_request.org_id
      and closing.year = extract(year from v_request.target_date)
      and closing.month = extract(month from v_request.target_date)
      and closing.status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  if p_decision = 'approved' and v_request.request_type in ('clock_in_at','clock_out_at') then
    select * into v_record from public.attendance_records
    where id = v_request.attendance_record_id
      and org_id = v_request.org_id
      and deleted_at is null for update;
    if not found and v_request.request_type = 'clock_in_at' then
      insert into public.attendance_records (employee_id, work_date, work_type, attendance_status, note, changed, org_id)
      values (v_request.employee_id, v_request.target_date, 'office', 'missing_out', '수정 요청으로 생성된 기록', true, v_request.org_id)
      on conflict (employee_id, work_date) do update
      set changed = true, deleted_at = null, deleted_by = null, deletion_reason = '', updated_at = now()
      returning * into v_record;
      update public.correction_requests set attendance_record_id = v_record.id where id = v_request.id;
    elsif not found then
      raise exception 'CLOCK_IN_CORRECTION_REQUIRED_FIRST';
    end if;

    if v_request.request_type = 'clock_in_at' then
      v_before := coalesce(v_record.clock_in_at::text,'');
      update public.attendance_records
      set clock_in_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true
      where id = v_record.id returning clock_in_at::text into v_after;
    else
      v_before := coalesce(v_record.clock_out_at::text,'');
      update public.attendance_records
      set clock_out_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true
      where id = v_record.id returning clock_out_at::text into v_after;
    end if;
  elsif p_decision = 'approved' then
    if v_request.request_type = 'overtime' then
      select * into v_record
      from public.attendance_records
      where deleted_at is null
        and org_id = v_request.org_id
        and employee_id = v_request.employee_id
        and work_date = v_request.target_date
      for update;
      if not found or v_record.clock_out_at is null or coalesce(v_record.recorded_overtime_minutes,0) <= 0 then
        raise exception 'ACTUAL_OVERTIME_REQUIRED';
      end if;
      v_approved := least(v_request.calculated_minutes,v_record.recorded_overtime_minutes);
      select coalesce(sum(approved_minutes),0)::integer into v_week_total
      from public.correction_requests
      where org_id = v_request.org_id
        and employee_id = v_request.employee_id
        and request_type = 'overtime'
        and status = 'approved'
        and id <> v_request.id
        and target_date >= date_trunc('week',v_request.target_date::timestamp)::date
        and target_date < date_trunc('week',v_request.target_date::timestamp)::date + 7;
      if v_week_total + v_approved > 720 then raise exception 'WEEKLY_OVERTIME_LIMIT'; end if;
      update public.correction_requests set attendance_record_id = v_record.id where id = v_request.id;
    else
      v_approved := v_request.calculated_minutes;
    end if;
    v_before := '미승인';
    v_after := jsonb_build_object(
      'start_date',v_request.target_date,'end_date',v_request.end_date,
      'start_time',v_request.start_time,'end_time',v_request.end_time,
      'requested_minutes',v_request.calculated_minutes,'approved_minutes',v_approved,
      'subtype',v_request.request_subtype
    )::text;
    update public.correction_requests set approved_minutes = v_approved where id = v_request.id;
  end if;

  if p_decision = 'approved' then
    insert into public.attendance_audit_logs (
      attendance_record_id, employee_id, action_type, changed_field,
      before_value, after_value, reason, changed_by, changed_by_role, correction_request_id, org_id
    ) values (
      coalesce(v_record.id,v_request.attendance_record_id),v_request.employee_id,'request_approved',v_request.request_type,
      v_before,v_after,coalesce(nullif(trim(p_comment),''),v_request.reason),auth.uid(),v_role,v_request.id,v_request.org_id
    );
  end if;

  update public.correction_requests
  set status = p_decision,
      reviewer_id = auth.uid(),
      reviewer_comment = coalesce(p_comment,''),
      reviewed_at = now()
  where id = p_request_id;
end $$;

create or replace function public.sync_attendance_leave_type_from_request()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_record record;
  v_leave_request public.correction_requests;
  v_leave_type text;
begin
  if new.request_type not in ('annual_leave','comp_time','special_leave','sick_leave','other_leave') then return new; end if;

  for v_record in
    select id, work_date
    from public.attendance_records
    where org_id = new.org_id
      and employee_id = new.employee_id
      and work_date between new.target_date and coalesce(new.end_date,new.target_date)
      and deleted_at is null
  loop
    v_leave_type := 'none';
    select request.* into v_leave_request
    from public.correction_requests request
    where request.org_id = new.org_id
      and request.employee_id = new.employee_id
      and request.status = 'approved'
      and request.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
      and request.target_date <= v_record.work_date
      and coalesce(request.end_date,request.target_date) >= v_record.work_date
    order by request.reviewed_at desc nulls last, request.requested_at desc
    limit 1;

    if found then
      if v_leave_request.request_type = 'annual_leave' then
        v_leave_type := case
          when v_leave_request.calculated_minutes >= 480 then 'annual_leave'
          when v_leave_request.calculated_minutes = 240 then 'half_day'
          when v_leave_request.calculated_minutes = 120 then 'quarter_day'
          when v_leave_request.calculated_minutes = 60 then 'hourly_leave'
          else 'none'
        end;
      elsif v_leave_request.request_type = 'sick_leave' then
        v_leave_type := 'sick_leave';
      end if;
    end if;

    update public.attendance_records
    set leave_type = v_leave_type, changed = true, updated_at = now()
    where id = v_record.id and leave_type is distinct from v_leave_type;
  end loop;
  return new;
end $$;

drop trigger if exists sync_attendance_leave_type_from_request_trigger on public.correction_requests;
create trigger sync_attendance_leave_type_from_request_trigger
after insert or update of status
on public.correction_requests
for each row execute function public.sync_attendance_leave_type_from_request();

revoke all on function public.admin_reopen_correction_request(uuid,text) from public,anon;
grant execute on function public.admin_reopen_correction_request(uuid,text) to authenticated;
revoke all on function public.review_correction_request(uuid,text,text) from public,anon;
grant execute on function public.review_correction_request(uuid,text,text) to authenticated;
notify pgrst, 'reload schema';
commit;

select '기관관리자 휴가 재검토와 출근부 반영 취소 보완 완료' as result;

-- ============================================================================
-- supabase/repair_leave_adjusted_attendance_status.sql
-- ============================================================================
begin;

create or replace function public.derive_attendance_status(p_record public.attendance_records)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_settings public.organization_settings;
  v_is_regular_workday boolean;
  v_location_review boolean;
  v_expected_start time;
  v_elapsed_minutes integer;
  v_worked_minutes integer;
  v_approved_leave_minutes integer := 0;
  v_required_minutes integer := 480;
  v_leave_type text := 'none';
begin
  select * into v_settings from public.organization_settings where org_id = p_record.org_id;
  if not found then raise exception 'ORGANIZATION_SETTINGS_REQUIRED'; end if;
  v_leave_type := coalesce(to_jsonb(p_record)->>'leave_type','none');

  if p_record.clock_in_at is null then
    return case
      when v_leave_type in ('annual_leave','half_day','quarter_day','hourly_leave','sick_leave') then v_leave_type
      when p_record.attendance_status in ('business_trip','leave') then p_record.attendance_status
      else 'missing_in'
    end;
  end if;

  v_is_regular_workday := extract(isodow from p_record.work_date)::smallint = any(v_settings.work_days)
    and not exists (
      select 1 from public.organization_holidays
      where org_id = p_record.org_id and holiday_date = p_record.work_date and is_paid_holiday
    );
  v_location_review := (p_record.clock_in_location_status in ('outside','low_accuracy') and not coalesce(p_record.clock_in_ip_matched,false))
    or (p_record.clock_out_at is not null and p_record.clock_out_location_status in ('outside','low_accuracy') and not coalesce(p_record.clock_out_ip_matched,false));
  if v_location_review then return 'admin_review'; end if;
  if not v_is_regular_workday then return 'holiday_work'; end if;

  select coalesce(count(*),0)::integer into v_approved_leave_minutes
  from generate_series(
    p_record.work_date + v_settings.default_start_time,
    p_record.work_date + v_settings.default_end_time - interval '1 minute',
    interval '1 minute'
  ) minute_point
  where not (minute_point::time >= time '12:00' and minute_point::time < time '13:00')
    and exists (
      select 1 from public.correction_requests request
      where request.org_id = p_record.org_id
        and request.employee_id = p_record.employee_id
        and request.status = 'approved'
        and request.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
        and p_record.work_date between request.target_date and coalesce(request.end_date,request.target_date)
        and minute_point::time >= case when p_record.work_date = request.target_date then coalesce(request.start_time,v_settings.default_start_time) else v_settings.default_start_time end
        and minute_point::time < case when p_record.work_date = coalesce(request.end_date,request.target_date) then coalesce(request.end_time,v_settings.default_end_time) else v_settings.default_end_time end
    );

  v_expected_start := v_settings.default_start_time;
  select greatest(v_expected_start,coalesce(max(
    case when p_record.work_date = coalesce(request.end_date,request.target_date)
      then coalesce(request.end_time,v_settings.default_end_time)
      else v_settings.default_end_time end
  ),v_expected_start)) into v_expected_start
  from public.correction_requests request
  where request.org_id = p_record.org_id
    and request.employee_id = p_record.employee_id
    and request.status = 'approved'
    and request.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
    and p_record.work_date between request.target_date and coalesce(request.end_date,request.target_date)
    and (case when p_record.work_date = request.target_date then coalesce(request.start_time,v_settings.default_start_time) else v_settings.default_start_time end) <= v_settings.default_start_time;

  if (p_record.clock_in_at at time zone 'Asia/Seoul')::time > v_expected_start + make_interval(mins => v_settings.late_grace_minutes) then return 'late'; end if;
  if p_record.clock_out_at is null then return 'working'; end if;

  v_required_minutes := greatest(0,480 - v_approved_leave_minutes);
  v_elapsed_minutes := greatest(0,floor(extract(epoch from (p_record.clock_out_at - p_record.clock_in_at)) / 60)::integer);
  v_worked_minutes := greatest(0,v_elapsed_minutes - case
    when (p_record.clock_in_at at time zone 'Asia/Seoul')::time < time '13:00'
      and (p_record.clock_out_at at time zone 'Asia/Seoul')::time > time '12:00'
    then least(60,floor(extract(epoch from (
      least(p_record.clock_out_at,(p_record.work_date + time '13:00') at time zone 'Asia/Seoul')
      - greatest(p_record.clock_in_at,(p_record.work_date + time '12:00') at time zone 'Asia/Seoul')
    )) / 60)::integer)
    else 0 end);
  return case when v_worked_minutes < v_required_minutes then 'admin_review' else 'normal' end;
end $$;

create or replace function public.recalculate_attendance_after_leave_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.request_type not in ('annual_leave','comp_time','special_leave','sick_leave','other_leave') then return new; end if;
  if tg_op = 'UPDATE' and old.status is not distinct from new.status
     and old.target_date is not distinct from new.target_date
     and old.end_date is not distinct from new.end_date
     and old.start_time is not distinct from new.start_time
     and old.end_time is not distinct from new.end_time then return new; end if;
  update public.comp_time_credits credit
  set remaining_minutes = 0,reason = trim(concat_ws(E'\n',credit.reason,'휴가 반영으로 실제 근무시간 재검토'))
  where credit.attendance_record_id in (
    select record.id from public.attendance_records record
    where record.org_id = new.org_id and record.employee_id = new.employee_id
      and record.work_date between new.target_date and coalesce(new.end_date,new.target_date)
      and record.deleted_at is null
  ) and credit.remaining_minutes > 0;
  update public.attendance_records record
  set attendance_status = public.derive_attendance_status(record),
      overtime_status = case when record.clock_out_at is not null then 'pending' else record.overtime_status end,
      approved_overtime_minutes = case when record.clock_out_at is not null then 0 else record.approved_overtime_minutes end,
      comp_time_eligible_minutes = case when record.clock_out_at is not null then 0 else record.comp_time_eligible_minutes end,
      changed = true,updated_at = now()
  where record.org_id = new.org_id and record.employee_id = new.employee_id
    and record.work_date between new.target_date and coalesce(new.end_date,new.target_date)
    and record.deleted_at is null and record.clock_in_at is not null;
  return new;
end $$;

drop trigger if exists derive_attendance_status_on_insert on public.attendance_records;
create trigger derive_attendance_status_on_insert
before insert on public.attendance_records
for each row execute function public.recalculate_attendance_status_on_time_change();

update public.attendance_records record
set attendance_status = public.derive_attendance_status(record), updated_at = now()
where record.deleted_at is null
  and record.clock_in_at is not null
  and exists (
    select 1 from public.correction_requests request
    where request.org_id = record.org_id
      and request.employee_id = record.employee_id
      and request.status = 'approved'
      and request.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
      and record.work_date between request.target_date and coalesce(request.end_date,request.target_date)
  );

notify pgrst, 'reload schema';
commit;

select '승인 휴가 시간 반영 지각과 필요 근무시간 판정 보완 완료' as result;

begin;

create or replace function public.link_clock_correction_request_to_attendance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.request_type not in ('clock_in_at', 'clock_out_at') then
    return new;
  end if;
  if new.attendance_record_id is null then
    select record.id into new.attendance_record_id
    from public.attendance_records record
    where record.org_id = new.org_id
      and record.employee_id = new.employee_id
      and record.work_date = new.target_date
      and record.deleted_at is null
    order by record.created_at desc
    limit 1;
  end if;
  return new;
end;
$$;

drop trigger if exists link_clock_correction_request_to_attendance_trigger on public.correction_requests;
create trigger link_clock_correction_request_to_attendance_trigger
before insert or update of attendance_record_id, employee_id, target_date, request_type
on public.correction_requests
for each row execute function public.link_clock_correction_request_to_attendance();

update public.correction_requests request
set attendance_record_id = record.id
from public.attendance_records record
where request.request_type in ('clock_in_at', 'clock_out_at')
  and request.status in ('pending', 'more_info')
  and request.attendance_record_id is null
  and record.org_id = request.org_id
  and record.employee_id = request.employee_id
  and record.work_date = request.target_date
  and record.deleted_at is null;

notify pgrst, 'reload schema';
commit;

select '출퇴근 시각 수정 신청과 근태기록 연결 보완 완료' as result;

begin;

alter table public.organizations
  add column if not exists mobile_org_admin_access_enabled boolean not null default true;

update public.organizations
set mobile_org_admin_access_enabled = true
where mobile_org_admin_access_enabled is null;

notify pgrst, 'reload schema';
commit;

select '기관별 기관관리자 모바일 접속 설정 추가 완료' as result;

-- ============================================================================
-- supabase/repair_overtime_review_final_consistency.sql
-- ============================================================================
begin;

do $$
declare
  v_function oid;
  v_definition text;
  v_repaired_definition text;
begin
  select p.oid into v_function
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'review_correction_request'
    and pg_get_function_identity_arguments(p.oid) = 'p_request_id uuid, p_decision text, p_comment text';

  if v_function is null then raise exception 'REVIEW_CORRECTION_REQUEST_REQUIRED'; end if;
  v_definition := pg_get_functiondef(v_function);
  v_repaired_definition := replace(
    v_definition,
    'if v_week_total + v_approved > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;',
    ''
  );
  if v_repaired_definition <> v_definition then execute v_repaired_definition; end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'review_correction_request'
    and pg_get_function_identity_arguments(p.oid) = 'p_request_id uuid, p_decision text, p_comment text';
  if v_definition like '%WEEKLY_OVERTIME_LIMIT%' then
    raise exception 'OVERTIME_REVIEW_FINAL_CONSISTENCY_FAILED';
  end if;
end $$;

do $$
begin
  if to_regclass('public.weekly_overtime_override_acknowledgements') is null
     or to_regprocedure('public.acknowledge_weekly_overtime_override(uuid,date,integer,text)') is null
     or to_regprocedure('public.consume_weekly_overtime_override(uuid,date,integer,text,uuid)') is null then
    raise exception 'WEEKLY_OVERTIME_OVERRIDE_SQL_REQUIRED';
  end if;
  if not exists (
    select 1 from pg_trigger
    where tgname = 'enforce_weekly_override_on_overtime_approval_trigger' and not tgisinternal
  ) then
    raise exception 'WEEKLY_OVERTIME_OVERRIDE_TRIGGER_REQUIRED';
  end if;
end $$;

notify pgrst, 'reload schema';
commit;

select '시간외 승인 최종 함수 정합성 보완 완료' as result;

-- ============================================================================
-- supabase/repair_employee_overtime_request_cancel.sql
-- ============================================================================
begin;
create or replace function public.employee_cancel_correction_request(p_request_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare v_request public.correction_requests; v_actor public.profiles;
begin
  select * into v_actor from public.profiles where id=auth.uid() and role in ('employee','team_lead') and is_active=true;
  if not found then raise exception 'EMPLOYEE_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,'')))<2 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_request from public.correction_requests where id=p_request_id and employee_id=auth.uid() and request_type<>'emergency_support' for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_CANCELLABLE'; end if;
  update public.correction_requests set status='cancelled',approved_minutes=0,reviewer_id=null,reviewer_comment='활동가 취소: '||trim(p_reason),reviewed_at=now() where id=p_request_id;
  insert into public.attendance_audit_logs(attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,reason,changed_by,changed_by_role,correction_request_id,org_id)
  values(v_request.attendance_record_id,v_request.employee_id,'request_cancelled',v_request.request_type,jsonb_build_object('status',v_request.status,'requested_value',v_request.requested_value)::text,jsonb_build_object('status','cancelled')::text,trim(p_reason),auth.uid(),v_actor.role,v_request.id,v_request.org_id);
end $$;
revoke all on function public.employee_cancel_correction_request(uuid,text) from public,anon;
grant execute on function public.employee_cancel_correction_request(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
select '활동가 근태 신청 취소 보완 완료' as result;

-- ============================================================================
-- supabase/repair_overtime_preapproval_limits.sql
-- ============================================================================
begin;

alter table public.correction_requests
  add column if not exists overtime_approval_limit_minutes integer not null default 0,
  add column if not exists comp_time_approval_limit_minutes integer not null default 0,
  add column if not exists overtime_finalized_at timestamptz;

create or replace function public.finalize_preapproved_overtime(p_request_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare
  v_request public.correction_requests;
  v_record public.attendance_records;
  v_overtime integer := 0;
  v_comp integer := 0;
  v_used integer := 0;
begin
  select * into v_request from public.correction_requests
  where id=p_request_id and request_type='overtime' and status='approved' for update;
  if not found then return; end if;

  select * into v_record from public.attendance_records
  where org_id=v_request.org_id and employee_id=v_request.employee_id
    and work_date=v_request.target_date and deleted_at is null for update;
  if not found or v_record.clock_out_at is null then return; end if;

  v_overtime := least(coalesce(v_record.recorded_overtime_minutes,0),v_request.overtime_approval_limit_minutes);
  v_comp := least(coalesce(v_record.recorded_overtime_minutes,0),v_request.comp_time_approval_limit_minutes);

  update public.correction_requests set attendance_record_id=v_record.id,
    approved_minutes=v_overtime,overtime_finalized_at=now() where id=v_request.id;
  update public.attendance_records set overtime_status='approved',
    approved_overtime_minutes=v_overtime,comp_time_eligible_minutes=v_comp,
    changed=true,updated_at=now() where id=v_record.id;

  if v_comp > 0 then
    insert into public.comp_time_credits(attendance_record_id,employee_id,granted_minutes,
      remaining_minutes,expires_on,granted_by,reason)
    values(v_record.id,v_request.employee_id,v_comp,v_comp,v_record.work_date+30,
      v_request.reviewer_id,coalesce(nullif(trim(v_request.reviewer_comment),''),v_request.reason))
    on conflict(attendance_record_id) do update set
      granted_minutes=excluded.granted_minutes,
      remaining_minutes=greatest(0,excluded.granted_minutes-(public.comp_time_credits.granted_minutes-public.comp_time_credits.remaining_minutes)),
      expires_on=excluded.expires_on,granted_by=excluded.granted_by,granted_at=now(),reason=excluded.reason;
  else
    select coalesce(granted_minutes-remaining_minutes,0) into v_used
    from public.comp_time_credits where attendance_record_id=v_record.id;
    if v_used > 0 then raise exception 'COMP_TIME_ALREADY_USED'; end if;
    delete from public.comp_time_credits where attendance_record_id=v_record.id;
  end if;
end $$;

create or replace function public.review_overtime_request_in_advance(
  p_request_id uuid,p_decision text,p_overtime_limit_minutes integer,
  p_comp_time_limit_minutes integer,p_comment text
) returns void language plpgsql security definer set search_path=public as $$
declare
  v_request public.correction_requests;
  v_role text:=public.current_profile_role();
  v_org_id uuid:=public.current_profile_org_id();
  v_week_start date;
  v_week_total integer:=0;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected','more_info') then raise exception 'INVALID_DECISION'; end if;
  if p_decision<>'approved' and char_length(trim(coalesce(p_comment,'')))<2 then raise exception 'COMMENT_REQUIRED'; end if;
  select * into v_request from public.correction_requests where id=p_request_id for update;
  if not found or v_request.request_type<>'overtime' or v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_REVIEWABLE'; end if;
  if v_role<>'super_admin' and v_request.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if exists(select 1 from public.monthly_closings c where c.org_id=v_request.org_id
    and c.year=extract(year from v_request.target_date) and c.month=extract(month from v_request.target_date)
    and c.status='closed') and v_role<>'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  if p_decision='approved' then
    if p_overtime_limit_minutes<0 or p_overtime_limit_minutes>least(240,v_request.calculated_minutes)
      or (p_overtime_limit_minutes>0 and (p_overtime_limit_minutes<60 or p_overtime_limit_minutes%30<>0)) then raise exception 'INVALID_OVERTIME_LIMIT'; end if;
    if p_comp_time_limit_minutes<0 or p_comp_time_limit_minutes>least(240,v_request.calculated_minutes)
      or (p_comp_time_limit_minutes>0 and (p_comp_time_limit_minutes<60 or p_comp_time_limit_minutes%30<>0)) then raise exception 'INVALID_COMP_TIME_LIMIT'; end if;
    v_week_start:=date_trunc('week',v_request.target_date::timestamp)::date;
    select coalesce(sum(coalesce(nullif(r.overtime_approval_limit_minutes,0),r.approved_minutes)),0)::integer into v_week_total
    from public.correction_requests r where r.employee_id=v_request.employee_id and r.id<>v_request.id
      and r.request_type='overtime' and r.status='approved' and r.target_date between v_week_start and v_week_start+6;
    select v_week_total+coalesce(sum(a.approved_overtime_minutes),0)::integer into v_week_total
    from public.attendance_records a where a.employee_id=v_request.employee_id and a.deleted_at is null
      and a.overtime_status='approved' and a.work_date between v_week_start and v_week_start+6
      and not exists(select 1 from public.correction_requests r where r.attendance_record_id=a.id
        and r.request_type='overtime' and r.status='approved');
    select v_week_total+coalesce(sum(r.approved_minutes),0)::integer into v_week_total
    from public.correction_requests r where r.employee_id=v_request.employee_id
      and r.request_type='emergency_support' and r.status='approved' and r.target_date between v_week_start and v_week_start+6;
    v_week_total:=v_week_total+p_overtime_limit_minutes;
    perform public.consume_weekly_overtime_override(v_request.employee_id,v_request.target_date,v_week_total,'overtime',v_request.id);
  end if;

  update public.correction_requests set status=p_decision,reviewer_id=auth.uid(),
    reviewer_comment=coalesce(p_comment,''),reviewed_at=now(),approved_minutes=0,
    overtime_approval_limit_minutes=case when p_decision='approved' then p_overtime_limit_minutes else 0 end,
    comp_time_approval_limit_minutes=case when p_decision='approved' then p_comp_time_limit_minutes else 0 end,
    overtime_finalized_at=null where id=p_request_id;

  insert into public.attendance_audit_logs(attendance_record_id,employee_id,action_type,changed_field,
    before_value,after_value,reason,changed_by,changed_by_role,correction_request_id,org_id)
  values(v_request.attendance_record_id,v_request.employee_id,
    case when p_decision='approved' then 'request_approved' else 'correction_review' end,'overtime',
    v_request.status,jsonb_build_object('status',p_decision,'overtime_limit_minutes',p_overtime_limit_minutes,
      'comp_time_limit_minutes',p_comp_time_limit_minutes)::text,
    coalesce(nullif(trim(p_comment),''),v_request.reason),auth.uid(),v_role,v_request.id,v_request.org_id);

  if p_decision='approved' then perform public.finalize_preapproved_overtime(p_request_id); end if;
end $$;

create or replace function public.sync_overtime_request_to_attendance()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_used integer:=0;
begin
  if new.request_type<>'overtime' then return new; end if;
  if new.status='approved' then perform public.finalize_preapproved_overtime(new.id);
  elsif tg_op='UPDATE' and old.status='approved' and new.status<>'approved' then
    select coalesce(granted_minutes-remaining_minutes,0) into v_used
    from public.comp_time_credits where attendance_record_id=old.attendance_record_id;
    if v_used>0 then raise exception 'COMP_TIME_ALREADY_USED'; end if;
    delete from public.comp_time_credits where attendance_record_id=old.attendance_record_id;
    update public.attendance_records set overtime_status=case when recorded_overtime_minutes>0 then 'pending' else 'none' end,
      approved_overtime_minutes=0,comp_time_eligible_minutes=0,changed=true,updated_at=now()
    where employee_id=new.employee_id and work_date=new.target_date and deleted_at is null;
  end if;
  return new;
end $$;

create or replace function public.finalize_preapproved_overtime_after_clock_out()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if new.clock_out_at is null then return new; end if;
  select id into v_id from public.correction_requests where org_id=new.org_id
    and employee_id=new.employee_id and target_date=new.work_date
    and request_type='overtime' and status='approved' order by reviewed_at desc nulls last limit 1;
  if v_id is not null then perform public.finalize_preapproved_overtime(v_id); end if;
  return new;
end $$;

create or replace function public.enforce_weekly_override_on_overtime_approval()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_week_start date; v_total integer;
begin
  if new.overtime_status<>'approved'
     or (tg_op='UPDATE' and old.overtime_status='approved' and old.approved_overtime_minutes=new.approved_overtime_minutes) then return new; end if;
  if exists(select 1 from public.correction_requests r where r.attendance_record_id=new.id
    and r.request_type='overtime' and r.status='approved' and r.overtime_approval_limit_minutes>0) then return new; end if;
  v_week_start:=date_trunc('week',new.work_date::timestamp)::date;
  select coalesce(sum(approved_overtime_minutes),0)::integer into v_total from public.attendance_records
  where employee_id=new.employee_id and id<>new.id and deleted_at is null and overtime_status='approved'
    and work_date between v_week_start and v_week_start+6;
  select v_total+coalesce(sum(approved_minutes),0)::integer into v_total from public.correction_requests
  where employee_id=new.employee_id and request_type='emergency_support' and status='approved'
    and target_date between v_week_start and v_week_start+6;
  v_total:=v_total+coalesce(new.approved_overtime_minutes,0);
  perform public.consume_weekly_overtime_override(new.employee_id,new.work_date,v_total,'overtime',new.id);
  return new;
end $$;

drop trigger if exists finalize_preapproved_overtime_after_clock_out_trigger on public.attendance_records;
create trigger finalize_preapproved_overtime_after_clock_out_trigger
after insert or update of clock_out_at,recorded_overtime_minutes on public.attendance_records
for each row execute function public.finalize_preapproved_overtime_after_clock_out();

revoke all on function public.review_overtime_request_in_advance(uuid,text,integer,integer,text) from public,anon;
grant execute on function public.review_overtime_request_in_advance(uuid,text,integer,integer,text) to authenticated;
revoke all on function public.finalize_preapproved_overtime(uuid) from public,anon;
revoke all on function public.finalize_preapproved_overtime_after_clock_out() from public,anon;
notify pgrst,'reload schema';
commit;

select '시간외근무와 대휴 사전승인 한도 및 퇴근 확정 보완 완료' as result;

-- ============================================================================
-- supabase/repair_detailed_attendance_review_history.sql
-- ============================================================================
begin;

alter table public.attendance_records
  add column if not exists clock_in_reviewed_at timestamptz,
  add column if not exists clock_in_reviewed_by uuid references public.profiles(id) on delete restrict,
  add column if not exists clock_out_reviewed_at timestamptz,
  add column if not exists clock_out_reviewed_by uuid references public.profiles(id) on delete restrict,
  add column if not exists work_time_reviewed_at timestamptz,
  add column if not exists work_time_reviewed_by uuid references public.profiles(id) on delete restrict;

create or replace function public.derive_attendance_status(p_record public.attendance_records)
returns text language plpgsql stable security definer set search_path=public as $$
declare
  v_settings public.organization_settings;
  v_is_regular_workday boolean;
  v_expected_start time;
  v_elapsed_minutes integer;
  v_worked_minutes integer;
  v_approved_leave_minutes integer:=0;
  v_required_minutes integer:=480;
  v_leave_type text:='none';
begin
  select * into v_settings from public.organization_settings where org_id=p_record.org_id;
  if not found then raise exception 'ORGANIZATION_SETTINGS_REQUIRED'; end if;
  v_leave_type:=coalesce(to_jsonb(p_record)->>'leave_type','none');
  if p_record.clock_in_at is null then return case
    when v_leave_type in ('annual_leave','half_day','quarter_day','hourly_leave','sick_leave') then v_leave_type
    when p_record.attendance_status in ('business_trip','leave') then p_record.attendance_status else 'missing_in' end; end if;
  v_is_regular_workday:=extract(isodow from p_record.work_date)::smallint=any(v_settings.work_days)
    and not exists(select 1 from public.organization_holidays where org_id=p_record.org_id and holiday_date=p_record.work_date and is_paid_holiday);
  if p_record.clock_in_location_status in ('outside','low_accuracy','permission_denied','unavailable')
     and not coalesce(p_record.clock_in_ip_matched,false) and p_record.clock_in_reviewed_at is null then return 'admin_review'; end if;
  if p_record.clock_out_at is not null and p_record.clock_out_location_status in ('outside','low_accuracy','permission_denied','unavailable')
     and not coalesce(p_record.clock_out_ip_matched,false) and p_record.clock_out_reviewed_at is null then return 'admin_review'; end if;
  if not v_is_regular_workday then return 'holiday_work'; end if;

  select coalesce(count(*),0)::integer into v_approved_leave_minutes
  from generate_series(p_record.work_date+v_settings.default_start_time,p_record.work_date+v_settings.default_end_time-interval '1 minute',interval '1 minute') minute_point
  where not(minute_point::time>=time '12:00' and minute_point::time<time '13:00') and exists(
    select 1 from public.correction_requests request where request.org_id=p_record.org_id and request.employee_id=p_record.employee_id
      and request.status='approved' and request.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
      and p_record.work_date between request.target_date and coalesce(request.end_date,request.target_date)
      and minute_point::time>=case when p_record.work_date=request.target_date then coalesce(request.start_time,v_settings.default_start_time) else v_settings.default_start_time end
      and minute_point::time<case when p_record.work_date=coalesce(request.end_date,request.target_date) then coalesce(request.end_time,v_settings.default_end_time) else v_settings.default_end_time end);
  v_expected_start:=v_settings.default_start_time;
  select greatest(v_expected_start,coalesce(max(case when p_record.work_date=coalesce(request.end_date,request.target_date)
    then coalesce(request.end_time,v_settings.default_end_time) else v_settings.default_end_time end),v_expected_start)) into v_expected_start
  from public.correction_requests request where request.org_id=p_record.org_id and request.employee_id=p_record.employee_id
    and request.status='approved' and request.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
    and p_record.work_date between request.target_date and coalesce(request.end_date,request.target_date)
    and (case when p_record.work_date=request.target_date then coalesce(request.start_time,v_settings.default_start_time) else v_settings.default_start_time end)<=v_settings.default_start_time;
  if (p_record.clock_in_at at time zone 'Asia/Seoul')::time>v_expected_start+make_interval(mins=>v_settings.late_grace_minutes)
     and p_record.work_time_reviewed_at is null then return 'late'; end if;
  if p_record.clock_out_at is null then return 'working'; end if;
  v_required_minutes:=greatest(0,480-v_approved_leave_minutes);
  v_elapsed_minutes:=greatest(0,floor(extract(epoch from(p_record.clock_out_at-p_record.clock_in_at))/60)::integer);
  v_worked_minutes:=greatest(0,v_elapsed_minutes-case when (p_record.clock_in_at at time zone 'Asia/Seoul')::time<time '13:00'
    and (p_record.clock_out_at at time zone 'Asia/Seoul')::time>time '12:00' then least(60,floor(extract(epoch from(
      least(p_record.clock_out_at,(p_record.work_date+time '13:00') at time zone 'Asia/Seoul')-
      greatest(p_record.clock_in_at,(p_record.work_date+time '12:00') at time zone 'Asia/Seoul')))/60)::integer) else 0 end);
  return case when v_worked_minutes<v_required_minutes and p_record.work_time_reviewed_at is null then 'admin_review' else 'normal' end;
end $$;

create or replace function public.recalculate_attendance_status_on_time_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if old.clock_in_at is distinct from new.clock_in_at then
    new.clock_in_reviewed_at:=null; new.clock_in_reviewed_by:=null;
    new.work_time_reviewed_at:=null; new.work_time_reviewed_by:=null;
  end if;
  if old.clock_out_at is distinct from new.clock_out_at then
    new.clock_out_reviewed_at:=null; new.clock_out_reviewed_by:=null;
    new.work_time_reviewed_at:=null; new.work_time_reviewed_by:=null;
  end if;
  new.attendance_status:=public.derive_attendance_status(new);
  return new;
end $$;

create or replace function public.admin_confirm_attendance_record(p_record_id uuid,p_comment text)
returns void language plpgsql security definer set search_path=public as $$
declare
  v_record public.attendance_records;
  v_role text:=public.current_profile_role();
  v_org_id uuid:=public.current_profile_org_id();
  v_items text[]:=array[]::text[];
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_comment,'')))<2 then raise exception 'COMMENT_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id=p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_role<>'super_admin' and v_record.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if v_record.is_closed and v_role<>'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if v_record.attendance_status not in ('admin_review','location_review','field','education','late') then raise exception 'RECORD_NOT_REVIEWABLE'; end if;
  if v_record.clock_in_location_status in ('outside','low_accuracy','permission_denied','unavailable') and not coalesce(v_record.clock_in_ip_matched,false) then
    v_items:=array_append(v_items,'직출 또는 출근 위치'); end if;
  if v_record.clock_out_at is not null and v_record.clock_out_location_status in ('outside','low_accuracy','permission_denied','unavailable') and not coalesce(v_record.clock_out_ip_matched,false) then
    v_items:=array_append(v_items,'직퇴 또는 퇴근 위치'); end if;
  if v_record.attendance_status in ('admin_review','late') and cardinality(v_items)=0 then v_items:=array_append(v_items,'지각 또는 근무시간'); end if;
  update public.attendance_records set
    clock_in_reviewed_at=case when '직출 또는 출근 위치'=any(v_items) then now() else clock_in_reviewed_at end,
    clock_in_reviewed_by=case when '직출 또는 출근 위치'=any(v_items) then auth.uid() else clock_in_reviewed_by end,
    clock_out_reviewed_at=case when '직퇴 또는 퇴근 위치'=any(v_items) then now() else clock_out_reviewed_at end,
    clock_out_reviewed_by=case when '직퇴 또는 퇴근 위치'=any(v_items) then auth.uid() else clock_out_reviewed_by end,
    work_time_reviewed_at=case when '지각 또는 근무시간'=any(v_items) then now() else work_time_reviewed_at end,
    work_time_reviewed_by=case when '지각 또는 근무시간'=any(v_items) then auth.uid() else work_time_reviewed_by end,
    changed=true,updated_at=now() where id=p_record_id;
  update public.attendance_records record set attendance_status=public.derive_attendance_status(record) where id=p_record_id;
  insert into public.attendance_audit_logs(attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,reason,changed_by,changed_by_role,org_id)
  values(v_record.id,v_record.employee_id,'admin_review_completed','attendance_review',v_record.attendance_status,
    jsonb_build_object('status',(select attendance_status from public.attendance_records where id=p_record_id),'confirmed_items',v_items)::text,
    trim(p_comment),auth.uid(),v_role,v_record.org_id);
end $$;

revoke all on function public.admin_confirm_attendance_record(uuid,text) from public,anon;
grant execute on function public.admin_confirm_attendance_record(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;

select '관리자 확인 항목 분리와 변경이력 상세화 완료' as result;
