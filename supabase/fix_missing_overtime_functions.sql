begin;

-- 1시간을 모두 채운 뒤 30분 구간을 1분이라도 넘으면 다음 30분까지 인정하며,
-- 하루 최대 인정시간은 4시간입니다.
create or replace function public.recognized_overtime_minutes(
  p_raw_minutes integer
) returns integer
language sql
immutable
as $$
  select case
    when coalesce(p_raw_minutes,0) < 60 then 0
    else least(240,60 + ceil((p_raw_minutes - 60) / 30.0)::integer * 30)
  end
$$;

-- 평일에는 실제 유급근무 8시간을 넘은 분량을 계산하고,
-- 주말과 기관휴일에는 실제 유급근무 전체를 시간외 원시간으로 계산합니다.
create or replace function public.calculate_raw_overtime_minutes(
  p_work_date date,
  p_clock_in timestamptz,
  p_clock_out timestamptz
) returns integer
language sql
stable
set search_path = public
as $function$
  with settings as (
    select work_days,break_minutes
    from public.organization_settings
    where id = true
  ), calculated as (
    select
      greatest(
        0,
        floor(extract(epoch from (p_clock_out - p_clock_in)) / 60)::integer
      ) as elapsed_minutes,
      work_days,
      break_minutes
    from settings
  ), worked as (
    select
      greatest(
        0,
        elapsed_minutes
          - case when elapsed_minutes >= 360 then break_minutes else 0 end
      ) as worked_minutes,
      work_days
    from calculated
  )
  select case
    when p_clock_in is null or p_clock_out is null or p_clock_out < p_clock_in then 0
    else coalesce((
      select case
        when extract(isodow from p_work_date)::smallint <> all(work_days)
          or exists (
            select 1 from public.holidays where holiday_date = p_work_date
          )
        then worked_minutes
        else greatest(0,worked_minutes - 480)
      end
      from worked
    ),0)
  end
$function$;

alter function public.recognized_overtime_minutes(integer) owner to postgres;
alter function public.calculate_raw_overtime_minutes(date,timestamptz,timestamptz) owner to postgres;

revoke all on function public.recognized_overtime_minutes(integer) from public, anon;
revoke all on function public.calculate_raw_overtime_minutes(date,timestamptz,timestamptz) from public, anon;
grant execute on function public.recognized_overtime_minutes(integer) to authenticated, service_role;
grant execute on function public.calculate_raw_overtime_minutes(date,timestamptz,timestamptz) to authenticated, service_role;

notify pgrst, 'reload schema';
commit;

select
  to_regprocedure('public.calculate_raw_overtime_minutes(date,timestamptz,timestamptz)') is not null
    as raw_overtime_function_exists,
  to_regprocedure('public.recognized_overtime_minutes(integer)') is not null
    as recognized_overtime_function_exists;
