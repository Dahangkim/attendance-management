import { runtimeEnv } from "../_lib/runtime-env";
import { createServerSupabaseClient } from "../_lib/server-supabase";
import { toSupabasePassword } from "../../../lib/auth-password";

export const dynamic = "force-dynamic";

const ORGANIZATION_FIELDS = "id,org_code,org_name,short_name,domain,mobile_org_admin_access_enabled,brand_title,brand_short_title,brand_description,brand_subtitle,brand_mark,brand_logo_url,brand_primary_color,brand_accent_color,brand_og_image_url";
const responseHeaders = { "Cache-Control": "no-store" };
const json = (body: Record<string, unknown>, status = 200) => Response.json(body, { status, headers: responseHeaders });
const rejectLogin = () => json({ ok: false, code: "INVALID_CREDENTIALS" }, 401);

const requestIpAddress = (request: Request) => {
  const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  return (request.headers.get("cf-connecting-ip") || forwarded || request.headers.get("x-real-ip") || "확인 불가").slice(0, 64);
};

export async function POST(request: Request) {
  const supabaseUrl = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey = runtimeEnv.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  const secretKey = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!supabaseUrl || !publishableKey || !secretKey) return json({ ok: false, code: "LOGIN_NOT_CONFIGURED" }, 503);

  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const identifier = typeof body?.identifier === "string"
    ? body.identifier.trim()
    : typeof body?.employeeNumber === "string"
      ? body.employeeNumber.trim()
      : "";
  const password = typeof body?.password === "string" ? body.password : "";
  const isEmail = identifier.includes("@");
  const employeeNumber = identifier.toUpperCase();
  if ((!isEmail && !/^[A-Z0-9-]{2,30}$/.test(employeeNumber)) || password.length < 1 || password.length > 200) {
    return rejectLogin();
  }

  const adminClient = createServerSupabaseClient(supabaseUrl, secretKey);
  let profileQuery = adminClient.from("profiles")
    .select("id,email,is_active,org_id,role")
    .in("role", ["employee", "team_lead", "org_admin", "admin", "super_admin"])
    .limit(2);
  profileQuery = isEmail
    ? profileQuery.ilike("email", identifier)
    : profileQuery.ilike("employee_number", employeeNumber);
  const { data: profiles, error: profileError } = await profileQuery;
  if (profileError || profiles?.length !== 1 || !profiles[0].is_active) {
    return rejectLogin();
  }
  const profile = profiles[0];
  let organization = null;
  if (profile.role !== "super_admin") {
    if (!profile.org_id) return rejectLogin();
    const { data: activeOrganization } = await adminClient.from("organizations")
      .select(ORGANIZATION_FIELDS)
      .eq("id", profile.org_id)
      .eq("is_active", true)
      .maybeSingle();
    if (!activeOrganization) return rejectLogin();
    organization = activeOrganization;
  }

  const { data: authUserData, error: authUserError } = await adminClient.auth.admin.getUserById(profile.id);
  const authEmail = authUserData.user?.email;
  if (authUserError || !authEmail) return rejectLogin();
  const authClient = createServerSupabaseClient(supabaseUrl, publishableKey);
  const { data: authData, error: authError } = await authClient.auth.signInWithPassword({ email: authEmail, password: toSupabasePassword(password) });
  if (authError || !authData.session || authData.user.id !== profile.id) return rejectLogin();
  const mobileRequest = /Android|iPhone|iPad|iPod|Mobile/i.test(request.headers.get("user-agent") || "");
  if (["org_admin", "admin"].includes(profile.role) && mobileRequest && organization?.mobile_org_admin_access_enabled === false) {
    return json({ ok: false, code: "MOBILE_ORG_ADMIN_DISABLED" }, 403);
  }
  if (["org_admin", "admin", "super_admin"].includes(profile.role)) {
    try {
      const { error: loginLogError } = await adminClient.from("admin_login_logs").insert({
        org_id: profile.role === "super_admin" ? null : profile.org_id,
        profile_id: profile.id,
        role: profile.role,
        ip_address: requestIpAddress(request),
        device_info: (request.headers.get("user-agent") || "기기 정보 확인 불가").slice(0, 500),
      });
      if (!loginLogError) await adminClient.from("admin_login_logs").delete().lt("created_at", new Date(Date.now() - 365 * 24 * 60 * 60 * 1000).toISOString());
    } catch {
      // 로그인 이력 저장 장애가 실제 로그인을 막지 않도록 합니다.
    }
  }
  return json({
    ok: true,
    organization,
    session: {
      access_token: authData.session.access_token,
      refresh_token: authData.session.refresh_token,
    },
  });
}
