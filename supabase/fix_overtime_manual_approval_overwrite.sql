begin;

-- 관리자가 실제 인정 가능시간보다 적게 승인한 경우 승인값을 유지합니다.
-- 예: 실제 인정 가능 3시간, 관리자 승인 2시간이면 최종 승인도 2시간입니다.
create or replace function public.sync_overtime_request_to_attendance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_record public.attendance_records;
  v_final integer := 0;
begin
  if new.request_type <> 'overtime' then
    return new;
  end if;

  if new.status = 'approved' then
    select *
    into v_record
    from public.attendance_records
    where deleted_at is null
      and employee_id = new.employee_id
      and work_date = new.target_date
    for update;

    if not found
       or v_record.clock_out_at is null
       or coalesce(v_record.recorded_overtime_minutes,0) <= 0 then
      raise exception 'ACTUAL_OVERTIME_REQUIRED';
    end if;

    v_final := least(
      240,
      coalesce(nullif(new.approved_minutes,0),new.calculated_minutes,0),
      v_record.recorded_overtime_minutes
    );
    if v_final <= 0 then
      raise exception 'ACTUAL_OVERTIME_REQUIRED';
    end if;

    update public.correction_requests
    set attendance_record_id = v_record.id,
        approved_minutes = v_final
    where id = new.id;

    if v_record.overtime_status <> 'approved'
       or v_record.approved_overtime_minutes <> v_final
       or v_record.comp_time_eligible_minutes <> 0 then
      update public.attendance_records
      set overtime_status = 'approved',
          approved_overtime_minutes = v_final,
          comp_time_eligible_minutes = 0,
          changed = true,
          updated_at = now()
      where id = v_record.id;

      insert into public.attendance_audit_logs (
        attendance_record_id,employee_id,action_type,changed_field,
        before_value,after_value,reason,changed_by,changed_by_role,
        correction_request_id
      ) values (
        v_record.id,new.employee_id,'overtime_review','approved_overtime_minutes',
        jsonb_build_object(
          'status',v_record.overtime_status,
          'minutes',v_record.approved_overtime_minutes
        )::text,
        jsonb_build_object(
          'status','approved',
          'requested_minutes',new.calculated_minutes,
          'actual_minutes',v_record.recorded_overtime_minutes,
          'approved_minutes',v_final
        )::text,
        coalesce(nullif(trim(new.reviewer_comment),''),new.reason),
        coalesce(new.reviewer_id,auth.uid()),
        public.current_profile_role(),
        new.id
      );
    end if;
  elsif tg_op = 'UPDATE'
        and old.status = 'approved'
        and new.status <> 'approved' then
    update public.attendance_records
    set overtime_status = case
          when recorded_overtime_minutes > 0 then 'pending'
          else 'none'
        end,
        approved_overtime_minutes = 0,
        comp_time_eligible_minutes = 0,
        changed = true,
        updated_at = now()
    where employee_id = new.employee_id
      and work_date = new.target_date
      and deleted_at is null;
  end if;

  return new;
end
$$;

drop trigger if exists sync_overtime_request_to_attendance_trigger
on public.correction_requests;
create trigger sync_overtime_request_to_attendance_trigger
after insert or update of status
on public.correction_requests
for each row
execute function public.sync_overtime_request_to_attendance();

revoke all on function public.sync_overtime_request_to_attendance() from public, anon;
grant execute on function public.sync_overtime_request_to_attendance() to authenticated;

notify pgrst, 'reload schema';
commit;

select '관리자 시간외근무 승인값 덮어쓰기 보완 완료' as result;
