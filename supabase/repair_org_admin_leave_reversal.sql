begin;

create or replace function public.admin_reopen_correction_request(
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
  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_request.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if v_request.status in ('pending','more_info') then raise exception 'REQUEST_ALREADY_OPEN'; end if;
  if v_request.status = 'approved' and v_request.request_type in ('clock_in_at','clock_out_at') then raise exception 'APPLIED_CLOCK_CORRECTION'; end if;
  if exists (
    select 1 from public.monthly_closings closing
    where closing.org_id = v_request.org_id
      and closing.year = extract(year from v_request.target_date)
      and closing.month = extract(month from v_request.target_date)
      and closing.status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  update public.correction_requests
  set status = 'pending', approved_minutes = 0,
      reviewer_id = null, reviewer_comment = '', reviewed_at = null
  where id = p_request_id;

  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field,
    before_value, after_value, reason, changed_by, changed_by_role,
    correction_request_id, org_id
  ) values (
    v_request.attendance_record_id, v_request.employee_id, 'request_reopened', 'request_status',
    v_request.status, 'pending', trim(p_reason), auth.uid(), v_role,
    v_request.id, v_request.org_id
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
  v_org_id uuid := public.current_profile_org_id();
  v_before text := '';
  v_after text := '';
  v_approved integer := 0;
  v_week_total integer := 0;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected','more_info') then raise exception 'INVALID_DECISION'; end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_comment,''))) < 2 then raise exception 'COMMENT_REQUIRED'; end if;

  select * into v_request from public.correction_requests where id = p_request_id for update;
  if not found or v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_REVIEWABLE'; end if;
  if v_role <> 'super_admin' and v_request.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if exists (
    select 1 from public.monthly_closings closing
    where closing.org_id = v_request.org_id
      and closing.year = extract(year from v_request.target_date)
      and closing.month = extract(month from v_request.target_date)
      and closing.status = 'closed'
  ) and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  if p_decision = 'approved' and v_request.request_type in ('clock_in_at','clock_out_at') then
    select * into v_record from public.attendance_records
    where id = v_request.attendance_record_id
      and org_id = v_request.org_id
      and deleted_at is null for update;
    if not found and v_request.request_type = 'clock_in_at' then
      insert into public.attendance_records (employee_id, work_date, work_type, attendance_status, note, changed, org_id)
      values (v_request.employee_id, v_request.target_date, 'office', 'missing_out', '수정 요청으로 생성된 기록', true, v_request.org_id)
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
        and org_id = v_request.org_id
        and employee_id = v_request.employee_id
        and work_date = v_request.target_date
      for update;
      if not found or v_record.clock_out_at is null or coalesce(v_record.recorded_overtime_minutes,0) <= 0 then
        raise exception 'ACTUAL_OVERTIME_REQUIRED';
      end if;
      v_approved := least(v_request.calculated_minutes,v_record.recorded_overtime_minutes);
      select coalesce(sum(approved_minutes),0)::integer into v_week_total
      from public.correction_requests
      where org_id = v_request.org_id
        and employee_id = v_request.employee_id
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
      before_value, after_value, reason, changed_by, changed_by_role, correction_request_id, org_id
    ) values (
      coalesce(v_record.id,v_request.attendance_record_id),v_request.employee_id,'request_approved',v_request.request_type,
      v_before,v_after,coalesce(nullif(trim(p_comment),''),v_request.reason),auth.uid(),v_role,v_request.id,v_request.org_id
    );
  end if;

  update public.correction_requests
  set status = p_decision,
      reviewer_id = auth.uid(),
      reviewer_comment = coalesce(p_comment,''),
      reviewed_at = now()
  where id = p_request_id;
end $$;

create or replace function public.sync_attendance_leave_type_from_request()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_record record;
  v_leave_request public.correction_requests;
  v_leave_type text;
begin
  if new.request_type not in ('annual_leave','comp_time','special_leave','sick_leave','other_leave') then return new; end if;

  for v_record in
    select id, work_date
    from public.attendance_records
    where org_id = new.org_id
      and employee_id = new.employee_id
      and work_date between new.target_date and coalesce(new.end_date,new.target_date)
      and deleted_at is null
  loop
    v_leave_type := 'none';
    select request.* into v_leave_request
    from public.correction_requests request
    where request.org_id = new.org_id
      and request.employee_id = new.employee_id
      and request.status = 'approved'
      and request.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
      and request.target_date <= v_record.work_date
      and coalesce(request.end_date,request.target_date) >= v_record.work_date
    order by request.reviewed_at desc nulls last, request.requested_at desc
    limit 1;

    if found then
      if v_leave_request.request_type = 'annual_leave' then
        v_leave_type := case
          when v_leave_request.calculated_minutes >= 480 then 'annual_leave'
          when v_leave_request.calculated_minutes = 240 then 'half_day'
          when v_leave_request.calculated_minutes = 120 then 'quarter_day'
          when v_leave_request.calculated_minutes = 60 then 'hourly_leave'
          else 'none'
        end;
      elsif v_leave_request.request_type = 'sick_leave' then
        v_leave_type := 'sick_leave';
      end if;
    end if;

    update public.attendance_records
    set leave_type = v_leave_type, changed = true, updated_at = now()
    where id = v_record.id and leave_type is distinct from v_leave_type;
  end loop;
  return new;
end $$;

drop trigger if exists sync_attendance_leave_type_from_request_trigger on public.correction_requests;
create trigger sync_attendance_leave_type_from_request_trigger
after insert or update of status
on public.correction_requests
for each row execute function public.sync_attendance_leave_type_from_request();

revoke all on function public.admin_reopen_correction_request(uuid,text) from public,anon;
grant execute on function public.admin_reopen_correction_request(uuid,text) to authenticated;
revoke all on function public.review_correction_request(uuid,text,text) from public,anon;
grant execute on function public.review_correction_request(uuid,text,text) to authenticated;
notify pgrst, 'reload schema';
commit;

select '기관관리자 휴가 재검토와 출근부 반영 취소 보완 완료' as result;
