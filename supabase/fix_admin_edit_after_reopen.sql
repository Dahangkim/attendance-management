begin;

-- 일부 기존 기관 데이터베이스에 빠진 시간외근무 인정단위 계산 함수를 함께 복구합니다.
create or replace function public.recognized_overtime_minutes(p_raw_minutes integer)
returns integer
language sql immutable
as $$
  select case
    when coalesce(p_raw_minutes,0) < 60 then 0
    else least(240,60 + ceil((p_raw_minutes - 60) / 30.0)::integer * 30)
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
