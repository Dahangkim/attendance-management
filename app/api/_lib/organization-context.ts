import type { SupabaseClient } from "@supabase/supabase-js";
import { normalizeHostname, organizationLookupDomain } from "../../../lib/organization-domain";

export interface ResolvedOrganization {
  id: string;
  org_code: string;
  org_name: string;
  short_name: string;
  domain: string | null;
  brand_title: string | null;
  brand_short_title: string | null;
  brand_description: string | null;
  brand_subtitle: string | null;
  brand_mark: string | null;
  brand_logo_url: string | null;
  brand_primary_color: string | null;
  brand_accent_color: string | null;
  brand_og_image_url: string | null;
}

const ORGANIZATION_FIELDS = "id,org_code,org_name,short_name,domain,brand_title,brand_short_title,brand_description,brand_subtitle,brand_mark,brand_logo_url,brand_primary_color,brand_accent_color,brand_og_image_url";

async function findOrganization(client: SupabaseClient, field: "domain" | "org_code", value: string) {
  const result = await client.from("organizations")
    .select(ORGANIZATION_FIELDS)
    .eq(field, value).eq("is_active", true).eq("organization_type", "facility").maybeSingle();
  return result.data;
}

async function findOrganizationByName(client: SupabaseClient, value: string) {
  const result = await client.from("organizations")
    .select(ORGANIZATION_FIELDS)
    .or(`org_name.ilike.*${value}*,short_name.ilike.*${value}*`)
    .eq("is_active", true).maybeSingle();
  return result.data;
}

async function findSuperAdminBranding(client: SupabaseClient): Promise<ResolvedOrganization | null> {
  const result = await client.from("profiles")
    .select("brand_title,brand_description,brand_subtitle,brand_mark,brand_logo_url,brand_primary_color,brand_accent_color")
    .eq("role", "super_admin").eq("is_active", true).limit(1).maybeSingle();
  if (!result.data) return null;
  const title = result.data.brand_title || "통합 근태관리";
  const shortName = title.replace(/\s*근태관리\s*$/, "").trim() || "통합관리";
  return {
    id: "00000000-0000-0000-0000-000000000000",
    org_code: "super-admin",
    org_name: shortName,
    short_name: shortName,
    domain: null,
    brand_title: result.data.brand_title,
    brand_short_title: result.data.brand_title,
    brand_description: result.data.brand_description,
    brand_subtitle: result.data.brand_subtitle,
    brand_mark: result.data.brand_mark,
    brand_logo_url: result.data.brand_logo_url,
    brand_primary_color: result.data.brand_primary_color,
    brand_accent_color: result.data.brand_accent_color,
    brand_og_image_url: null,
  };
}

export async function resolveRequestOrganization(
  request: Request,
  client: SupabaseClient,
  defaultOrgCode = "",
): Promise<ResolvedOrganization | null> {
  const hostname = normalizeHostname(request.headers.get("x-forwarded-host") || request.headers.get("host"));
  const domain = organizationLookupDomain(hostname);
  if (domain) {
    const data = await findOrganization(client, "domain", domain);
    if (data) return data as ResolvedOrganization;
  }

  const fallbackCode = defaultOrgCode.trim().toLowerCase();
  if (!fallbackCode) return null;
  if (fallbackCode === "super_admin" || fallbackCode === "super-admin") return findSuperAdminBranding(client);
  if (fallbackCode.startsWith("name:")) {
    const fallbackName = defaultOrgCode.trim().slice(5).trim();
    if (!fallbackName) return null;
    const named = await findOrganizationByName(client, fallbackName);
    return named ? named as ResolvedOrganization : null;
  }
  const data = await findOrganization(client, "org_code", fallbackCode);
  return data ? data as ResolvedOrganization : null;
}
