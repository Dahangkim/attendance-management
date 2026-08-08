begin;

-- 종일 외부교육을 출퇴근 기록 예외로 보존합니다.
do $$
declare v_constraint record;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.attendance_exceptions'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%exception_type%'
  loop
    execute format('alter table public.attendance_exceptions drop constraint %I', v_constraint.conname);
  end loop;
end $$;

alter table public.attendance_exceptions
  add constraint attendance_exceptions_exception_type_check
  check (exception_type in (
    'business_trip','external_training','approved_other',
    'annual_leave','comp_time','sick_leave','other_leave'
  )) not valid;

-- 여러 직원의 근무기록을 한 번에 만들고 기존 기록은 이름과 함께 제외합니다.
create or replace function public.admin_create_attendance_records(
  p_employee_ids uuid[],
  p_work_date date,
  p_clock_in_time time,
  p_clock_out_time time,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_employee_id uuid;
  v_employee_name text;
  v_created integer := 0;
  v_skipped_names text[] := array[]::text[];
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if coalesce(array_length(p_employee_ids,1),0) = 0 then raise exception 'EMPLOYEE_REQUIRED'; end if;
  if p_work_date is null or p_clock_in_time is null or p_clock_out_time is null then raise exception 'REQUIRED_VALUE_MISSING'; end if;
  if p_clock_out_time <= p_clock_in_time then raise exception 'INVALID_TIME_RANGE'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;

  foreach v_employee_id in array p_employee_ids loop
    select name into v_employee_name
    from public.profiles
    where id = v_employee_id and role = 'employee' and is_active = true;

    if not found then
      v_skipped_names := array_append(v_skipped_names, '비활성 또는 미확인 직원');
    elsif exists (
      select 1 from public.attendance_records
      where employee_id = v_employee_id and work_date = p_work_date and deleted_at is null
    ) then
      v_skipped_names := array_append(v_skipped_names, v_employee_name);
    else
      perform public.admin_create_attendance_record(
        v_employee_id, p_work_date, p_clock_in_time, p_clock_out_time, p_reason
      );
      v_created := v_created + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'created_count', v_created,
    'skipped_count', coalesce(array_length(v_skipped_names,1),0),
    'skipped_names', to_jsonb(v_skipped_names)
  );
end $$;

-- 출장, 외부교육, 종일 휴가를 여러 직원에게 일괄 등록합니다.
create or replace function public.admin_create_attendance_exceptions(
  p_employee_ids uuid[],
  p_start_date date,
  p_end_date date,
  p_exception_type text,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_employee_id uuid;
  v_employee_name text;
  v_created integer := 0;
  v_skipped_names text[] := array[]::text[];
  v_id uuid;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if coalesce(array_length(p_employee_ids,1),0) = 0 then raise exception 'EMPLOYEE_REQUIRED'; end if;
  if p_end_date < p_start_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_exception_type not in ('business_trip','external_training','approved_other','annual_leave','comp_time','sick_leave','other_leave') then raise exception 'INVALID_EXCEPTION_TYPE'; end if;
  if p_exception_type in ('external_training','other_leave') and char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;

  foreach v_employee_id in array p_employee_ids loop
    select name into v_employee_name
    from public.profiles
    where id = v_employee_id and role = 'employee' and is_active = true;

    if not found then
      v_skipped_names := array_append(v_skipped_names, '비활성 또는 미확인 직원');
    elsif exists (
      select 1 from public.attendance_exceptions
      where employee_id = v_employee_id
        and cancelled_at is null
        and start_date <= p_end_date
        and end_date >= p_start_date
    ) then
      v_skipped_names := array_append(v_skipped_names, v_employee_name);
    elsif p_exception_type = 'external_training' then
      insert into public.attendance_exceptions (
        employee_id, start_date, end_date, exception_type, reason, approved_by
      ) values (
        v_employee_id, p_start_date, p_end_date, p_exception_type,
        trim(coalesce(p_reason,'')), auth.uid()
      ) returning id into v_id;

      insert into public.attendance_audit_logs (
        employee_id, action_type, changed_field, before_value, after_value,
        reason, changed_by, changed_by_role
      ) values (
        v_employee_id, 'exception_create', 'attendance_exception', '',
        jsonb_build_object(
          'id',v_id,'start_date',p_start_date,'end_date',p_end_date,
          'exception_type',p_exception_type
        )::text,
        trim(coalesce(p_reason,'')), auth.uid(), v_role
      );
      v_created := v_created + 1;
    else
      perform public.admin_create_attendance_exception(
        v_employee_id, p_start_date, p_end_date, p_exception_type, p_reason
      );
      v_created := v_created + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'created_count', v_created,
    'skipped_count', coalesce(array_length(v_skipped_names,1),0),
    'skipped_names', to_jsonb(v_skipped_names)
  );
end $$;

-- 출퇴근 사이에 승인된 휴가가 있으면 점심시간과 겹치지 않는 분만 실제 근무에서 제외합니다.
create or replace function public.approved_leave_minutes_during_attendance(
  p_employee_id uuid,
  p_clock_in timestamptz,
  p_clock_out timestamptz
) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(count(*),0)::integer
  from generate_series(
    date_trunc('minute', p_clock_in at time zone 'Asia/Seoul'),
    date_trunc('minute', p_clock_out at time zone 'Asia/Seoul') - interval '1 minute',
    interval '1 minute'
  ) as minute_point
  where minute_point::time >= time '09:00'
    and minute_point::time < time '18:00'
    and not (minute_point::time >= time '12:00' and minute_point::time < time '13:00')
    and exists (
      select 1
      from public.correction_requests request
      where request.employee_id = p_employee_id
        and request.status = 'approved'
        and request.request_type in ('annual_leave','comp_time','sick_leave','other_leave')
        and minute_point::date between request.target_date and coalesce(request.end_date,request.target_date)
        and minute_point::time >= case
          when minute_point::date = request.target_date then coalesce(request.start_time,time '09:00')
          else time '09:00'
        end
        and minute_point::time < case
          when minute_point::date = coalesce(request.end_date,request.target_date) then coalesce(request.end_time,time '18:00')
          else time '18:00'
        end
    )
$$;

-- 실제 근무시간은 출퇴근 간격에서 점심시간과 승인 휴가시간을 제외해 계산합니다.
create or replace function public.recalculate_overtime_after_attendance_change()
returns trigger language plpgsql set search_path = public as $$
declare
  v_settings public.organization_settings;
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
  select * into v_settings from public.organization_settings where id = true;
  if new.clock_in_at is not null and new.clock_out_at is not null and new.clock_out_at > new.clock_in_at then
    v_worked := floor(extract(epoch from (new.clock_out_at - new.clock_in_at)) / 60)::integer;
    v_lunch_from := (new.work_date + time '12:00') at time zone 'Asia/Seoul';
    v_lunch_until := (new.work_date + time '13:00') at time zone 'Asia/Seoul';
    if least(new.clock_out_at, v_lunch_until) > greatest(new.clock_in_at, v_lunch_from) then
      v_lunch := floor(extract(epoch from (least(new.clock_out_at, v_lunch_until) - greatest(new.clock_in_at, v_lunch_from))) / 60)::integer;
    end if;
    v_leave := public.approved_leave_minutes_during_attendance(new.employee_id,new.clock_in_at,new.clock_out_at);
    v_actual := greatest(0, v_worked - v_lunch - v_leave);
    v_is_holiday := extract(isodow from new.work_date)::smallint <> all(v_settings.work_days)
      or exists (select 1 from public.holidays where holiday_date = new.work_date);
    v_raw := case when v_is_holiday then v_actual else greatest(0, v_actual - 480) end;
    v_recognized := public.recognized_overtime_minutes(v_raw);
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

drop trigger if exists attendance_refresh_overtime on public.attendance_records;
drop trigger if exists recalculate_overtime_after_attendance_change_trigger on public.attendance_records;
create trigger recalculate_overtime_after_attendance_change_trigger
before insert or update of clock_in_at,clock_out_at
on public.attendance_records
for each row execute function public.recalculate_overtime_after_attendance_change();

-- 휴가 승인, 재검토, 시간 변경 시 연결된 실제 근무시간을 다시 계산합니다.
create or replace function public.recalculate_attendance_after_leave_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.request_type not in ('annual_leave','comp_time','sick_leave','other_leave') then return new; end if;
  if tg_op = 'UPDATE'
     and old.status is not distinct from new.status
     and old.target_date is not distinct from new.target_date
     and old.end_date is not distinct from new.end_date
     and old.start_time is not distinct from new.start_time
     and old.end_time is not distinct from new.end_time then
    return new;
  end if;

  update public.comp_time_credits credit
  set remaining_minutes = 0,
      reason = trim(concat_ws(E'\n',credit.reason,'휴가 반영으로 실제 근무시간 재검토'))
  where credit.attendance_record_id in (
    select record.id
    from public.attendance_records record
    where record.employee_id = new.employee_id
      and record.work_date between new.target_date and coalesce(new.end_date,new.target_date)
      and record.deleted_at is null
  ) and credit.remaining_minutes > 0;

  update public.attendance_records record
  set overtime_status = 'pending',
      approved_overtime_minutes = 0,
      comp_time_eligible_minutes = 0,
      clock_out_at = record.clock_out_at,
      changed = true,
      updated_at = now()
  where record.employee_id = new.employee_id
    and record.work_date between new.target_date and coalesce(new.end_date,new.target_date)
    and record.deleted_at is null
    and record.clock_in_at is not null
    and record.clock_out_at is not null;
  return new;
end $$;

drop trigger if exists recalculate_attendance_after_leave_request_trigger on public.correction_requests;
create trigger recalculate_attendance_after_leave_request_trigger
after insert or update of status,target_date,end_date,start_time,end_time
on public.correction_requests
for each row execute function public.recalculate_attendance_after_leave_request();

-- 직원의 시간외 신청 승인값을 실제 퇴근기록과 신청시간 중 작은 값으로 확정합니다.
create or replace function public.sync_overtime_request_to_attendance()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_final integer := 0;
begin
  if new.request_type <> 'overtime' then return new; end if;

  if new.status = 'approved' then
    select * into v_record
    from public.attendance_records
    where deleted_at is null
      and employee_id = new.employee_id
      and work_date = new.target_date
    for update;
    if not found or v_record.clock_out_at is null or coalesce(v_record.recorded_overtime_minutes,0) <= 0 then
      raise exception 'ACTUAL_OVERTIME_REQUIRED';
    end if;
    -- 관리자가 실제 인정시간을 줄여 승인한 경우 그 값을 다시 신청시간으로 덮어쓰지 않습니다.
    v_final := least(
      coalesce(nullif(new.approved_minutes,0),new.calculated_minutes,0),
      v_record.recorded_overtime_minutes
    );
    if v_final <= 0 then raise exception 'ACTUAL_OVERTIME_REQUIRED'; end if;

    update public.correction_requests
    set attendance_record_id = v_record.id,
        approved_minutes = v_final
    where id = new.id;

    if v_record.overtime_status <> 'approved'
       or v_record.approved_overtime_minutes <> v_final
       or v_record.comp_time_eligible_minutes <> 0 then
      update public.attendance_records
      set overtime_status = 'approved',
          approved_overtime_minutes = v_final,
          comp_time_eligible_minutes = 0,
          changed = true,
          updated_at = now()
      where id = v_record.id;

      insert into public.attendance_audit_logs (
        attendance_record_id, employee_id, action_type, changed_field,
        before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
      ) values (
        v_record.id, new.employee_id, 'overtime_review', 'approved_overtime_minutes',
        jsonb_build_object('status',v_record.overtime_status,'minutes',v_record.approved_overtime_minutes)::text,
        jsonb_build_object('status','approved','requested_minutes',new.calculated_minutes,'actual_minutes',v_record.recorded_overtime_minutes,'approved_minutes',v_final)::text,
        coalesce(nullif(trim(new.reviewer_comment),''),new.reason),
        coalesce(new.reviewer_id,auth.uid()), public.current_profile_role(), new.id
      );
    end if;
  elsif tg_op = 'UPDATE' and old.status = 'approved' and new.status <> 'approved' then
    update public.attendance_records
    set overtime_status = case when recorded_overtime_minutes > 0 then 'pending' else 'none' end,
        approved_overtime_minutes = 0,
        comp_time_eligible_minutes = 0,
        changed = true,
        updated_at = now()
    where employee_id = new.employee_id and work_date = new.target_date and deleted_at is null;
  end if;
  return new;
end $$;

drop trigger if exists sync_overtime_request_to_attendance_trigger on public.correction_requests;
create trigger sync_overtime_request_to_attendance_trigger
after insert or update of status
on public.correction_requests
for each row execute function public.sync_overtime_request_to_attendance();

-- 통합 요청 승인 함수에서 시간외근무는 실제 퇴근기록을 먼저 확인합니다.
create or replace function public.review_correction_request(
  p_request_id uuid,
  p_decision text,
  p_comment text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_before text := '';
  v_after text := '';
  v_approved integer := 0;
  v_week_total integer := 0;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected','more_info') then raise exception 'INVALID_DECISION'; end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_comment,''))) < 2 then raise exception 'COMMENT_REQUIRED'; end if;

  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found or v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_REVIEWABLE'; end if;
  if exists (
    select 1 from public.monthly_closings
    where year = extract(year from v_request.target_date)
      and month = extract(month from v_request.target_date)
      and status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  if p_decision = 'approved' and v_request.request_type in ('clock_in_at','clock_out_at') then
    select * into v_record from public.attendance_records
    where id = v_request.attendance_record_id and deleted_at is null for update;
    if not found and v_request.request_type = 'clock_in_at' then
      insert into public.attendance_records (employee_id, work_date, work_type, attendance_status, note, changed)
      values (v_request.employee_id, v_request.target_date, 'office', 'missing_out', '수정 요청으로 생성된 기록', true)
      on conflict (employee_id, work_date) do update
      set changed = true, deleted_at = null, deleted_by = null, deletion_reason = '', updated_at = now()
      returning * into v_record;
      update public.correction_requests set attendance_record_id = v_record.id where id = v_request.id;
    elsif not found then
      raise exception 'CLOCK_IN_CORRECTION_REQUIRED_FIRST';
    end if;

    if v_request.request_type = 'clock_in_at' then
      v_before := coalesce(v_record.clock_in_at::text,'');
      update public.attendance_records
      set clock_in_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true
      where id = v_record.id returning clock_in_at::text into v_after;
    else
      v_before := coalesce(v_record.clock_out_at::text,'');
      update public.attendance_records
      set clock_out_at = (v_request.target_date::text || ' ' || v_request.requested_value)::timestamp at time zone 'Asia/Seoul', changed = true
      where id = v_record.id returning clock_out_at::text into v_after;
    end if;
  elsif p_decision = 'approved' then
    if v_request.request_type = 'overtime' then
      select * into v_record
      from public.attendance_records
      where deleted_at is null
        and employee_id = v_request.employee_id
        and work_date = v_request.target_date
      for update;
      if not found or v_record.clock_out_at is null or coalesce(v_record.recorded_overtime_minutes,0) <= 0 then
        raise exception 'ACTUAL_OVERTIME_REQUIRED';
      end if;
      v_approved := least(240,v_request.calculated_minutes,v_record.recorded_overtime_minutes);
      select coalesce(sum(approved_minutes),0)::integer into v_week_total
      from public.correction_requests
      where employee_id = v_request.employee_id
        and request_type = 'overtime'
        and status = 'approved'
        and id <> v_request.id
        and target_date >= date_trunc('week',v_request.target_date::timestamp)::date
        and target_date < date_trunc('week',v_request.target_date::timestamp)::date + 7;
      if v_week_total + v_approved > 720 then raise exception 'WEEKLY_OVERTIME_LIMIT'; end if;
      update public.correction_requests set attendance_record_id = v_record.id where id = v_request.id;
    else
      v_approved := v_request.calculated_minutes;
    end if;
    v_before := '미승인';
    v_after := jsonb_build_object(
      'start_date',v_request.target_date,'end_date',v_request.end_date,
      'start_time',v_request.start_time,'end_time',v_request.end_time,
      'requested_minutes',v_request.calculated_minutes,'approved_minutes',v_approved,
      'subtype',v_request.request_subtype
    )::text;
    update public.correction_requests set approved_minutes = v_approved where id = v_request.id;
  end if;

  if p_decision = 'approved' then
    insert into public.attendance_audit_logs (
      attendance_record_id, employee_id, action_type, changed_field,
      before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
    ) values (
      coalesce(v_record.id,v_request.attendance_record_id),v_request.employee_id,'request_approved',v_request.request_type,
      v_before,v_after,coalesce(nullif(trim(p_comment),''),v_request.reason),auth.uid(),v_role,v_request.id
    );
  end if;

  update public.correction_requests
  set status = p_decision,
      reviewer_id = auth.uid(),
      reviewer_comment = coalesce(p_comment,''),
      reviewed_at = now()
  where id = p_request_id;
end $$;

-- 기록 화면에서 직접 시간외근무를 재검토할 때도 신청시간 상한을 지킵니다.
create or replace function public.admin_review_overtime(
  p_record_id uuid,
  p_decision text,
  p_approved_minutes integer,
  p_comp_time_minutes integer,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_request public.correction_requests;
  v_role text := public.current_profile_role();
  v_week_start date;
  v_week_total integer := 0;
  v_raw_minutes integer := 0;
  v_comp_time_limit integer := 0;
  v_after text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'INVALID_DECISION'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if coalesce(v_record.recorded_overtime_minutes,0) <= 0 then raise exception 'NO_RECORDED_OVERTIME'; end if;
  v_raw_minutes := greatest(coalesce(v_record.raw_overtime_minutes,0),coalesce(v_record.recorded_overtime_minutes,0));
  v_comp_time_limit := case when v_raw_minutes < 60 then 0 else floor(v_raw_minutes / 30.0)::integer * 30 end;

  select * into v_request
  from public.correction_requests
  where employee_id = v_record.employee_id
    and target_date = v_record.work_date
    and request_type = 'overtime'
  order by requested_at desc
  limit 1
  for update;

  if p_decision = 'approved' then
    if p_approved_minutes not in (60,90,120,150,180,210,240)
       or p_approved_minutes > v_record.recorded_overtime_minutes then
      raise exception 'INVALID_OVERTIME_MINUTES';
    end if;
    if found and p_approved_minutes > v_request.calculated_minutes then raise exception 'OVERTIME_REQUEST_LIMIT'; end if;
    -- 대체휴무는 시간외근무 승인시간과 겹칠 수 있으며 실제 추가근무 전체를 기준으로 합니다.
    -- 최초 1시간부터 인정하고 이후에는 30분 단위로 적립합니다.
    if p_comp_time_minutes < 0
       or (p_comp_time_minutes > 0 and (p_comp_time_minutes < 60 or p_comp_time_minutes % 30 <> 0))
       or p_comp_time_minutes > v_comp_time_limit then raise exception 'INVALID_EXTRA_COMP_TIME'; end if;
    v_week_start := date_trunc('week',v_record.work_date::timestamp)::date;
    select coalesce(sum(approved_overtime_minutes),0)::integer into v_week_total
    from public.attendance_records
    where employee_id = v_record.employee_id
      and id <> v_record.id
      and work_date between v_week_start and v_week_start + 6
      and overtime_status = 'approved'
      and deleted_at is null;
    if v_week_total + p_approved_minutes > 720 then raise exception 'WEEKLY_OVERTIME_LIMIT'; end if;

    update public.attendance_records
    set overtime_status = 'approved', approved_overtime_minutes = p_approved_minutes,
        comp_time_eligible_minutes = p_comp_time_minutes, changed = true, updated_at = now()
    where id = v_record.id;
    if p_comp_time_minutes > 0 then
      insert into public.comp_time_credits (attendance_record_id,employee_id,granted_minutes,remaining_minutes,expires_on,granted_by,reason)
      values (v_record.id,v_record.employee_id,p_comp_time_minutes,p_comp_time_minutes,v_record.work_date + 30,auth.uid(),trim(p_reason))
      on conflict (attendance_record_id) do update
      set granted_minutes = excluded.granted_minutes,
          remaining_minutes = greatest(0,excluded.granted_minutes - (public.comp_time_credits.granted_minutes - public.comp_time_credits.remaining_minutes)),
          expires_on = excluded.expires_on, granted_by = excluded.granted_by,
          granted_at = now(), reason = excluded.reason;
    else
      update public.comp_time_credits
      set remaining_minutes = 0,
          reason = trim(concat_ws(E'\n',reason,'관리자 재검토로 추가 대체휴무 적립 취소'))
      where attendance_record_id = v_record.id and remaining_minutes > 0;
    end if;
    v_after := jsonb_build_object('status','approved','minutes',p_approved_minutes,'comp_time_eligible_minutes',p_comp_time_minutes)::text;
  else
    update public.attendance_records
    set overtime_status = 'rejected', approved_overtime_minutes = 0,
        comp_time_eligible_minutes = 0, changed = true, updated_at = now()
    where id = v_record.id;
    update public.comp_time_credits
    set remaining_minutes = 0,
        reason = trim(concat_ws(E'\n',reason,'시간외근무 반려로 미사용 잔액 소멸'))
    where attendance_record_id = v_record.id and remaining_minutes > 0;
    v_after := jsonb_build_object('status','rejected','minutes',0)::text;
  end if;

  if v_request.id is not null then
    update public.correction_requests
    set status = p_decision,
        approved_minutes = case when p_decision = 'approved' then p_approved_minutes else 0 end,
        reviewer_id = auth.uid(), reviewer_comment = trim(p_reason), reviewed_at = now()
    where id = v_request.id;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role,
    correction_request_id
  ) values (
    v_record.id,v_record.employee_id,'overtime_review','approved_overtime_minutes',
    jsonb_build_object('status',v_record.overtime_status,'minutes',v_record.approved_overtime_minutes,'comp_time_eligible_minutes',v_record.comp_time_eligible_minutes)::text,
    v_after,trim(p_reason),auth.uid(),v_role,v_request.id
  );
end $$;

revoke all on function public.admin_create_attendance_records(uuid[],date,time,time,text) from public, anon;
grant execute on function public.admin_create_attendance_records(uuid[],date,time,time,text) to authenticated;
revoke all on function public.admin_create_attendance_exceptions(uuid[],date,date,text,text) from public, anon;
grant execute on function public.admin_create_attendance_exceptions(uuid[],date,date,text,text) to authenticated;
revoke all on function public.approved_leave_minutes_during_attendance(uuid,timestamptz,timestamptz) from public, anon;
grant execute on function public.approved_leave_minutes_during_attendance(uuid,timestamptz,timestamptz) to authenticated;
revoke all on function public.review_correction_request(uuid,text,text) from public, anon;
grant execute on function public.review_correction_request(uuid,text,text) to authenticated;
revoke all on function public.admin_review_overtime(uuid,text,integer,integer,text) from public, anon;
grant execute on function public.admin_review_overtime(uuid,text,integer,integer,text) to authenticated;

notify pgrst, 'reload schema';
commit;

select '다중 직원 등록, 외부교육, 실제 시간외근무, 중간 휴가 계산 보완 완료' as result;
