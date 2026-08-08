-- 최고관리자 계정의 독립 로고와 색상을 저장합니다.
begin;

alter table public.profiles add column if not exists brand_title text;
alter table public.profiles add column if not exists brand_description text;
alter table public.profiles add column if not exists brand_subtitle text;
alter table public.profiles add column if not exists brand_mark text;
alter table public.profiles add column if not exists brand_logo_url text;
alter table public.profiles add column if not exists brand_primary_color text;
alter table public.profiles add column if not exists brand_accent_color text;

alter table public.profiles drop constraint if exists profiles_brand_primary_color_check;
alter table public.profiles add constraint profiles_brand_primary_color_check
  check (brand_primary_color is null or brand_primary_color ~ '^#[0-9A-Fa-f]{6}$');
alter table public.profiles drop constraint if exists profiles_brand_accent_color_check;
alter table public.profiles add constraint profiles_brand_accent_color_check
  check (brand_accent_color is null or brand_accent_color ~ '^#[0-9A-Fa-f]{6}$');

commit;
