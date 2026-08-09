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
  support_email: string | null;
}

const ORGANIZATION_FIELDS = "id,org_code,org_name,short_name,domain,brand_title,brand_short_title,brand_description,brand_subtitle,brand_mark,brand_logo_url,brand_primary_color,brand_accent_color,brand_og_image_url,support_email";
const LEGACY_ORGANIZATION_FIELDS = ORGANIZATION_FIELDS.replace(",support_email", "");

async function findOrganization(client: SupabaseClient, field: "domain" | "org_code", value: string) {
  let result = await client.from("organizations")
    .select(ORGANIZATION_FIELDS)
    .eq(field, value).eq("is_active", true).eq("organization_type", "facility").maybeSingle();
  if (result.error?.code === "42703") {
    result = await client.from("organizations")
      .select(LEGACY_ORGANIZATION_FIELDS)
      .eq(field, value).eq("is_active", true).eq("organization_type", "facility").maybeSingle() as typeof result;
  }
  return result.data ? { ...result.data, support_email: result.data.support_email ?? null } : null;
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
  const data = await findOrganization(client, "org_code", fallbackCode);
  return data ? data as ResolvedOrganization : null;
}
