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
