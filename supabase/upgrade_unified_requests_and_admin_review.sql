begin;

-- 휴가, 출장, 시간외근무를 시작일시와 종료일시로 요청할 수 있도록 확장합니다.
alter table public.correction_requests add column if not exists end_date date;
alter table public.correction_requests add column if not exists start_time time;
alter table public.correction_requests add column if not exists end_time time;
alter table public.correction_requests add column if not exists calculated_minutes integer not null default 0;
alter table public.correction_requests add column if not exists approved_minutes integer not null default 0;
alter table public.correction_requests add column if not exists request_subtype text not null default '';

alter table public.attendance_records add column if not exists raw_overtime_minutes integer not null default 0;
alter table public.attendance_records add column if not exists recorded_overtime_minutes integer not null default 0;
alter table public.attendance_records add column if not exists approved_overtime_minutes integer not null default 0;
alter table public.attendance_records add column if not exists overtime_status text not null default 'none';
alter table public.attendance_records add column if not exists comp_time_eligible_minutes integer not null default 0;

-- 기존에 만들어진 보기 화면은 나중에 추가한 시간외근무 열을 자동으로 포함하지 않습니다.
-- 다시 만들어 앱이 계산값과 승인상태를 실제로 읽을 수 있게 합니다.
drop view if exists public.attendance_records_view;
create view public.attendance_records_view with (security_invoker = true) as
select ar.*, p.name as employee_name, p.employee_number, p.department
from public.attendance_records ar
join public.profiles p on p.id = ar.employee_id
where ar.deleted_at is null;
grant select on public.attendance_records_view to authenticated;

update public.correction_requests
set end_date = target_date
where end_date is null;

alter table public.correction_requests alter column end_date drop default;

do $$
declare v_constraint record;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.correction_requests'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%request_type%'
  loop
    execute format('alter table public.correction_requests drop constraint %I', v_constraint.conname);
  end loop;
end $$;

alter table public.correction_requests
  add constraint correction_requests_request_type_check
  check (request_type in (
    'clock_in_at','clock_out_at','annual_leave','comp_time','sick_leave',
    'business_trip','overtime','other_leave','work_type','note','attendance_status'
  )) not valid;

alter table public.correction_requests drop constraint if exists correction_requests_date_range_check;
alter table public.correction_requests
  add constraint correction_requests_date_range_check
  check (end_date is null or end_date >= target_date) not valid;

create or replace function public.calculate_attendance_request_minutes(
  p_request_type text,
  p_start_date date,
  p_end_date date,
  p_start_time time,
  p_end_time time
) returns integer
language plpgsql stable security definer set search_path = public as $$
declare
  v_day date;
  v_from timestamp;
  v_until timestamp;
  v_lunch_from timestamp;
  v_lunch_until timestamp;
  v_minutes integer := 0;
  v_day_minutes integer;
begin
  if p_end_date < p_start_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_start_time is null or p_end_time is null then raise exception 'TIME_REQUIRED'; end if;

  if p_request_type = 'overtime' then
    if p_start_date <> p_end_date or p_end_time <= p_start_time then raise exception 'INVALID_OVERTIME_RANGE'; end if;
    return floor(extract(epoch from (p_end_time - p_start_time)) / 60)::integer;
  end if;

  v_day := p_start_date;
  while v_day <= p_end_date loop
    if extract(isodow from v_day) < 6
       and not exists (select 1 from public.holidays h where h.holiday_date = v_day) then
      v_from := v_day + case when v_day = p_start_date then greatest(p_start_time, time '09:00') else time '09:00' end;
      v_until := v_day + case when v_day = p_end_date then least(p_end_time, time '18:00') else time '18:00' end;
      if v_until > v_from then
        v_day_minutes := floor(extract(epoch from (v_until - v_from)) / 60)::integer;
        v_lunch_from := greatest(v_from, v_day + time '12:00');
        v_lunch_until := least(v_until, v_day + time '13:00');
        if v_lunch_until > v_lunch_from then
          v_day_minutes := v_day_minutes - floor(extract(epoch from (v_lunch_until - v_lunch_from)) / 60)::integer;
        end if;
        v_minutes := v_minutes + greatest(0, least(480, v_day_minutes));
      end if;
    end if;
    v_day := v_day + 1;
  end loop;
  return v_minutes;
end $$;

create or replace function public.prepare_attendance_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.end_date := coalesce(new.end_date, new.target_date);
  if new.request_type in ('clock_in_at','clock_out_at') then
    new.end_date := new.target_date;
    new.calculated_minutes := 0;
  elsif new.request_type in ('annual_leave','comp_time','sick_leave','business_trip','overtime','other_leave') then
    new.calculated_minutes := public.calculate_attendance_request_minutes(
      new.request_type, new.target_date, new.end_date, new.start_time, new.end_time
    );
    if new.calculated_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;
    new.requested_value := new.calculated_minutes::text;
  end if;
  if new.request_type = 'other_leave' and char_length(trim(coalesce(new.request_subtype,''))) < 2 then
    raise exception 'OTHER_LEAVE_NAME_REQUIRED';
  end if;
  return new;
end $$;

drop trigger if exists prepare_attendance_request_trigger on public.correction_requests;
create trigger prepare_attendance_request_trigger
before insert or update of target_date, end_date, start_time, end_time, request_type, request_subtype
on public.correction_requests
for each row execute function public.prepare_attendance_request();

-- 수정된 시각을 기준으로 지각과 확인 필요 상태도 다시 판정합니다.
create or replace function public.derive_attendance_status(p_record public.attendance_records)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_start time := coalesce((select default_start_time from public.organization_settings where id = true), time '09:00');
  v_grace integer := coalesce((select late_grace_minutes from public.organization_settings where id = true), 0);
  v_leave_type text := coalesce(to_jsonb(p_record)->>'leave_type', 'none');
  v_regular boolean;
  v_location_review boolean;
  v_worked integer := 0;
  v_lunch integer := 0;
  v_required integer := 480;
  v_lunch_from timestamptz;
  v_lunch_until timestamptz;
begin
  if p_record.clock_in_at is null then
    return case when v_leave_type in ('annual_leave','half_day','quarter_day','hourly_leave','sick_leave') then v_leave_type else 'missing_in' end;
  end if;
  v_regular := extract(isodow from p_record.work_date) < 6
    and not exists (select 1 from public.holidays h where h.holiday_date = p_record.work_date and h.is_paid_holiday);
  v_location_review :=
    (p_record.clock_in_location_status in ('outside','low_accuracy') and not coalesce(p_record.clock_in_ip_matched,false))
    or (p_record.clock_out_at is not null and p_record.clock_out_location_status in ('outside','low_accuracy') and not coalesce(p_record.clock_out_ip_matched,false));
  if v_location_review then return 'admin_review'; end if;
  if not v_regular then return 'holiday_work'; end if;
  if (p_record.clock_in_at at time zone 'Asia/Seoul')::time > v_start + make_interval(mins => v_grace) then return 'late'; end if;
  if p_record.clock_out_at is null then return 'working'; end if;

  v_worked := floor(extract(epoch from (p_record.clock_out_at - p_record.clock_in_at)) / 60)::integer;
  v_lunch_from := (p_record.work_date + time '12:00') at time zone 'Asia/Seoul';
  v_lunch_until := (p_record.work_date + time '13:00') at time zone 'Asia/Seoul';
  if least(p_record.clock_out_at, v_lunch_until) > greatest(p_record.clock_in_at, v_lunch_from) then
    v_lunch := floor(extract(epoch from (least(p_record.clock_out_at, v_lunch_until) - greatest(p_record.clock_in_at, v_lunch_from))) / 60)::integer;
  end if;
  v_worked := greatest(0, v_worked - v_lunch);
  v_required := case v_leave_type when 'half_day' then 240 when 'quarter_day' then 360 when 'hourly_leave' then 420 when 'annual_leave' then 0 when 'sick_leave' then 0 else 480 end;
  return case when v_worked < v_required then 'admin_review' else 'normal' end;
end $$;

create or replace function public.recalculate_attendance_status_on_time_change()
returns trigger language plpgsql security definer set search_path = public as $$
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

update public.attendance_records ar
set attendance_status = public.derive_attendance_status(ar), updated_at = now()
where ar.deleted_at is null
  and ar.clock_in_at is not null
  and ar.attendance_status is distinct from public.derive_attendance_status(ar);

create or replace function public.admin_confirm_attendance_record(
  p_record_id uuid,
  p_comment text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_comment,''))) < 2 then raise exception 'COMMENT_REQUIRED'; end if;

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_record.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if v_record.attendance_status not in ('admin_review','location_review','field','education') then
    raise exception 'RECORD_NOT_REVIEWABLE';
  end if;

  update public.attendance_records
  set attendance_status = case when clock_out_at is null then 'working' else 'normal' end,
      changed = true,
      updated_at = now()
  where id = p_record_id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, org_id
  ) values (
    v_record.id, v_record.employee_id, 'admin_review_completed', 'attendance_status',
    v_record.attendance_status,
    case when v_record.clock_out_at is null then 'working' else 'normal' end,
    trim(p_comment), auth.uid(), v_role, v_record.org_id
  );
end $$;

-- 관리자 화면의 시간외근무 승인, 반려 버튼이 호출하는 처리 함수입니다.
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
  v_role text := public.current_profile_role();
  v_week_start date;
  v_week_total integer := 0;
  v_raw_minutes integer := 0;
  v_after text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'INVALID_DECISION'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if coalesce(v_record.recorded_overtime_minutes,0) <= 0 then raise exception 'NO_RECORDED_OVERTIME'; end if;
  v_raw_minutes := greatest(coalesce(v_record.raw_overtime_minutes,0), coalesce(v_record.recorded_overtime_minutes,0));

  if p_decision = 'approved' then
    if p_approved_minutes not in (60,90,120,150,180,210,240)
       or p_approved_minutes > v_record.recorded_overtime_minutes then
      raise exception 'INVALID_OVERTIME_MINUTES';
    end if;
    if p_comp_time_minutes < 0 or p_comp_time_minutes % 60 <> 0
       or p_approved_minutes + p_comp_time_minutes > v_raw_minutes then
      raise exception 'INVALID_EXTRA_COMP_TIME';
    end if;
    v_week_start := date_trunc('week', v_record.work_date::timestamp)::date;
    select coalesce(sum(approved_overtime_minutes + comp_time_eligible_minutes),0)::integer into v_week_total
    from public.attendance_records
    where employee_id = v_record.employee_id
      and id <> v_record.id
      and work_date between v_week_start and v_week_start + 6
      and overtime_status = 'approved'
      and deleted_at is null;
    if v_week_total + p_approved_minutes + p_comp_time_minutes > 720 then raise exception 'WEEKLY_OVERTIME_LIMIT'; end if;

    update public.attendance_records
    set overtime_status = 'approved',
        approved_overtime_minutes = p_approved_minutes,
        comp_time_eligible_minutes = p_comp_time_minutes,
        changed = true,
        updated_at = now()
    where id = v_record.id;
    if p_comp_time_minutes > 0 then
      insert into public.comp_time_credits (attendance_record_id, employee_id, granted_minutes, remaining_minutes, expires_on, granted_by, reason)
      values (v_record.id, v_record.employee_id, p_comp_time_minutes, p_comp_time_minutes, v_record.work_date + 30, auth.uid(), trim(p_reason))
      on conflict (attendance_record_id) do update
      set granted_minutes = excluded.granted_minutes,
          remaining_minutes = greatest(0, excluded.granted_minutes - (public.comp_time_credits.granted_minutes - public.comp_time_credits.remaining_minutes)),
          expires_on = excluded.expires_on,
          granted_by = excluded.granted_by,
          granted_at = now(),
          reason = excluded.reason;
    else
      update public.comp_time_credits
      set remaining_minutes = 0,
          reason = trim(concat_ws(E'\n', reason, '관리자 재검토로 추가 대체휴무 적립 취소'))
      where attendance_record_id = v_record.id and remaining_minutes > 0;
    end if;
    v_after := jsonb_build_object('status','approved','minutes',p_approved_minutes,'comp_time_eligible_minutes',p_comp_time_minutes)::text;
  else
    update public.attendance_records
    set overtime_status = 'rejected',
        approved_overtime_minutes = 0,
        comp_time_eligible_minutes = 0,
        changed = true,
        updated_at = now()
    where id = v_record.id;
    update public.comp_time_credits
    set remaining_minutes = 0,
        reason = trim(concat_ws(E'\n', reason, '시간외근무 반려로 미사용 잔액 소멸'))
    where attendance_record_id = v_record.id and remaining_minutes > 0;
    v_after := jsonb_build_object('status','rejected','minutes',0)::text;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role
  ) values (
    v_record.id, v_record.employee_id, 'overtime_review', 'approved_overtime_minutes',
    jsonb_build_object('status',v_record.overtime_status,'minutes',v_record.approved_overtime_minutes)::text,
    v_after, trim(p_reason), auth.uid(), v_role
  );
end $$;

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
      v_approved := least(240, v_request.calculated_minutes);
      select coalesce(sum(approved_minutes), 0)::integer into v_week_total
      from public.correction_requests
      where employee_id = v_request.employee_id
        and request_type = 'overtime'
        and status = 'approved'
        and target_date >= date_trunc('week', v_request.target_date::timestamp)::date
        and target_date < date_trunc('week', v_request.target_date::timestamp)::date + 7;
      if v_week_total + v_approved > 720 then raise exception 'WEEKLY_OVERTIME_LIMIT'; end if;
    else
      v_approved := v_request.calculated_minutes;
    end if;
    v_before := '미승인';
    v_after := jsonb_build_object(
      'start_date', v_request.target_date,
      'end_date', v_request.end_date,
      'start_time', v_request.start_time,
      'end_time', v_request.end_time,
      'minutes', v_request.calculated_minutes,
      'subtype', v_request.request_subtype
    )::text;
    update public.correction_requests
    set approved_minutes = v_approved
    where id = v_request.id;
  end if;

  if p_decision = 'approved' then
    insert into public.attendance_audit_logs (
      attendance_record_id, employee_id, action_type, changed_field,
      before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
    ) values (
      v_request.attendance_record_id, v_request.employee_id, 'request_approved', v_request.request_type,
      v_before, v_after, coalesce(nullif(trim(p_comment),''), v_request.reason), auth.uid(), v_role, v_request.id
    );
  end if;

  update public.correction_requests
  set status = p_decision,
      reviewer_id = auth.uid(),
      reviewer_comment = coalesce(p_comment,''),
      reviewed_at = now()
  where id = p_request_id;
end $$;

create or replace function public.admin_reopen_correction_request(
  p_request_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_role text := public.current_profile_role();
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.status in ('pending','more_info') then raise exception 'REQUEST_ALREADY_OPEN'; end if;
  if v_request.status = 'approved' and v_request.request_type in ('clock_in_at','clock_out_at') then raise exception 'APPLIED_CLOCK_CORRECTION'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_request.target_date) and month = extract(month from v_request.target_date) and status = 'closed') and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  update public.correction_requests
  set status = 'pending', reviewer_id = null, reviewer_comment = '', reviewed_at = null
  where id = p_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
  ) values (
    v_request.attendance_record_id, v_request.employee_id, 'request_reopened', 'request_status',
    v_request.status, 'pending', trim(p_reason), auth.uid(), v_role, v_request.id
  );
end $$;

drop function if exists public.admin_update_attendance_request(uuid,date,date,time,time,text,text,text);

create or replace function public.admin_update_attendance_request(
  p_request_id uuid,
  p_start_date date,
  p_end_date date,
  p_start_time time,
  p_end_time time,
  p_request_type text,
  p_request_subtype text,
  p_requested_value text,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_role text := public.current_profile_role();
  v_before text;
  v_request_type text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.status = 'approved' and v_request.request_type in ('clock_in_at','clock_out_at') then raise exception 'APPLIED_CLOCK_CORRECTION'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_request.target_date) and month = extract(month from v_request.target_date) and status = 'closed') and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  v_request_type := trim(coalesce(p_request_type,''));
  if v_request_type not in ('clock_in_at','clock_out_at','annual_leave','comp_time','sick_leave','business_trip','overtime','other_leave') then raise exception 'INVALID_REQUEST_TYPE'; end if;
  v_before := jsonb_build_object('request_type',v_request.request_type,'start_date',v_request.target_date,'end_date',v_request.end_date,'start_time',v_request.start_time,'end_time',v_request.end_time,'subtype',v_request.request_subtype,'value',v_request.requested_value,'reason',v_request.reason,'status',v_request.status)::text;

  if v_request_type in ('clock_in_at','clock_out_at') then
    update public.correction_requests
    set request_type = v_request_type,
        target_date = p_start_date, end_date = p_start_date,
        start_time = null, end_time = null,
        request_subtype = '', approved_minutes = 0,
        requested_value = trim(coalesce(p_requested_value,'')), reason = trim(p_reason),
        status = 'pending', reviewer_id = null, reviewer_comment = '', reviewed_at = null
    where id = p_request_id;
  else
    update public.correction_requests
    set request_type = v_request_type,
        target_date = p_start_date,
        end_date = case when v_request_type = 'overtime' then p_start_date else coalesce(p_end_date,p_start_date) end,
        start_time = p_start_time, end_time = p_end_time,
        request_subtype = case when v_request_type = 'other_leave' then trim(coalesce(p_request_subtype,'')) else '' end,
        approved_minutes = 0, reason = trim(p_reason),
        status = 'pending', reviewer_id = null, reviewer_comment = '', reviewed_at = null
    where id = p_request_id;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
  )
  select
    attendance_record_id, employee_id, 'request_edited', 'attendance_request',
    v_before,
    jsonb_build_object('request_type',request_type,'start_date',target_date,'end_date',end_date,'start_time',start_time,'end_time',end_time,'subtype',request_subtype,'value',requested_value,'reason',reason,'status',status)::text,
    trim(p_reason), auth.uid(), v_role, id
  from public.correction_requests where id = p_request_id;
end $$;

create or replace function public.employee_resubmit_attendance_request(
  p_request_id uuid,
  p_start_date date,
  p_end_date date,
  p_start_time time,
  p_end_time time,
  p_request_subtype text,
  p_requested_value text,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_request public.correction_requests;
  v_before text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_request
  from public.correction_requests
  where id = p_request_id and employee_id = auth.uid()
  for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.status not in ('pending','rejected','more_info') then raise exception 'REQUEST_NOT_RESUBMITTABLE'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_request.target_date) and month = extract(month from v_request.target_date) and status = 'closed') then raise exception 'MONTH_CLOSED'; end if;
  v_before := jsonb_build_object('start_date',v_request.target_date,'end_date',v_request.end_date,'start_time',v_request.start_time,'end_time',v_request.end_time,'subtype',v_request.request_subtype,'value',v_request.requested_value,'reason',v_request.reason,'status',v_request.status)::text;

  if v_request.request_type in ('clock_in_at','clock_out_at') then
    update public.correction_requests
    set target_date = p_start_date, end_date = p_start_date,
        start_time = null, end_time = null,
        requested_value = trim(coalesce(p_requested_value,'')), reason = trim(p_reason),
        status = 'pending', reviewer_id = null, reviewer_comment = '', reviewed_at = null,
        requested_at = now()
    where id = p_request_id;
  else
    update public.correction_requests
    set target_date = p_start_date,
        end_date = case when request_type = 'overtime' then p_start_date else coalesce(p_end_date,p_start_date) end,
        start_time = p_start_time, end_time = p_end_time,
        request_subtype = trim(coalesce(p_request_subtype,'')), reason = trim(p_reason),
        status = 'pending', reviewer_id = null, reviewer_comment = '', reviewed_at = null,
        requested_at = now()
    where id = p_request_id;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role, correction_request_id
  )
  select attendance_record_id, employee_id, 'request_resubmitted', 'attendance_request', v_before,
    jsonb_build_object('start_date',target_date,'end_date',end_date,'start_time',start_time,'end_time',end_time,'subtype',request_subtype,'value',requested_value,'reason',reason,'status',status)::text,
    trim(p_reason), auth.uid(), 'employee', id
  from public.correction_requests where id = p_request_id;
end $$;

create or replace function public.admin_restore_attendance(
  p_record_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.deleted_at is null then raise exception 'RECORD_NOT_DELETED'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if exists (
    select 1 from public.attendance_records
    where employee_id = v_record.employee_id and work_date = v_record.work_date
      and id <> v_record.id and deleted_at is null
  ) then raise exception 'ACTIVE_RECORD_ALREADY_EXISTS'; end if;

  update public.attendance_records
  set deleted_at = null, deleted_by = null, deletion_reason = '', changed = true, updated_at = now()
  where id = p_record_id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role
  ) values (
    v_record.id, v_record.employee_id, 'admin_restore', 'attendance_record',
    '삭제됨', '기록 복원됨', trim(p_reason), auth.uid(), v_role
  );
end $$;

-- 버튼 기록뿐 아니라 관리자가 출퇴근 시각을 수정한 경우에도 시간외근무를 다시 계산합니다.
create or replace function public.recalculate_overtime_after_attendance_change()
returns trigger language plpgsql set search_path = public as $$
declare
  v_worked integer := 0;
  v_lunch integer := 0;
  v_raw integer := 0;
  v_recognized integer := 0;
  v_lunch_from timestamptz;
  v_lunch_until timestamptz;
begin
  if new.clock_in_at is not null and new.clock_out_at is not null and new.clock_out_at > new.clock_in_at then
    v_worked := floor(extract(epoch from (new.clock_out_at - new.clock_in_at)) / 60)::integer;
    v_lunch_from := (new.work_date + time '12:00') at time zone 'Asia/Seoul';
    v_lunch_until := (new.work_date + time '13:00') at time zone 'Asia/Seoul';
    if least(new.clock_out_at, v_lunch_until) > greatest(new.clock_in_at, v_lunch_from) then
      v_lunch := floor(extract(epoch from (least(new.clock_out_at, v_lunch_until) - greatest(new.clock_in_at, v_lunch_from))) / 60)::integer;
    end if;
    v_raw := greatest(0, v_worked - v_lunch - 480);
    v_recognized := case when v_raw < 60 then 0 else least(240, floor(v_raw / 30.0)::integer * 30) end;
  end if;
  new.raw_overtime_minutes := v_raw;
  new.recorded_overtime_minutes := v_recognized;
  if v_recognized > 0 and (tg_op = 'INSERT' or old.clock_in_at is distinct from new.clock_in_at or old.clock_out_at is distinct from new.clock_out_at) then
    new.overtime_status := 'pending';
    new.approved_overtime_minutes := 0;
  elsif v_recognized = 0 then
    new.overtime_status := 'none';
    new.approved_overtime_minutes := 0;
  end if;
  return new;
end $$;

drop trigger if exists recalculate_overtime_after_attendance_change_trigger on public.attendance_records;
create trigger recalculate_overtime_after_attendance_change_trigger
before insert or update of clock_in_at, clock_out_at
on public.attendance_records
for each row execute function public.recalculate_overtime_after_attendance_change();

-- 기존 기록도 같은 기준으로 한 번 다시 계산합니다.
update public.attendance_records
set clock_in_at = clock_in_at
where deleted_at is null and clock_in_at is not null and clock_out_at is not null;

drop view if exists public.correction_requests_view;
create view public.correction_requests_view with (security_invoker = true) as
select
  cr.*,
  employee.name as employee_name,
  employee.employee_number,
  employee.department,
  reviewer.name as reviewer_name
from public.correction_requests cr
join public.profiles employee on employee.id = cr.employee_id
left join public.profiles reviewer on reviewer.id = cr.reviewer_id;

grant select on public.correction_requests_view to authenticated;
revoke all on function public.calculate_attendance_request_minutes(text,date,date,time,time) from public, anon;
grant execute on function public.calculate_attendance_request_minutes(text,date,date,time,time) to authenticated;
revoke all on function public.admin_confirm_attendance_record(uuid,text) from public, anon;
grant execute on function public.admin_confirm_attendance_record(uuid,text) to authenticated;
revoke all on function public.admin_review_overtime(uuid,text,integer,integer,text) from public, anon;
grant execute on function public.admin_review_overtime(uuid,text,integer,integer,text) to authenticated;
revoke all on function public.admin_reopen_correction_request(uuid,text) from public, anon;
grant execute on function public.admin_reopen_correction_request(uuid,text) to authenticated;
revoke all on function public.admin_update_attendance_request(uuid,date,date,time,time,text,text,text,text) from public, anon;
grant execute on function public.admin_update_attendance_request(uuid,date,date,time,time,text,text,text,text) to authenticated;
revoke all on function public.employee_resubmit_attendance_request(uuid,date,date,time,time,text,text,text) from public, anon;
grant execute on function public.employee_resubmit_attendance_request(uuid,date,date,time,time,text,text,text) to authenticated;
revoke all on function public.admin_restore_attendance(uuid,text) from public, anon;
grant execute on function public.admin_restore_attendance(uuid,text) to authenticated;

notify pgrst, 'reload schema';
commit;

select '통합 요청과 관리자 확인 화면용 데이터베이스 보완 완료' as result;
