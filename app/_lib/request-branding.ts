import { cache } from "react";
import { headers } from "next/headers";
import { createServerSupabaseClient } from "../api/_lib/server-supabase";
import { resolveRequestOrganization } from "../api/_lib/organization-context";
import { organizationBranding } from "../../lib/organization-branding";
import { deploymentBrandingSource } from "../../lib/deployment-branding";

export const getRequestBranding = cache(async () => {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") || requestHeaders.get("host") || "localhost:3000";
  const protocol = requestHeaders.get("x-forwarded-proto") || (host.startsWith("localhost") ? "http" : "https");
  const runtimeEnv = process.env as Record<string, string | undefined>;
  const supabaseUrl = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const secretKey = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  let organization = null;
  if (supabaseUrl && secretKey) {
    const client = createServerSupabaseClient(supabaseUrl, secretKey);
    const request = new Request(`${protocol}://${host}`, { headers: requestHeaders });
    organization = await resolveRequestOrganization(request, client, runtimeEnv.DEFAULT_ORG_CODE ?? process.env.DEFAULT_ORG_CODE);
  }
  return { branding: organizationBranding(organization || deploymentBrandingSource()), organization, metadataBase: new URL(`${protocol}://${host}`) };
});
