import { runtimeEnv } from "../_lib/runtime-env";
import { createServerSupabaseClient } from "../_lib/server-supabase";
import { resolveRequestOrganization } from "../_lib/organization-context";
import { organizationBranding } from "../../../lib/organization-branding";
import { deploymentBrandingSource } from "../../../lib/deployment-branding";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const supabaseUrl = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const secretKey = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  const organization = supabaseUrl && secretKey
    ? await resolveRequestOrganization(request, createServerSupabaseClient(supabaseUrl, secretKey), runtimeEnv.DEFAULT_ORG_CODE ?? process.env.DEFAULT_ORG_CODE)
    : null;
  const brand = organizationBranding(organization || deploymentBrandingSource());
  const icon = brand.logoUrl || "/api/brand-icon";
  const iconType = brand.logoUrl
    ? /\.jpe?g(?:\?|$)/i.test(brand.logoUrl) ? "image/jpeg"
      : /\.webp(?:\?|$)/i.test(brand.logoUrl) ? "image/webp"
        : "image/png"
    : "image/svg+xml";
  const iconSizes = brand.logoUrl ? "192x192 512x512" : "any";
  return Response.json({
    name: brand.title,
    short_name: brand.shortTitle,
    description: brand.description,
    start_url: "/",
    display: "standalone",
    background_color: "#f3f2ec",
    theme_color: brand.primaryColor,
    lang: "ko",
    icons: [
      { src: icon, sizes: iconSizes, type: iconType, purpose: "any" },
      ...(!brand.logoUrl ? [{ src: icon, sizes: "512x512", type: iconType, purpose: "maskable" }] : []),
    ],
  }, { headers: { "Cache-Control": "no-store", "Content-Type": "application/manifest+json; charset=utf-8" } });
}
