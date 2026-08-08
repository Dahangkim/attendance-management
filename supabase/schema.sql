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
