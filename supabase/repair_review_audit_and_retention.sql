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
    select 1 from public.monthly_closings
    where org_id = v_request.org_id
      and year = extract(year from v_request.target_date)
      and month = extract(month from v_request.target_date)
      and status = 'closed'
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

create or replace function public.preview_attendance_retention_cleanup(p_delete_through_year integer)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_max_year integer := extract(year from timezone('Asia/Seoul',now()))::integer - 7;
  v_end_date date;
begin
  if v_role <> 'super_admin' then raise exception 'SUPER_ADMIN_REQUIRED'; end if;
  if p_delete_through_year < 1900 or p_delete_through_year > v_max_year then raise exception 'RETENTION_PERIOD_REQUIRED'; end if;
  v_end_date := make_date(p_delete_through_year,12,31);
  return jsonb_build_object(
    'delete_through_year',p_delete_through_year,
    'attendance_records',(select count(*) from public.attendance_records where work_date <= v_end_date),
    'correction_requests',(select count(*) from public.correction_requests where coalesce(end_date,target_date) <= v_end_date),
    'attendance_exceptions',(select count(*) from public.attendance_exceptions where end_date <= v_end_date),
    'audit_logs',(select count(*) from public.attendance_audit_logs where created_at < (v_end_date + 1)::timestamptz),
    'monthly_closings',(select count(*) from public.monthly_closings where year <= p_delete_through_year)
  );
end $$;

create or replace function public.purge_attendance_retention_data(
  p_delete_through_year integer,
  p_confirmation text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_actor uuid := auth.uid();
  v_actor_org uuid := public.current_profile_org_id();
  v_max_year integer := extract(year from timezone('Asia/Seoul',now()))::integer - 7;
  v_end_date date;
  v_record_ids uuid[] := array[]::uuid[];
  v_request_ids uuid[] := array[]::uuid[];
  v_credit_ids uuid[] := array[]::uuid[];
  v_records integer := 0;
  v_requests integer := 0;
  v_exceptions integer := 0;
  v_audits integer := 0;
begin
  if v_role <> 'super_admin' then raise exception 'SUPER_ADMIN_REQUIRED'; end if;
  if p_delete_through_year < 1900 or p_delete_through_year > v_max_year then raise exception 'RETENTION_PERIOD_REQUIRED'; end if;
  if trim(coalesce(p_confirmation,'')) <> p_delete_through_year::text || '년 이전 기록 영구 삭제' then raise exception 'CONFIRMATION_REQUIRED'; end if;
  v_end_date := make_date(p_delete_through_year,12,31);

  select coalesce(array_agg(id),array[]::uuid[]) into v_record_ids
  from public.attendance_records where work_date <= v_end_date;
  select coalesce(array_agg(id),array[]::uuid[]) into v_request_ids
  from public.correction_requests
  where coalesce(end_date,target_date) <= v_end_date or attendance_record_id = any(v_record_ids);
  select coalesce(array_agg(id),array[]::uuid[]) into v_credit_ids
  from public.comp_time_credits
  where attendance_record_id = any(v_record_ids);

  delete from public.attendance_audit_logs
  where created_at < (v_end_date + 1)::timestamptz
     or attendance_record_id = any(v_record_ids)
     or correction_request_id = any(v_request_ids);
  get diagnostics v_audits = row_count;
  delete from public.attendance_exceptions where end_date <= v_end_date or correction_request_id = any(v_request_ids);
  get diagnostics v_exceptions = row_count;
  delete from public.comp_time_usage_allocations where correction_request_id = any(v_request_ids) or credit_id = any(v_credit_ids);
  delete from public.comp_time_credits where id = any(v_credit_ids);
  delete from public.correction_requests where id = any(v_request_ids);
  get diagnostics v_requests = row_count;
  delete from public.attendance_locations where attendance_record_id = any(v_record_ids);
  delete from public.attendance_events where attendance_record_id = any(v_record_ids);
  delete from public.attendance_records where id = any(v_record_ids);
  get diagnostics v_records = row_count;
  delete from public.employee_schedule_overrides where work_date <= v_end_date;
  delete from public.annual_leave_entitlements where valid_to <= v_end_date;
  delete from public.monthly_closings where year <= p_delete_through_year;

  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,reason,
    changed_by,changed_by_role,org_id
  ) values (
    v_actor,'attendance_retention_purged','retention_period','보존 중',
    jsonb_build_object('delete_through_year',p_delete_through_year,'attendance_records',v_records,'correction_requests',v_requests,'attendance_exceptions',v_exceptions,'audit_logs',v_audits)::text,
    p_delete_through_year::text || '년 이전 보존기간 경과 기록 영구 삭제',v_actor,v_role,v_actor_org
  );
  return jsonb_build_object('delete_through_year',p_delete_through_year,'attendance_records',v_records,'correction_requests',v_requests,'attendance_exceptions',v_exceptions,'audit_logs',v_audits);
end $$;

revoke all on function public.admin_reopen_correction_request(uuid,text) from public,anon;
grant execute on function public.admin_reopen_correction_request(uuid,text) to authenticated;
revoke all on function public.preview_attendance_retention_cleanup(integer) from public,anon;
grant execute on function public.preview_attendance_retention_cleanup(integer) to authenticated;
revoke all on function public.purge_attendance_retention_data(integer,text) from public,anon;
grant execute on function public.purge_attendance_retention_data(integer,text) to authenticated;

notify pgrst, 'reload schema';
commit;
