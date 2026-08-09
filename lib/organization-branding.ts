export interface OrganizationBrandingSource {
  org_code?: string | null;
  org_name?: string | null;
  short_name?: string | null;
  brand_title?: string | null;
  brand_short_title?: string | null;
  brand_description?: string | null;
  brand_subtitle?: string | null;
  brand_mark?: string | null;
  brand_logo_url?: string | null;
  brand_primary_color?: string | null;
  brand_accent_color?: string | null;
  brand_og_image_url?: string | null;
  support_email?: string | null;
}

export interface OrganizationBranding {
  orgCode: string;
  organizationName: string;
  shortName: string;
  title: string;
  shortTitle: string;
  description: string;
  subtitle: string;
  mark: string;
  logoUrl: string | null;
  primaryColor: string;
  accentColor: string;
  ogImageUrl: string | null;
}

export const DEFAULT_PRIMARY_COLOR = "#173f35";
export const DEFAULT_ACCENT_COLOR = "#d7e86b";
const HEX_COLOR = /^#[0-9a-f]{6}$/i;

function clean(value: string | null | undefined): string {
  return String(value || "").trim();
}

function color(value: string | null | undefined, fallback: string): string {
  const normalized = clean(value);
  return HEX_COLOR.test(normalized) ? normalized.toLowerCase() : fallback;
}

function assetUrl(value: string | null | undefined): string | null {
  const normalized = clean(value);
  if (!normalized) return null;
  if (normalized.startsWith("/") || /^https:\/\//i.test(normalized)) return normalized;
  return null;
}

export function organizationBranding(source?: OrganizationBrandingSource | null): OrganizationBranding {
  const shortName = clean(source?.short_name) || "기관";
  const organizationName = clean(source?.org_name) || shortName;
  const title = clean(source?.brand_title) || `${shortName} 근태관리`;
  return {
    orgCode: clean(source?.org_code),
    organizationName,
    shortName,
    title,
    shortTitle: clean(source?.brand_short_title) || title,
    description: clean(source?.brand_description) || `${organizationName} 출퇴근 기록과 월별 근태관리를 위한 내부 웹앱`,
    subtitle: clean(source?.brand_subtitle) || "안전한 내부 기록",
    mark: clean(source?.brand_mark).slice(0, 2) || shortName.slice(0, 1),
    logoUrl: assetUrl(source?.brand_logo_url),
    primaryColor: color(source?.brand_primary_color, DEFAULT_PRIMARY_COLOR),
    accentColor: color(source?.brand_accent_color, DEFAULT_ACCENT_COLOR),
    ogImageUrl: assetUrl(source?.brand_og_image_url),
  };
}
