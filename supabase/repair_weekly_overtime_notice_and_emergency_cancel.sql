begin;

-- 휴일은 실제 근무 전체를 기록하고 승인할 수 있도록 분 한도를 넓힙니다.
alter table public.attendance_records drop constraint if exists attendance_records_overtime_minutes_check;
alter table public.attendance_records
  add constraint attendance_records_overtime_minutes_check
  check (raw_overtime_minutes between 0 and 1440 and recorded_overtime_minutes between 0 and 1440 and approved_overtime_minutes between 0 and 1440) not valid;

create or replace function public.recalculate_overtime_after_attendance_change()
returns trigger language plpgsql set search_path = public as $$
declare
  v_settings public.organization_settings;
  v_policy public.organization_work_policies;
  v_worked integer := 0; v_lunch integer := 0; v_leave integer := 0;
  v_actual integer := 0; v_raw integer := 0; v_recognized integer := 0;
  v_lunch_from timestamptz; v_lunch_until timestamptz;
  v_is_holiday boolean := false; v_should_reopen boolean := false;
begin
  select * into v_settings from public.organization_settings where org_id = new.org_id;
  if not found then raise exception 'ORGANIZATION_SETTINGS_REQUIRED'; end if;
  select * into v_policy from public.organization_work_policies where org_id = new.org_id;
  if new.clock_in_at is not null and new.clock_out_at is not null and new.clock_out_at > new.clock_in_at then
    v_worked := floor(extract(epoch from (new.clock_out_at - new.clock_in_at)) / 60)::integer;
    v_lunch_from := (new.work_date + time '12:00') at time zone 'Asia/Seoul';
    v_lunch_until := (new.work_date + time '13:00') at time zone 'Asia/Seoul';
    if least(new.clock_out_at,v_lunch_until) > greatest(new.clock_in_at,v_lunch_from) then
      v_lunch := floor(extract(epoch from (least(new.clock_out_at,v_lunch_until) - greatest(new.clock_in_at,v_lunch_from))) / 60)::integer;
    end if;
    v_leave := public.approved_leave_minutes_during_attendance(new.employee_id,new.clock_in_at,new.clock_out_at);
    v_is_holiday := extract(isodow from new.work_date)::smallint <> all(v_settings.work_days)
      or exists (select 1 from public.organization_holidays where org_id = new.org_id and holiday_date = new.work_date);
    -- 휴일은 출퇴근 전체 시간을 검토 대상으로 남깁니다. 휴게시간 포함 여부는
    -- 관리자가 승인시간을 입력할 때 실제 운영 기준에 맞게 결정합니다.
    v_actual := greatest(0,v_worked - case when v_is_holiday then 0 else v_lunch end - v_leave);
    v_raw := case when v_is_holiday then v_actual else greatest(0,v_actual - 480) end;
    v_recognized := case
      when v_is_holiday and coalesce(v_policy.holiday_work_counts_as_overtime,true)
        then least(1440,ceil(v_raw::numeric / coalesce(v_policy.overtime_rounding_minutes,30))::integer * coalesce(v_policy.overtime_rounding_minutes,30))
      when v_is_holiday then 0
      else public.recognized_overtime_minutes(v_raw)
    end;
  end if;
  v_should_reopen := tg_op = 'INSERT' or old.clock_in_at is distinct from new.clock_in_at
    or old.clock_out_at is distinct from new.clock_out_at or new.overtime_status = 'pending';
  new.raw_overtime_minutes := v_raw;
  new.recorded_overtime_minutes := v_recognized;
  if v_recognized > 0 and v_should_reopen then
    new.overtime_status := 'pending'; new.approved_overtime_minutes := 0; new.comp_time_eligible_minutes := 0;
  elsif v_recognized = 0 then
    new.overtime_status := 'none'; new.approved_overtime_minutes := 0; new.comp_time_eligible_minutes := 0;
  end if;
  return new;
end $$;

-- 주 12시간은 승인 차단 조건이 아니라 관리자 확인용 안내 기준으로 사용합니다.
-- 기존 함수 본문에 남은 차단 구문만 제거하며, 일일 승인 한도 등 다른 검증은 유지합니다.
do $$
declare
  item record;
  original_definition text;
  repaired_definition text;
begin
  for item in
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('admin_review_overtime','review_correction_request')
  loop
    original_definition := pg_get_functiondef(item.oid);
    repaired_definition := original_definition;
    repaired_definition := replace(repaired_definition,
      'if v_week_total + p_approved_minutes > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;', '');
    repaired_definition := replace(repaired_definition,
      'if v_week_total + p_approved_minutes + p_comp_time_minutes > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;', '');
    repaired_definition := replace(repaired_definition,
      'if v_week_total + v_approved > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;', '');
    repaired_definition := replace(repaired_definition,
      'if p_approved_minutes not in (60,90,120,150,180,210,240)
       or p_approved_minutes > v_record.recorded_overtime_minutes then
      raise exception ''INVALID_OVERTIME_MINUTES'';
    end if;',
      'if p_approved_minutes < 60 or p_approved_minutes % 30 <> 0
       or p_approved_minutes > v_record.recorded_overtime_minutes then
      raise exception ''INVALID_OVERTIME_MINUTES'';
    end if;');
    if repaired_definition <> original_definition then
      execute repaired_definition;
    end if;
  end loop;
end $$;

create or replace function public.admin_cancel_emergency_support_work(
  p_request_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;

  select * into v_request
  from public.correction_requests
  where id = p_request_id and request_type = 'emergency_support'
  for update;
  if not found then raise exception 'EMERGENCY_SUPPORT_NOT_FOUND'; end if;
  if v_request.status <> 'approved' then raise exception 'APPROVED_EMERGENCY_SUPPORT_REQUIRED'; end if;
  if v_role <> 'super_admin' and v_request.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if exists (
    select 1 from public.monthly_closings
    where org_id = v_request.org_id
      and year = extract(year from v_request.target_date)
      and month = extract(month from v_request.target_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  update public.correction_requests
  set status = 'cancelled', approved_minutes = 0,
      reviewer_id = auth.uid(), reviewer_comment = '관리자 승인 취소: ' || trim(p_reason),
      reviewed_at = now()
  where id = p_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role,correction_request_id,org_id
  ) values (
    v_request.attendance_record_id,v_request.employee_id,'emergency_support_approval_cancelled','emergency_support',
    jsonb_build_object('status',v_request.status,'minutes',v_request.approved_minutes,'start_date',v_request.target_date,'end_date',v_request.end_date,'start_time',v_request.start_time,'end_time',v_request.end_time)::text,
    jsonb_build_object('status','cancelled','minutes',0)::text,
    trim(p_reason),auth.uid(),v_role,v_request.id,v_request.org_id
  );
end $$;

revoke all on function public.admin_cancel_emergency_support_work(uuid,text) from public,anon;
grant execute on function public.admin_cancel_emergency_support_work(uuid,text) to authenticated;

notify pgrst, 'reload schema';
commit;

select '주간 시간외 안내 전환과 승인 긴급지원 취소 보완 완료' as result;
