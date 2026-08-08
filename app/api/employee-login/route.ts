import { runtimeEnv } from "../_lib/runtime-env";
import { createServerSupabaseClient } from "../_lib/server-supabase";

export const dynamic = "force-dynamic";

const ORGANIZATION_FIELDS = "id,org_code,org_name,short_name,domain,brand_title,brand_short_title,brand_description,brand_subtitle,brand_mark,brand_logo_url,brand_primary_color,brand_accent_color,brand_og_image_url";
const responseHeaders = { "Cache-Control": "no-store" };
const json = (body: Record<string, unknown>, status = 200) => Response.json(body, { status, headers: responseHeaders });

export async function POST(request: Request) {
  const supabaseUrl = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey = runtimeEnv.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  const secretKey = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!supabaseUrl || !publishableKey || !secretKey) return json({ ok: false, code: "LOGIN_NOT_CONFIGURED" }, 503);

  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const employeeNumber = typeof body?.employeeNumber === "string" ? body.employeeNumber.trim().toUpperCase() : "";
  const password = typeof body?.password === "string" ? body.password : "";
  if (!/^[A-Z0-9-]{2,30}$/.test(employeeNumber) || password.length < 1 || password.length > 200) {
    return json({ ok: false, code: "INVALID_CREDENTIALS" }, 401);
  }

  const adminClient = createServerSupabaseClient(supabaseUrl, secretKey);
  const { data: profiles, error: profileError } = await adminClient.from("profiles")
    .select("id,email,is_active,org_id,role")
    .ilike("employee_number", employeeNumber)
    .in("role", ["employee", "team_lead", "org_admin", "admin", "super_admin"])
    .limit(2);
  if (profileError || profiles?.length !== 1 || !profiles[0].is_active) {
    return json({ ok: false, code: "INVALID_CREDENTIALS" }, 401);
  }
  const profile = profiles[0];
  let organization = null;
  if (profile.role !== "super_admin") {
    if (!profile.org_id) return json({ ok: false, code: "INVALID_CREDENTIALS" }, 401);
    const { data: activeOrganization } = await adminClient.from("organizations")
      .select(ORGANIZATION_FIELDS)
      .eq("id", profile.org_id)
      .eq("is_active", true)
      .maybeSingle();
    if (!activeOrganization) return json({ ok: false, code: "INVALID_CREDENTIALS" }, 401);
    organization = activeOrganization;
  }

  const { data: authUserData, error: authUserError } = await adminClient.auth.admin.getUserById(profile.id);
  const authEmail = authUserData.user?.email;
  if (authUserError || !authEmail) return json({ ok: false, code: "INVALID_CREDENTIALS" }, 401);
  const authClient = createServerSupabaseClient(supabaseUrl, publishableKey);
  const { data: authData, error: authError } = await authClient.auth.signInWithPassword({ email: authEmail, password });
  if (authError || !authData.session || authData.user.id !== profile.id) return json({ ok: false, code: "INVALID_CREDENTIALS" }, 401);

  return json({
    ok: true,
    organization,
    session: {
      access_token: authData.session.access_token,
      refresh_token: authData.session.refresh_token,
    },
  });
}
