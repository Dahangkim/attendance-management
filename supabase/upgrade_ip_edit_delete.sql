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
