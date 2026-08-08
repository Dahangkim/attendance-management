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
alter table public.attendance_records add constraint attendance_records_overtime_minutes_check check (raw_overtime_minutes between 0 and 1440 and recorded_overtime_minutes between 0 and 240 and approved_overtime_minutes between 0 and 240) not valid;
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
  select case when coalesce(p_raw_minutes,0) < 60 then 0 else least(240, 60 + ceil((p_raw_minutes - 60) / 30.0)::integer * 30) end
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
