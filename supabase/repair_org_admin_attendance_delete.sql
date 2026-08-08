-- 기관관리자가 자기 기관의 근태기록을 삭제 처리할 수 있게 보완합니다.
create or replace function public.admin_delete_attendance(p_record_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_before text;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_record.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if v_record.is_closed and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  v_before := jsonb_build_object('work_date',v_record.work_date,'clock_in_at',v_record.clock_in_at,'clock_out_at',v_record.clock_out_at,'work_type',v_record.work_type,'attendance_status',v_record.attendance_status,'note',v_record.note)::text;
  delete from public.attendance_events where employee_id = v_record.employee_id and work_date = v_record.work_date;
  update public.attendance_records set deleted_at = now(), deleted_by = auth.uid(), deletion_reason = trim(p_reason), updated_at = now() where id = p_record_id;
  insert into public.attendance_audit_logs (
    attendance_record_id, employee_id, action_type, changed_field, before_value, after_value,
    reason, changed_by, changed_by_role, org_id
  ) values (
    v_record.id, v_record.employee_id, 'admin_delete', 'attendance_record', v_before, '목록에서 삭제됨',
    trim(p_reason), auth.uid(), v_role, v_record.org_id
  );
end $$;

revoke all on function public.admin_delete_attendance(uuid,text) from public, anon;
grant execute on function public.admin_delete_attendance(uuid,text) to authenticated;
