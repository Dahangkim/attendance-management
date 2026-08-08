import { runtimeEnv } from "../_lib/runtime-env";
import { createServerSupabaseClient } from "../_lib/server-supabase";
import { resolveRequestOrganization } from "../_lib/organization-context";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const supabaseUrl = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const secretKey = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!supabaseUrl || !secretKey) return Response.json({ organization: null, code: "ORGANIZATION_CONTEXT_NOT_CONFIGURED" }, { status: 503, headers: { "Cache-Control": "no-store" } });
  const client = createServerSupabaseClient(supabaseUrl, secretKey);
  const organization = await resolveRequestOrganization(request, client, runtimeEnv.DEFAULT_ORG_CODE ?? process.env.DEFAULT_ORG_CODE);
  if (!organization) return Response.json({ organization: null, code: "ORGANIZATION_NOT_FOUND" }, { status: 404, headers: { "Cache-Control": "no-store" } });
  return Response.json({ organization }, { headers: { "Cache-Control": "no-store" } });
}
