begin;

create table if not exists public.admin_login_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references public.organizations(id) on delete restrict,
  profile_id uuid not null references public.profiles(id) on delete restrict,
  role text not null check (role in ('org_admin', 'admin', 'super_admin')),
  ip_address text not null check (char_length(ip_address) between 2 and 64),
  device_info text not null default '' check (char_length(device_info) <= 500),
  created_at timestamptz not null default now()
);

create index if not exists admin_login_logs_created_idx on public.admin_login_logs (created_at desc);
create index if not exists admin_login_logs_org_created_idx on public.admin_login_logs (org_id, created_at desc);

alter table public.admin_login_logs enable row level security;
drop policy if exists "admin login history read" on public.admin_login_logs;
create policy "admin login history read" on public.admin_login_logs
  for select to authenticated
  using (
    public.current_profile_role() = 'super_admin'
    or (
      public.current_profile_role() in ('admin', 'org_admin')
      and profile_id = auth.uid()
    )
  );

revoke all on public.admin_login_logs from public, anon;
grant select on public.admin_login_logs to authenticated;
notify pgrst, 'reload schema';
commit;

select '관리자 로그인 이력 적용 완료' as result;
