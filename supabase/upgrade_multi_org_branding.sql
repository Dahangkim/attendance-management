-- 멀티 조직 전환 3단계: 기관별 브랜딩 값을 한곳에서 관리한다.
-- 제목, 설명, 로고, 대표색은 organizations 행을 기준으로 제공한다.

begin;

alter table public.organizations add column if not exists brand_title text;
alter table public.organizations add column if not exists brand_short_title text;
alter table public.organizations add column if not exists brand_description text;
alter table public.organizations add column if not exists brand_subtitle text;
alter table public.organizations add column if not exists brand_mark text;
alter table public.organizations add column if not exists brand_logo_url text;
alter table public.organizations add column if not exists brand_primary_color text default '#173f35';
alter table public.organizations add column if not exists brand_accent_color text default '#d7e86b';
alter table public.organizations add column if not exists brand_og_image_url text;

update public.organizations
set brand_title = coalesce(nullif(trim(brand_title), ''), short_name || ' 근태관리'),
    brand_short_title = coalesce(nullif(trim(brand_short_title), ''), short_name || ' 근태'),
    brand_description = coalesce(nullif(trim(brand_description), ''), org_name || ' 출퇴근 기록과 월별 근태관리를 위한 내부 웹앱'),
    brand_subtitle = coalesce(nullif(trim(brand_subtitle), ''), '안전한 내부 기록'),
    brand_mark = coalesce(nullif(trim(brand_mark), ''), left(short_name, 1)),
    brand_primary_color = coalesce(nullif(trim(brand_primary_color), ''), '#173f35'),
    brand_accent_color = coalesce(nullif(trim(brand_accent_color), ''), '#d7e86b');

alter table public.organizations alter column brand_title set not null;
alter table public.organizations alter column brand_short_title set not null;
alter table public.organizations alter column brand_description set not null;
alter table public.organizations alter column brand_subtitle set not null;
alter table public.organizations alter column brand_mark set not null;
alter table public.organizations alter column brand_primary_color set not null;
alter table public.organizations alter column brand_accent_color set not null;

alter table public.organizations drop constraint if exists organizations_brand_primary_color_check;
alter table public.organizations add constraint organizations_brand_primary_color_check
  check (brand_primary_color ~ '^#[0-9A-Fa-f]{6}$');
alter table public.organizations drop constraint if exists organizations_brand_accent_color_check;
alter table public.organizations add constraint organizations_brand_accent_color_check
  check (brand_accent_color ~ '^#[0-9A-Fa-f]{6}$');

commit;
