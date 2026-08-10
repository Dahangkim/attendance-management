begin;

-- 평일 시간외근무 신청은 기관 정규 근무시간 이전과 이후만 합산합니다.
-- 주말과 기관 휴일은 입력한 전체 근무시간을 신청시간으로 인정합니다.
create or replace function public.calculate_overtime_request_minutes(
  p_org_id uuid,
  p_work_date date,
  p_start_time time,
  p_end_time time
) returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_settings public.organization_settings;
  v_total integer;
  v_before_work integer := 0;
  v_after_work integer := 0;
  v_is_holiday boolean;
begin
  if p_start_time is null or p_end_time is null or p_end_time <= p_start_time then
    raise exception 'INVALID_OVERTIME_RANGE';
  end if;

  select * into v_settings
  from public.organization_settings
  where org_id = p_org_id;
  if not found then raise exception 'ORGANIZATION_SETTINGS_REQUIRED'; end if;

  v_total := floor(extract(epoch from (p_end_time - p_start_time)) / 60)::integer;
  v_is_holiday := extract(isodow from p_work_date)::smallint <> all(v_settings.work_days)
    or exists (
      select 1 from public.organization_holidays
      where org_id = p_org_id and holiday_date = p_work_date
    );
  if v_is_holiday then return v_total; end if;

  v_before_work := greatest(
    0,
    floor(extract(epoch from (least(p_end_time,v_settings.default_start_time) - p_start_time)) / 60)::integer
  );
  v_after_work := greatest(
    0,
    floor(extract(epoch from (p_end_time - greatest(p_start_time,v_settings.default_end_time))) / 60)::integer
  );
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
    new.calculated_minutes := public.calculate_overtime_request_minutes(
      new.org_id,new.target_date,new.start_time,new.end_time
    );
    if new.calculated_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;
    new.requested_value := new.calculated_minutes::text;
  elsif new.request_type in ('annual_leave','comp_time','special_leave','sick_leave','business_trip','other_leave') then
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

revoke all on function public.calculate_overtime_request_minutes(uuid,date,time,time) from public,anon,authenticated;

notify pgrst, 'reload schema';

commit;

select '시간외근무 신청 정규 근무시간 제외 계산 보완 완료' as result;
