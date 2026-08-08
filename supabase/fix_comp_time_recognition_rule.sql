-- 대체휴무 적립 기준 보완
-- 시간외근무 승인시간과 별도로 실제 추가근무 전체를 대체휴무로 인정할 수 있습니다.
-- 최초 1시간부터 인정하고 이후에는 30분 단위로 적립합니다.

begin;

-- 실제 유급 근무가 8시간을 넘은 분량을 계산합니다.
-- 최초 1시간은 모두 채워야 하고, 그 이후에는 30분 구간을 1분이라도 넘으면 다음 30분까지 인정합니다.
create or replace function public.recognized_overtime_minutes(p_raw_minutes integer)
returns integer
language sql immutable
as $$
  select case
    when coalesce(p_raw_minutes,0) < 60 then 0
    else least(240,60 + ceil((p_raw_minutes - 60) / 30.0)::integer * 30)
  end
$$;

alter table public.comp_time_credits
  drop constraint if exists comp_time_credits_granted_minutes_check;
alter table public.comp_time_credits
  drop constraint if exists comp_time_credits_remaining_minutes_check;
alter table public.comp_time_credits
  add constraint comp_time_credits_granted_minutes_check
    check (granted_minutes >= 0),
  add constraint comp_time_credits_remaining_minutes_check
    check (remaining_minutes >= 0 and remaining_minutes <= granted_minutes);

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
  v_has_request boolean := false;
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

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if coalesce(v_record.recorded_overtime_minutes,0) <= 0 then raise exception 'NO_RECORDED_OVERTIME'; end if;

  v_raw_minutes := greatest(
    coalesce(v_record.raw_overtime_minutes,0),
    coalesce(v_record.recorded_overtime_minutes,0)
  );
  v_comp_time_limit := case
    when v_raw_minutes < 60 then 0
    else 60 + ceil((v_raw_minutes - 60) / 30.0)::integer * 30
  end;

  select * into v_request
  from public.correction_requests
  where employee_id = v_record.employee_id
    and target_date = v_record.work_date
    and request_type = 'overtime'
  order by requested_at desc
  limit 1
  for update;
  v_has_request := found;

  if p_decision = 'approved' then
    if p_approved_minutes not in (60,90,120,150,180,210,240)
       or p_approved_minutes > v_record.recorded_overtime_minutes then
      raise exception 'INVALID_OVERTIME_MINUTES';
    end if;
    if v_has_request and p_approved_minutes > v_request.calculated_minutes then
      raise exception 'OVERTIME_REQUEST_LIMIT';
    end if;

    if p_comp_time_minutes < 0
       or (p_comp_time_minutes > 0 and (p_comp_time_minutes < 60 or p_comp_time_minutes % 30 <> 0))
       or p_comp_time_minutes > v_comp_time_limit then
      raise exception 'INVALID_EXTRA_COMP_TIME';
    end if;

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
    set overtime_status = 'approved',
        approved_overtime_minutes = p_approved_minutes,
        comp_time_eligible_minutes = p_comp_time_minutes,
        changed = true,
        updated_at = now()
    where id = v_record.id;

    if p_comp_time_minutes > 0 then
      insert into public.comp_time_credits (
        attendance_record_id,employee_id,granted_minutes,remaining_minutes,
        expires_on,granted_by,reason
      ) values (
        v_record.id,v_record.employee_id,p_comp_time_minutes,p_comp_time_minutes,
        v_record.work_date + 30,auth.uid(),trim(p_reason)
      )
      on conflict (attendance_record_id) do update
      set granted_minutes = excluded.granted_minutes,
          remaining_minutes = greatest(
            0,
            excluded.granted_minutes
              - (public.comp_time_credits.granted_minutes - public.comp_time_credits.remaining_minutes)
          ),
          expires_on = excluded.expires_on,
          granted_by = excluded.granted_by,
          granted_at = now(),
          reason = excluded.reason;
    else
      update public.comp_time_credits
      set remaining_minutes = 0,
          reason = trim(concat_ws(E'\n',reason,'관리자 재검토로 대체휴무 적립 취소'))
      where attendance_record_id = v_record.id and remaining_minutes > 0;
    end if;

    v_after := jsonb_build_object(
      'status','approved',
      'minutes',p_approved_minutes,
      'comp_time_eligible_minutes',p_comp_time_minutes
    )::text;
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
        reason = trim(concat_ws(E'\n',reason,'시간외근무 반려로 미사용 잔액 소멸'))
    where attendance_record_id = v_record.id and remaining_minutes > 0;
    v_after := jsonb_build_object('status','rejected','minutes',0)::text;
  end if;

  if v_has_request then
    update public.correction_requests
    set status = p_decision,
        approved_minutes = case when p_decision = 'approved' then p_approved_minutes else 0 end,
        reviewer_id = auth.uid(),
        reviewer_comment = trim(p_reason),
        reviewed_at = now()
    where id = v_request.id;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,
    before_value,after_value,reason,changed_by,changed_by_role,
    correction_request_id
  ) values (
    v_record.id,v_record.employee_id,'overtime_review','approved_overtime_minutes',
    jsonb_build_object(
      'status',v_record.overtime_status,
      'minutes',v_record.approved_overtime_minutes,
      'comp_time_eligible_minutes',v_record.comp_time_eligible_minutes
    )::text,
    v_after,trim(p_reason),auth.uid(),v_role,
    case when v_has_request then v_request.id else null end
  );
end $$;

-- 저장된 출퇴근기록도 새 인정단위로 다시 계산합니다.
update public.attendance_records
set clock_out_at = clock_out_at
where deleted_at is null and clock_in_at is not null and clock_out_at is not null;

revoke all on function public.recognized_overtime_minutes(integer) from public, anon;
grant execute on function public.recognized_overtime_minutes(integer) to authenticated;

revoke all on function public.admin_review_overtime(uuid,text,integer,integer,text) from public, anon;
grant execute on function public.admin_review_overtime(uuid,text,integer,integer,text) to authenticated;

notify pgrst, 'reload schema';
commit;

select '대체휴무 적립 기준 보완 완료' as result;
