begin;

-- 사전 승인된 대체휴무를 퇴근 시 적립할 때 필수 출처일과 조직을 함께 보존합니다.
create or replace function public.finalize_preapproved_overtime(p_request_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare
  v_request public.correction_requests;
  v_record public.attendance_records;
  v_overtime integer := 0;
  v_comp integer := 0;
  v_used integer := 0;
begin
  select * into v_request from public.correction_requests
  where id=p_request_id and request_type='overtime' and status='approved' for update;
  if not found then return; end if;

  select * into v_record from public.attendance_records
  where org_id=v_request.org_id and employee_id=v_request.employee_id
    and work_date=v_request.target_date and deleted_at is null for update;
  if not found or v_record.clock_out_at is null then return; end if;

  v_overtime := least(coalesce(v_record.recorded_overtime_minutes,0),v_request.overtime_approval_limit_minutes);
  v_comp := least(coalesce(v_record.recorded_overtime_minutes,0),v_request.comp_time_approval_limit_minutes);

  update public.correction_requests set attendance_record_id=v_record.id,
    approved_minutes=v_overtime,overtime_finalized_at=now() where id=v_request.id;
  update public.attendance_records set overtime_status='approved',
    approved_overtime_minutes=v_overtime,comp_time_eligible_minutes=v_comp,
    changed=true,updated_at=now() where id=v_record.id;

  if v_comp > 0 then
    insert into public.comp_time_credits(org_id,attendance_record_id,employee_id,source_type,source_date,
      granted_minutes,remaining_minutes,expires_on,granted_by,reason)
    values(v_request.org_id,v_record.id,v_request.employee_id,'overtime',v_record.work_date,
      v_comp,v_comp,v_record.work_date+30,v_request.reviewer_id,
      coalesce(nullif(trim(v_request.reviewer_comment),''),v_request.reason))
    on conflict(attendance_record_id) do update set
      org_id=excluded.org_id,employee_id=excluded.employee_id,
      source_type=excluded.source_type,source_date=excluded.source_date,
      granted_minutes=excluded.granted_minutes,
      remaining_minutes=greatest(0,excluded.granted_minutes-(public.comp_time_credits.granted_minutes-public.comp_time_credits.remaining_minutes)),
      expires_on=excluded.expires_on,granted_by=excluded.granted_by,granted_at=now(),reason=excluded.reason;
  else
    select coalesce(granted_minutes-remaining_minutes,0) into v_used
    from public.comp_time_credits where attendance_record_id=v_record.id;
    if v_used > 0 then raise exception 'COMP_TIME_ALREADY_USED'; end if;
    delete from public.comp_time_credits where attendance_record_id=v_record.id;
  end if;
end $$;

revoke all on function public.finalize_preapproved_overtime(uuid) from public,anon;
notify pgrst,'reload schema';
commit;

select '퇴근 시 대체휴무 출처일 저장 보완 완료' as result;
