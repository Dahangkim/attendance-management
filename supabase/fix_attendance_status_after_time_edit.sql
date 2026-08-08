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
