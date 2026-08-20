begin;

create or replace function public.employee_cancel_correction_request(p_request_id uuid,p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_request public.correction_requests; v_actor public.profiles;
begin
  select * into v_actor from public.profiles where id = auth.uid() and role in ('employee','team_lead') and is_active = true;
  if not found then raise exception 'EMPLOYEE_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_request from public.correction_requests
  where id = p_request_id and employee_id = auth.uid() and request_type <> 'emergency_support' for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_CANCELLABLE'; end if;
  update public.correction_requests set status='cancelled',approved_minutes=0,reviewer_id=null,
    reviewer_comment='활동가 취소: '||trim(p_reason),reviewed_at=now() where id=p_request_id;
  insert into public.attendance_audit_logs(attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,reason,changed_by,changed_by_role,correction_request_id,org_id)
  values(v_request.attendance_record_id,v_request.employee_id,'request_cancelled',v_request.request_type,
    jsonb_build_object('status',v_request.status,'requested_value',v_request.requested_value)::text,
    jsonb_build_object('status','cancelled')::text,trim(p_reason),auth.uid(),v_actor.role,v_request.id,v_request.org_id);
end $$;

revoke all on function public.employee_cancel_correction_request(uuid,text) from public,anon;
grant execute on function public.employee_cancel_correction_request(uuid,text) to authenticated;
notify pgrst, 'reload schema';
commit;

select '활동가 근태 신청 취소 보완 완료' as result;
