-- 기관관리자가 자기 기관의 시간외근무를 승인하고 대휴를 적립할 수 있게 보완합니다.
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
  v_org_id uuid := public.current_profile_org_id();
  v_week_start date;
  v_week_total integer := 0;
  v_raw_minutes integer := 0;
  v_comp_time_limit integer := 0;
  v_after text;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'INVALID_DECISION'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;

  select * into v_record
  from public.attendance_records
  where id = p_record_id and deleted_at is null
  for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_record.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if coalesce(v_record.recorded_overtime_minutes,0) <= 0 then raise exception 'NO_RECORDED_OVERTIME'; end if;

  v_raw_minutes := greatest(coalesce(v_record.raw_overtime_minutes,0), coalesce(v_record.recorded_overtime_minutes,0));
  v_comp_time_limit := case when v_raw_minutes < 60 then 0 else 60 + ceil((v_raw_minutes - 60) / 30.0)::integer * 30 end;

  select * into v_request
  from public.correction_requests
  where employee_id = v_record.employee_id
    and org_id = v_record.org_id
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
    if v_has_request and p_approved_minutes > v_request.calculated_minutes then raise exception 'OVERTIME_REQUEST_LIMIT'; end if;
    if p_comp_time_minutes < 0
       or (p_comp_time_minutes > 0 and (p_comp_time_minutes < 60 or p_comp_time_minutes % 30 <> 0))
       or p_comp_time_minutes > v_comp_time_limit then raise exception 'INVALID_EXTRA_COMP_TIME'; end if;

    v_week_start := date_trunc('week',v_record.work_date::timestamp)::date;
    select coalesce(sum(approved_overtime_minutes),0)::integer into v_week_total
    from public.attendance_records
    where employee_id = v_record.employee_id
      and org_id = v_record.org_id
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
      insert into public.comp_time_credits (
        attendance_record_id,employee_id,granted_minutes,remaining_minutes,
        expires_on,granted_by,reason,source_type,source_date,org_id
      ) values (
        v_record.id,v_record.employee_id,p_comp_time_minutes,p_comp_time_minutes,
        v_record.work_date + 30,auth.uid(),trim(p_reason),'overtime',v_record.work_date,v_record.org_id
      )
      on conflict (attendance_record_id) do update
      set granted_minutes = excluded.granted_minutes,
          remaining_minutes = greatest(0, excluded.granted_minutes - (public.comp_time_credits.granted_minutes - public.comp_time_credits.remaining_minutes)),
          expires_on = excluded.expires_on,
          granted_by = excluded.granted_by,
          granted_at = now(),
          reason = excluded.reason,
          source_date = excluded.source_date,
          org_id = excluded.org_id;
    else
      update public.comp_time_credits
      set remaining_minutes = 0,
          reason = trim(concat_ws(E'\n',reason,'관리자 재검토로 대체휴무 적립 취소'))
      where attendance_record_id = v_record.id and org_id = v_record.org_id and remaining_minutes > 0;
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
    where attendance_record_id = v_record.id and org_id = v_record.org_id and remaining_minutes > 0;
    v_after := jsonb_build_object('status','rejected','minutes',0)::text;
  end if;

  if v_has_request then
    update public.correction_requests
    set status = p_decision,
        approved_minutes = case when p_decision = 'approved' then p_approved_minutes else 0 end,
        reviewer_id = auth.uid(), reviewer_comment = trim(p_reason), reviewed_at = now()
    where id = v_request.id and org_id = v_record.org_id;
  end if;

  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,
    before_value,after_value,reason,changed_by,changed_by_role,
    correction_request_id,org_id
  ) values (
    v_record.id,v_record.employee_id,'overtime_review','approved_overtime_minutes',
    jsonb_build_object('status',v_record.overtime_status,'minutes',v_record.approved_overtime_minutes,'comp_time_eligible_minutes',v_record.comp_time_eligible_minutes)::text,
    v_after,trim(p_reason),auth.uid(),v_role,
    case when v_has_request then v_request.id else null end,v_record.org_id
  );
end $$;

revoke all on function public.admin_review_overtime(uuid,text,integer,integer,text) from public, anon;
grant execute on function public.admin_review_overtime(uuid,text,integer,integer,text) to authenticated;
notify pgrst, 'reload schema';
