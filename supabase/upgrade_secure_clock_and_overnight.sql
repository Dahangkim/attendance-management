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
  v_policy public.organization_work_policies;
  v_shift public.work_shift_templates;
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
  select p.* into v_user from public.profiles p
  join public.organizations o on o.id = p.org_id and o.is_active = true
  where p.id = p_employee_id and p.is_active = true;
  if not found then raise exception 'INACTIVE_OR_UNKNOWN_USER'; end if;
  select * into v_workplace from public.workplaces where org_id = v_user.org_id and is_active order by created_at limit 1;
  if not found then raise exception 'WORKPLACE_NOT_CONFIGURED'; end if;
  select * into v_settings from public.organization_settings where org_id = v_user.org_id;
  if not found then raise exception 'ORGANIZATION_SETTINGS_NOT_CONFIGURED'; end if;
  select * into v_policy from public.organization_work_policies where org_id = v_user.org_id;
  if not found then raise exception 'WORK_POLICY_NOT_CONFIGURED'; end if;

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
  if not v_policy.require_location and not v_policy.require_office_ip then v_location_status := 'inside'; end if;
  if v_policy.require_office_ip and not v_ip_matched then v_location_status := 'outside'; end if;
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
      and org_id = v_user.org_id
      and work_date between v_today - 2 and v_today
      and clock_in_at >= v_now - make_interval(hours => v_policy.max_open_shift_hours)
    order by clock_in_at desc
    limit 1
    for update;
    if not found then raise exception 'CLOCK_IN_REQUIRED'; end if;
    v_work_date := v_record.work_date;
  else
    v_work_date := v_today;
    select st.* into v_shift
    from public.employee_shift_assignments esa
    join public.work_shift_templates st on st.id = esa.shift_template_id and st.org_id = esa.org_id
    where esa.org_id = v_user.org_id and esa.employee_id = p_employee_id and esa.work_date = v_work_date and st.is_active = true;
  end if;

  if exists (
    select 1 from public.monthly_closings
    where org_id = v_user.org_id
      and year = extract(year from v_work_date)
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
      when (v_now at time zone 'Asia/Seoul')::time > coalesce(v_shift.start_time, v_settings.default_start_time) + make_interval(mins => coalesce(v_shift.late_grace_minutes, v_settings.late_grace_minutes)) then 'late'
      else 'working'
    end;
    insert into public.attendance_records (
      employee_id, work_date, work_type, clock_in_at, clock_in_accuracy, clock_in_distance,
      clock_in_location_status, clock_in_ip_address, clock_in_ip_matched, attendance_status,
      note, raw_overtime_minutes, recorded_overtime_minutes, overtime_status,
      approved_overtime_minutes, leave_type, org_id, shift_template_id, scheduled_start_at, scheduled_end_at
    ) values (
      p_employee_id, v_work_date, 'office', v_now, p_accuracy, v_distance,
      v_location_status, nullif(trim(p_ip_address), ''), v_ip_matched, v_attendance_status,
      v_record_note, 0, 0, 'none', 0, 'none', v_user.org_id, v_shift.id,
      case when v_shift.id is null then null else (v_work_date + v_shift.start_time) at time zone 'Asia/Seoul' end,
      case when v_shift.id is null then null else (v_work_date + v_shift.end_time + case when v_shift.crosses_midnight then interval '1 day' else interval '0 day' end) at time zone 'Asia/Seoul' end
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
      shift_template_id = excluded.shift_template_id,
      scheduled_start_at = excluded.scheduled_start_at, scheduled_end_at = excluded.scheduled_end_at,
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
