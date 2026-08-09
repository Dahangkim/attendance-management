begin;
alter table public.organizations add column if not exists support_email text;
alter table public.organizations drop constraint if exists organizations_support_email_check;
alter table public.organizations add constraint organizations_support_email_check
check (support_email is null or support_email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') not valid;
notify pgrst, 'reload schema';
commit;
