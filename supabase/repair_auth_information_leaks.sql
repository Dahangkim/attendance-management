begin;

-- 비밀번호 변경을 마친 로그인 사용자는 자신의 상태만 완료할 수 있습니다.
create or replace function public.complete_required_password_change()
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  update public.profiles
  set must_change_password = false, updated_at = now()
  where id = auth.uid();
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
end $$;

revoke all on function public.complete_required_password_change() from public,anon;
grant execute on function public.complete_required_password_change() to authenticated;

-- 이 함수는 다른 보안 함수와 트리거가 내부적으로만 사용합니다.
-- 임의 직원 UUID를 넣어 출근 관련 정보를 추측하지 못하도록 직접 RPC 권한을 제거합니다.
revoke all on function public.emergency_support_time_overlaps(uuid,date,date,time,time,uuid)
from public,anon,authenticated;

notify pgrst, 'reload schema';
commit;

select '로그인 정보노출과 내부 긴급지원 함수 권한 보완 완료' as result;

