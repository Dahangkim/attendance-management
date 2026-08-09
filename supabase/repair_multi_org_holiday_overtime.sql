begin;

alter table public.organization_work_policies
  add column if not exists holiday_work_counts_as_overtime boolean not null default true;

-- 기관별 근무일 설정을 사용해 휴일의 실제 근무 전체를 시간외근무로 계산합니다.
create or replace function public.recalculate_overtime_after_attendance_change()
returns trigger language plpgsql set search_path = public as $$
declare
  v_settings public.organization_settings;
  v_policy public.organization_work_policies;
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
  select * into v_settings from public.organization_settings where org_id = new.org_id;
  if not found then raise exception 'ORGANIZATION_SETTINGS_REQUIRED'; end if;
  select * into v_policy from public.organization_work_policies where org_id = new.org_id;
  if new.clock_in_at is not null and new.clock_out_at is not null and new.clock_out_at > new.clock_in_at then
    v_worked := floor(extract(epoch from (new.clock_out_at - new.clock_in_at)) / 60)::integer;
    v_lunch_from := (new.work_date + time '12:00') at time zone 'Asia/Seoul';
    v_lunch_until := (new.work_date + time '13:00') at time zone 'Asia/Seoul';
    if least(new.clock_out_at, v_lunch_until) > greatest(new.clock_in_at, v_lunch_from) then
      v_lunch := floor(extract(epoch from (least(new.clock_out_at, v_lunch_until) - greatest(new.clock_in_at, v_lunch_from))) / 60)::integer;
    end if;
    v_leave := public.approved_leave_minutes_during_attendance(new.employee_id,new.clock_in_at,new.clock_out_at);
    v_actual := greatest(0,v_worked - v_lunch - v_leave);
    v_is_holiday := extract(isodow from new.work_date)::smallint <> all(v_settings.work_days)
      or exists (select 1 from public.organization_holidays where org_id = new.org_id and holiday_date = new.work_date);
    v_raw := case when v_is_holiday then v_actual else greatest(0,v_actual - 480) end;
    v_recognized := case
      when v_is_holiday and coalesce(v_policy.holiday_work_counts_as_overtime,true)
        then least(240,ceil(v_raw::numeric / coalesce(v_policy.overtime_rounding_minutes,30))::integer * coalesce(v_policy.overtime_rounding_minutes,30))
      when v_is_holiday then 0
      else public.recognized_overtime_minutes(v_raw)
    end;
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

-- 시간 수정 후 상태 판정도 해당 기관의 근무일과 휴일을 사용합니다.
create or replace function public.derive_attendance_status(p_record public.attendance_records)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_settings public.organization_settings;
  v_is_regular_workday boolean;
  v_location_review boolean;
  v_elapsed_minutes integer;
  v_worked_minutes integer;
  v_required_minutes integer := 480;
  v_leave_type text := 'none';
begin
  select * into v_settings from public.organization_settings where org_id = p_record.org_id;
  if not found then raise exception 'ORGANIZATION_SETTINGS_REQUIRED'; end if;
  v_leave_type := coalesce(to_jsonb(p_record)->>'leave_type','none');
  if p_record.clock_in_at is null then
    return case when v_leave_type in ('annual_leave','half_day','quarter_day','hourly_leave','sick_leave') then v_leave_type when p_record.attendance_status in ('business_trip','leave') then p_record.attendance_status else 'missing_in' end;
  end if;
  v_is_regular_workday := extract(isodow from p_record.work_date)::smallint = any(v_settings.work_days)
    and not exists (select 1 from public.organization_holidays where org_id = p_record.org_id and holiday_date = p_record.work_date and is_paid_holiday);
  v_location_review := (p_record.clock_in_location_status in ('outside','low_accuracy') and not coalesce(p_record.clock_in_ip_matched,false))
    or (p_record.clock_out_at is not null and p_record.clock_out_location_status in ('outside','low_accuracy') and not coalesce(p_record.clock_out_ip_matched,false));
  if v_location_review then return 'admin_review'; end if;
  if not v_is_regular_workday then return 'holiday_work'; end if;
  if (p_record.clock_in_at at time zone 'Asia/Seoul')::time > v_settings.default_start_time + make_interval(mins => v_settings.late_grace_minutes) then return 'late'; end if;
  if p_record.clock_out_at is null then return 'working'; end if;
  v_required_minutes := case v_leave_type when 'half_day' then 240 when 'quarter_day' then 360 when 'hourly_leave' then 420 when 'annual_leave' then 0 when 'sick_leave' then 0 else 480 end;
  v_elapsed_minutes := greatest(0,floor(extract(epoch from (p_record.clock_out_at - p_record.clock_in_at)) / 60)::integer);
  v_worked_minutes := greatest(0,v_elapsed_minutes - case when v_elapsed_minutes >= 360 then v_settings.break_minutes else 0 end);
  return case when v_worked_minutes < v_required_minutes then 'admin_review' else 'normal' end;
end $$;

-- 이미 저장된 기록도 기관별 조건으로 다시 계산합니다. 승인 완료 기록은 승인값을 유지합니다.
update public.attendance_records
set clock_out_at = clock_out_at,
    overtime_status = case when overtime_status = 'approved' then 'approved' else 'pending' end
where clock_in_at is not null and clock_out_at is not null and deleted_at is null;

notify pgrst, 'reload schema';
commit;
