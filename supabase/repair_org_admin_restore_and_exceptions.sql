begin;

create or replace function public.admin_restore_attendance(
  p_record_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_record.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
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
    before_value, after_value, reason, changed_by, changed_by_role, org_id
  ) values (
    v_record.id, v_record.employee_id, 'admin_restore', 'attendance_record',
    '삭제됨', '기록 복원됨', trim(p_reason), auth.uid(), v_role, v_record.org_id
  );
end $$;

create or replace function public.admin_create_attendance_exception(
  p_employee_id uuid,
  p_start_date date,
  p_end_date date,
  p_exception_type text,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_employee_org_id uuid;
  v_id uuid;
  v_request_id uuid;
  v_request_reason text;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_end_date < p_start_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_exception_type not in ('business_trip','approved_other','annual_leave','comp_time','special_leave','sick_leave','other_leave') then raise exception 'INVALID_EXCEPTION_TYPE'; end if;
  if p_exception_type in ('special_leave','other_leave') and char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;

  select org_id into v_employee_org_id from public.profiles
  where id = p_employee_id and role = 'employee' and is_active = true;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_employee_org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;

  if exists (
    select 1 from public.attendance_exceptions
    where employee_id = p_employee_id and org_id = v_employee_org_id
      and cancelled_at is null and start_date <= p_end_date and end_date >= p_start_date
  ) then raise exception 'EXCEPTION_OVERLAP'; end if;

  if p_exception_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave') then
    v_request_reason := case p_exception_type
      when 'annual_leave' then '관리자 직접 등록 종일 연차'
      when 'comp_time' then '관리자 직접 등록 종일 대체휴무'
      when 'special_leave' then '관리자 직접 등록 종일 특별휴가'
      when 'sick_leave' then '관리자 직접 등록 종일 병가'
      else '관리자 직접 등록 ' || trim(p_reason)
    end;
    insert into public.correction_requests (
      employee_id, target_date, end_date, start_time, end_time,
      request_type, request_subtype, before_value, requested_value, reason,
      status, reviewer_id, reviewer_comment, reviewed_at, org_id
    ) values (
      p_employee_id, p_start_date, p_end_date, time '09:00', time '18:00',
      p_exception_type,
      case when p_exception_type in ('special_leave','other_leave') then trim(p_reason) else '' end,
      '관리자 직접 등록', '0', v_request_reason,
      'approved', auth.uid(), v_request_reason, now(), v_employee_org_id
    ) returning id into v_request_id;
    update public.correction_requests set approved_minutes = calculated_minutes where id = v_request_id;
  end if;

  insert into public.attendance_exceptions (
    employee_id, start_date, end_date, exception_type, reason,
    approved_by, correction_request_id, org_id
  ) values (
    p_employee_id, p_start_date, p_end_date, p_exception_type,
    trim(coalesce(p_reason,'')), auth.uid(), v_request_id, v_employee_org_id
  ) returning id into v_id;

  insert into public.attendance_audit_logs (
    employee_id, action_type, changed_field, before_value, after_value,
    reason, changed_by, changed_by_role, correction_request_id, org_id
  ) values (
    p_employee_id, 'exception_create', 'attendance_exception', '',
    jsonb_build_object('id',v_id,'start_date',p_start_date,'end_date',p_end_date,'exception_type',p_exception_type)::text,
    trim(coalesce(p_reason,'')), auth.uid(), v_role, v_request_id, v_employee_org_id
  );
  return v_id;
end $$;

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
  v_org_id uuid := public.current_profile_org_id();
  v_employee_id uuid;
  v_employee_name text;
  v_employee_org_id uuid;
  v_work_date date;
  v_record_id uuid;
  v_created integer := 0;
  v_skipped_names text[] := array[]::text[];
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if coalesce(array_length(p_employee_ids,1),0) = 0 then raise exception 'EMPLOYEE_REQUIRED'; end if;
  if p_end_date < p_start_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_exception_type not in ('business_trip','external_training','approved_other','annual_leave','comp_time','special_leave','sick_leave','other_leave') then raise exception 'INVALID_EXCEPTION_TYPE'; end if;
  if p_exception_type in ('external_training','special_leave','other_leave') and char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;

  foreach v_employee_id in array p_employee_ids loop
    select name, org_id into v_employee_name, v_employee_org_id from public.profiles
    where id = v_employee_id and role = 'employee' and is_active = true;
    if not found or (v_role <> 'super_admin' and v_employee_org_id is distinct from v_org_id) then
      raise exception 'ORGANIZATION_ACCESS_DENIED';
    end if;

    if p_exception_type = 'external_training' then
      for v_work_date in select generate_series(p_start_date,p_end_date,interval '1 day')::date loop
        v_record_id := null;
        if exists (select 1 from public.attendance_records where employee_id = v_employee_id and work_date = v_work_date and deleted_at is null) then
          v_skipped_names := array_append(v_skipped_names,v_employee_name || ' ' || v_work_date::text);
          continue;
        end if;
        insert into public.attendance_records (
          employee_id,work_date,work_type,clock_in_at,clock_out_at,
          clock_in_location_status,clock_out_location_status,attendance_status,note,changed,org_id
        ) values (
          v_employee_id,v_work_date,'education',
          (v_work_date + time '09:00') at time zone 'Asia/Seoul',
          (v_work_date + time '18:00') at time zone 'Asia/Seoul',
          'not_checked','not_checked','normal','',true,v_employee_org_id
        ) on conflict (employee_id,work_date) do update set
          work_type = 'education', clock_in_at = excluded.clock_in_at,
          clock_out_at = excluded.clock_out_at, clock_in_location_status = 'not_checked',
          clock_out_location_status = 'not_checked', attendance_status = 'normal',
          note = '', changed = true, deleted_at = null, updated_at = now()
        where attendance_records.deleted_at is not null
        returning id into v_record_id;
        if v_record_id is null then
          v_skipped_names := array_append(v_skipped_names,v_employee_name || ' ' || v_work_date::text);
          continue;
        end if;
        insert into public.attendance_audit_logs (
          attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
          reason,changed_by,changed_by_role,org_id
        ) values (
          v_record_id,v_employee_id,'external_training_record_create','attendance_record','',
          jsonb_build_object('work_date',v_work_date,'clock_in_time','09:00','clock_out_time','18:00')::text,
          trim(coalesce(p_reason,'')),auth.uid(),v_role,v_employee_org_id
        );
        v_created := v_created + 1;
      end loop;
    elsif exists (
      select 1 from public.attendance_exceptions
      where employee_id = v_employee_id and org_id = v_employee_org_id and cancelled_at is null
        and start_date <= p_end_date and end_date >= p_start_date
    ) then
      v_skipped_names := array_append(v_skipped_names,v_employee_name);
    else
      perform public.admin_create_attendance_exception(v_employee_id,p_start_date,p_end_date,p_exception_type,p_reason);
      v_created := v_created + 1;
    end if;
  end loop;
  return jsonb_build_object('created_count',v_created,'skipped_count',coalesce(array_length(v_skipped_names,1),0),'skipped_names',to_jsonb(v_skipped_names));
end $$;

create or replace function public.admin_cancel_attendance_exception(
  p_exception_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_item public.attendance_exceptions;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_item from public.attendance_exceptions
  where id = p_exception_id and cancelled_at is null for update;
  if not found then raise exception 'EXCEPTION_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_item.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;

  update public.attendance_exceptions set
    cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = trim(p_reason)
  where id = p_exception_id;
  if v_item.correction_request_id is not null then
    update public.correction_requests set
      status = 'rejected', reviewer_id = auth.uid(),
      reviewer_comment = '예외 일정 취소: ' || trim(p_reason), reviewed_at = now(), approved_minutes = 0
    where id = v_item.correction_request_id and org_id = v_item.org_id;
  end if;
  insert into public.attendance_audit_logs (
    employee_id, action_type, changed_field, before_value, after_value,
    reason, changed_by, changed_by_role, correction_request_id, org_id
  ) values (
    v_item.employee_id, 'exception_cancel', 'attendance_exception',
    jsonb_build_object('id',v_item.id,'start_date',v_item.start_date,'end_date',v_item.end_date,'exception_type',v_item.exception_type)::text,
    '취소됨', trim(p_reason), auth.uid(), v_role, v_item.correction_request_id, v_item.org_id
  );
end $$;

revoke all on function public.admin_restore_attendance(uuid,text) from public, anon;
grant execute on function public.admin_restore_attendance(uuid,text) to authenticated;
revoke all on function public.admin_create_attendance_exception(uuid,date,date,text,text) from public, anon;
grant execute on function public.admin_create_attendance_exception(uuid,date,date,text,text) to authenticated;
revoke all on function public.admin_create_attendance_exceptions(uuid[],date,date,text,text) from public, anon;
grant execute on function public.admin_create_attendance_exceptions(uuid[],date,date,text,text) to authenticated;
revoke all on function public.admin_cancel_attendance_exception(uuid,text) from public, anon;
grant execute on function public.admin_cancel_attendance_exception(uuid,text) to authenticated;

notify pgrst, 'reload schema';
commit;
