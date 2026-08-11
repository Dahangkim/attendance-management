begin;

alter table public.organizations
  add column if not exists mobile_org_admin_access_enabled boolean not null default true;

update public.organizations
set mobile_org_admin_access_enabled = true
where mobile_org_admin_access_enabled is null;

notify pgrst, 'reload schema';
commit;

select '기관별 기관관리자 모바일 접속 설정 추가 완료' as result;
