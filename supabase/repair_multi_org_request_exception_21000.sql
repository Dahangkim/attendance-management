begin;

-- 다기관 전환 뒤 organization_settings가 여러 행이어도 신청 행의 기관 설정만 읽습니다.
create or replace function public.sync_approved_request_to_attendance_exception()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_default_start time := time '09:00';
  v_default_end time := time '18:00';
  v_end_date date := coalesce(new.end_date,new.target_date);
  v_exception_type text;
  v_should_create boolean := false;
begin
  select coalesce(settings.default_start_time,time '09:00'),
         coalesce(settings.default_end_time,time '18:00')
  into v_default_start,v_default_end
  from public.organization_settings settings
  where settings.org_id = new.org_id;
  v_default_start := coalesce(v_default_start,time '09:00');
  v_default_end := coalesce(v_default_end,time '18:00');

  if coalesce(new.before_value,'') = '관리자 직접 등록' then return new; end if;
  if new.status = 'approved' then
    if new.request_type = 'business_trip' then v_exception_type := 'business_trip'; v_should_create := true;
    elsif new.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
      and coalesce(new.start_time,v_default_start) <= v_default_start
      and coalesce(new.end_time,v_default_end) >= v_default_end then
      v_exception_type := new.request_type; v_should_create := true;
    end if;
  end if;
  if v_should_create then
    if not exists (select 1 from public.attendance_exceptions where correction_request_id = new.id and cancelled_at is null)
       and not exists (select 1 from public.attendance_exceptions where employee_id = new.employee_id and cancelled_at is null and start_date <= v_end_date and end_date >= new.target_date) then
      insert into public.attendance_exceptions (
        employee_id,start_date,end_date,exception_type,reason,approved_by,approved_at,correction_request_id
      ) values (
        new.employee_id,new.target_date,v_end_date,v_exception_type,
        case when new.request_type in ('special_leave','other_leave') then trim(new.request_subtype) || ': ' || trim(new.reason) else trim(new.reason) end,
        coalesce(new.reviewer_id,auth.uid()),coalesce(new.reviewed_at,now()),new.id
      );
    end if;
  else
    update public.attendance_exceptions
    set cancelled_at = coalesce(cancelled_at,now()),cancelled_by = coalesce(cancelled_by,auth.uid()),
        cancellation_reason = case when cancellation_reason = '' then '연결된 신청의 승인 상태 변경' else cancellation_reason end
    where correction_request_id = new.id and cancelled_at is null;
  end if;
  return new;
end $$;

notify pgrst, 'reload schema';

commit;

select '다기관 통합 요청 저장 오류 21000 보완 완료' as result;
