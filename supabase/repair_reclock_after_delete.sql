-- 같은 날짜의 삭제된 기록을 다시 출근으로 복원할 때 실행되는 안전장치입니다.
-- 삭제 당시 남아 있던 이전 퇴근값을 새 출근 기록에 섞지 않도록 초기화합니다.

begin;

create or replace function public.clear_old_clock_out_when_reclocking()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.deleted_at is not null
    and new.deleted_at is null
    and new.clock_in_at is distinct from old.clock_in_at
  then
    new.clock_out_at := null;
    new.clock_out_accuracy := null;
    new.clock_out_distance := null;
    new.clock_out_location_status := 'not_checked';
    new.clock_out_ip_address := null;
    new.clock_out_ip_matched := false;
  end if;
  return new;
end $$;

drop trigger if exists attendance_clear_old_clock_out_when_reclocking
on public.attendance_records;

create trigger attendance_clear_old_clock_out_when_reclocking
before update on public.attendance_records
for each row
execute function public.clear_old_clock_out_when_reclocking();

notify pgrst, 'reload schema';
commit;

select
  trigger_name,
  event_manipulation,
  action_timing
from information_schema.triggers
where event_object_schema = 'public'
  and event_object_table = 'attendance_records'
  and trigger_name = 'attendance_clear_old_clock_out_when_reclocking';
