begin;

drop policy if exists "organization admins manage workplaces" on public.workplaces;
drop policy if exists "super admin manages workplaces" on public.workplaces;
create policy "super admin manages workplaces" on public.workplaces
for all to authenticated
using (public.is_super_admin()) with check (public.is_super_admin());

drop policy if exists "organization admins manage settings" on public.organization_settings;
drop policy if exists "super admin manages organization settings" on public.organization_settings;
create policy "super admin manages organization settings" on public.organization_settings
for all to authenticated
using (public.is_super_admin()) with check (public.is_super_admin());

revoke insert, update, delete on public.workplaces from authenticated;
revoke insert, update, delete on public.organization_settings from authenticated;
revoke all on function public.save_workplace_settings(text,double precision,double precision,integer,integer) from public, anon, authenticated;

-- 일반 근무조건은 이 제한된 함수로만 저장하며 사무실 IP는 바꿀 수 없습니다.
grant execute on function public.save_organization_settings(time,time,integer,integer,integer,text,boolean) to authenticated;

notify pgrst, 'reload schema';
commit;
