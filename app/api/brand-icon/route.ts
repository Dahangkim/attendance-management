import { runtimeEnv } from "../_lib/runtime-env";
import { createServerSupabaseClient } from "../_lib/server-supabase";
import { resolveRequestOrganization } from "../_lib/organization-context";
import { organizationBranding } from "../../../lib/organization-branding";
import { deploymentBrandingSource } from "../../../lib/deployment-branding";

export const dynamic = "force-dynamic";

function escapeXml(value: string): string {
  return value.replace(/[<>&"']/g, (character) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;", "'": "&apos;" })[character] || character);
}

export async function GET(request: Request) {
  const supabaseUrl = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const secretKey = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  const organization = supabaseUrl && secretKey
    ? await resolveRequestOrganization(request, createServerSupabaseClient(supabaseUrl, secretKey), runtimeEnv.DEFAULT_ORG_CODE ?? process.env.DEFAULT_ORG_CODE)
    : null;
  const brand = organizationBranding(organization || deploymentBrandingSource());
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" role="img"><title>${escapeXml(brand.title)}</title><rect width="512" height="512" rx="112" fill="${brand.primaryColor}"/><rect x="70" y="70" width="372" height="372" rx="112" fill="${brand.accentColor}"/><text x="256" y="326" text-anchor="middle" font-family="Arial, Apple SD Gothic Neo, sans-serif" font-size="220" font-weight="800" fill="${brand.primaryColor}">${escapeXml(brand.mark)}</text></svg>`;
  return new Response(svg, { headers: { "Cache-Control": "public, max-age=300", "Content-Type": "image/svg+xml; charset=utf-8" } });
}
