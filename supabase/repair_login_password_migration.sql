begin;

alter table public.profiles
  add column if not exists must_change_password boolean not null default false;

create or replace function public.complete_required_password_change()
returns void
language sql
security invoker
set search_path = public
as $$
  update public.profiles
  set must_change_password = false,
      updated_at = now()
  where id = auth.uid();
$$;

revoke all on function public.complete_required_password_change() from public, anon;
grant execute on function public.complete_required_password_change() to authenticated;

notify pgrst, 'reload schema';

commit;
