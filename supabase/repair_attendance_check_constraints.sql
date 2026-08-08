-- 출퇴근 저장 시 오류코드 23514가 발생할 때 전체를 한 번 실행합니다.
-- 기존 테이블에 남아 있는 예전 허용값 규칙만 현재 앱 기준으로 교체합니다.

begin;

do $$
declare
  item record;
begin
  for item in
    select conname
    from pg_constraint
    where conrelid = 'public.attendance_records'::regclass
      and contype = 'c'
      and (
        pg_get_constraintdef(oid) ilike '%clock_in_location_status%'
        or pg_get_constraintdef(oid) ilike '%clock_out_location_status%'
        or pg_get_constraintdef(oid) ilike '%attendance_status%'
      )
  loop
    execute format('alter table public.attendance_records drop constraint %I', item.conname);
  end loop;
end $$;

alter table public.attendance_records
  add constraint attendance_records_clock_in_location_status_check
  check (clock_in_location_status in (
    'inside', 'outside', 'low_accuracy', 'permission_denied', 'unavailable', 'not_checked'
  )) not valid;

alter table public.attendance_records
  add constraint attendance_records_clock_out_location_status_check
  check (clock_out_location_status in (
    'inside', 'outside', 'low_accuracy', 'permission_denied', 'unavailable', 'not_checked'
  )) not valid;

alter table public.attendance_records
  add constraint attendance_records_attendance_status_check
  check (attendance_status in (
    'normal', 'late', 'early_leave', 'absent', 'missing_in', 'missing_out',
    'location_review', 'admin_review', 'field', 'business_trip', 'education',
    'leave', 'holiday_work', 'working'
  )) not valid;

update public.work_type_settings
set is_active = true, updated_at = now()
where work_type = 'office';

notify pgrst, 'reload schema';
commit;

select conname, pg_get_constraintdef(oid) as rule
from pg_constraint
where conrelid = 'public.attendance_records'::regclass
  and conname in (
    'attendance_records_clock_in_location_status_check',
    'attendance_records_clock_out_location_status_check',
    'attendance_records_attendance_status_check'
  )
order by conname;
