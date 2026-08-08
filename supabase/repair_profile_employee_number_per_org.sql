-- 이전 파일명을 유지한 호환용 보완 SQL입니다.
-- 현재 로그인 정책은 전체 기관에서 직원 사번을 고유하게 사용합니다.

begin;

alter table public.profiles drop constraint if exists profiles_employee_number_key;
drop index if exists public.profiles_org_employee_number_unique_idx;
create unique index if not exists profiles_employee_number_global_unique_idx
  on public.profiles(upper(employee_number)) where role = 'employee';

commit;
