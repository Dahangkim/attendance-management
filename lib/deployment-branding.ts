import type { OrganizationBrandingSource } from "./organization-branding";

const value = (input: string | undefined, fallback: string) => input?.trim() || fallback;

export function deploymentBrandingSource(): OrganizationBrandingSource {
  const organizationName = value(process.env.NEXT_PUBLIC_APP_ORGANIZATION_NAME, "근태관리");
  const title = value(process.env.NEXT_PUBLIC_APP_TITLE, "근태관리");
  return {
    org_code: "",
    org_name: organizationName,
    short_name: value(process.env.NEXT_PUBLIC_APP_SHORT_TITLE, title),
    brand_title: title,
    brand_short_title: value(process.env.NEXT_PUBLIC_APP_SHORT_TITLE, title),
    brand_description: value(process.env.NEXT_PUBLIC_APP_DESCRIPTION, `${organizationName} 출퇴근 기록과 월별 근태관리를 위한 내부 웹앱`),
    brand_subtitle: value(process.env.NEXT_PUBLIC_APP_SUBTITLE, "안전한 내부 기록"),
    brand_mark: value(process.env.NEXT_PUBLIC_APP_MARK, "근태").slice(0, 2),
    brand_primary_color: process.env.NEXT_PUBLIC_APP_PRIMARY_COLOR,
    brand_accent_color: process.env.NEXT_PUBLIC_APP_ACCENT_COLOR,
  };
}
