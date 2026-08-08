begin;

-- 관리자가 출근 또는 퇴근시각을 비우면 해당 버튼을 다시 누를 수 있어야 합니다.
-- 실제 시각만 비우고 중복 방지 이벤트를 남겨 두면 재기록이 거부되므로 함께 정리합니다.
create or replace function public.cleanup_attendance_events_after_time_clear()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.clock_in_at is not null and new.clock_in_at is null then
    delete from public.attendance_events
    where employee_id = new.employee_id
      and work_date = new.work_date
      and action_type in ('clock_in','clock_out');
  elsif old.clock_out_at is not null and new.clock_out_at is null then
    delete from public.attendance_events
    where employee_id = new.employee_id
      and work_date = new.work_date
      and action_type = 'clock_out';
  end if;
  return new;
end
$$;

alter function public.cleanup_attendance_events_after_time_clear() owner to postgres;
revoke all on function public.cleanup_attendance_events_after_time_clear() from public, anon, authenticated;

drop trigger if exists attendance_cleanup_events_after_time_clear on public.attendance_records;
create trigger attendance_cleanup_events_after_time_clear
after update of clock_in_at, clock_out_at on public.attendance_records
for each row
when (old.clock_in_at is distinct from new.clock_in_at or old.clock_out_at is distinct from new.clock_out_at)
execute function public.cleanup_attendance_events_after_time_clear();

notify pgrst, 'reload schema';
commit;

select '출퇴근시각 삭제 후 재기록 보완 완료' as result;
