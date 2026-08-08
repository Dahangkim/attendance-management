import { runtimeEnv } from "../_lib/runtime-env";
import { authenticatedAdmin } from "../_lib/admin-auth";
import { createServerSupabaseClient } from "../_lib/server-supabase";

export const dynamic = "force-dynamic";
const json = (body: Record<string, unknown>, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });

export async function PATCH(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);
  if (actor.role !== "super_admin") return json({ ok: false, code: "SUPER_ADMIN_REQUIRED" }, 403);

  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const text = (keyName: string, max: number) => typeof body?.[keyName] === "string" ? String(body[keyName]).trim().slice(0, max) : "";
  const primary = text("brandPrimaryColor", 7);
  const accent = text("brandAccentColor", 7);
  const logoUrl = text("brandLogoUrl", 2000);
  if ((primary && !/^#[0-9a-f]{6}$/i.test(primary)) || (accent && !/^#[0-9a-f]{6}$/i.test(accent)) || (logoUrl && !logoUrl.startsWith("/") && !/^https:\/\//i.test(logoUrl))) {
    return json({ ok: false, code: "INVALID_INPUT" }, 400);
  }
  const updates = {
    brand_title: text("brandTitle", 100) || null,
    brand_description: text("brandDescription", 300) || null,
    brand_subtitle: text("brandSubtitle", 100) || null,
    brand_mark: text("brandMark", 2) || null,
    brand_logo_url: logoUrl || null,
    brand_primary_color: primary || null,
    brand_accent_color: accent || null,
  };
  const { data: beforeProfile } = await client.from("profiles").select("brand_title,brand_description,brand_subtitle,brand_mark,brand_logo_url,brand_primary_color,brand_accent_color").eq("id", actor.id).maybeSingle();
  const { data: profile, error } = await client.from("profiles").update(updates).eq("id", actor.id).eq("role", "super_admin").select("*").maybeSingle();
  if (error || !profile) return json({ ok: false, code: error?.code === "42703" ? "BRANDING_SCHEMA_REQUIRED" : "SUPER_ADMIN_BRANDING_UPDATE_FAILED" }, 500);
  await client.from("attendance_audit_logs").insert({
    employee_id: actor.id,
    action_type: "super_admin_branding_updated",
    changed_field: "super_admin_branding",
    before_value: JSON.stringify(beforeProfile || {}),
    after_value: JSON.stringify(updates),
    reason: "최고관리자 본인의 통합관리 화면 설정 변경",
    changed_by: actor.id,
    changed_by_role: actor.role,
    org_id: null,
  });
  return json({ ok: true, profile });
}
