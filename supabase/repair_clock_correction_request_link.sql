begin;

create or replace function public.link_clock_correction_request_to_attendance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.request_type not in ('clock_in_at', 'clock_out_at') then
    return new;
  end if;

  if new.attendance_record_id is null then
    select record.id
    into new.attendance_record_id
    from public.attendance_records record
    where record.org_id = new.org_id
      and record.employee_id = new.employee_id
      and record.work_date = new.target_date
      and record.deleted_at is null
    order by record.created_at desc
    limit 1;
  end if;

  return new;
end;
$$;

drop trigger if exists link_clock_correction_request_to_attendance_trigger
on public.correction_requests;

create trigger link_clock_correction_request_to_attendance_trigger
before insert or update of attendance_record_id, employee_id, target_date, request_type
on public.correction_requests
for each row
execute function public.link_clock_correction_request_to_attendance();

update public.correction_requests request
set attendance_record_id = record.id
from public.attendance_records record
where request.request_type in ('clock_in_at', 'clock_out_at')
  and request.status in ('pending', 'more_info')
  and request.attendance_record_id is null
  and record.org_id = request.org_id
  and record.employee_id = request.employee_id
  and record.work_date = request.target_date
  and record.deleted_at is null;

notify pgrst, 'reload schema';
commit;

select '출퇴근 시각 수정 신청과 근태기록 연결 보완 완료' as result;
