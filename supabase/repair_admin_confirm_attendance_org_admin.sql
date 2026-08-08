-- 기관관리자도 자기 기관의 확인 필요 근태기록을 처리할 수 있게 보완합니다.
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
  if v_record.attendance_status not in ('admin_review','location_review','field','education') then raise exception 'RECORD_NOT_REVIEWABLE'; end if;

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

revoke all on function public.admin_confirm_attendance_record(uuid,text) from public, anon;
grant execute on function public.admin_confirm_attendance_record(uuid,text) to authenticated;
