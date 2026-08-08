import { runtimeEnv } from "../_lib/runtime-env";
import { authenticatedAdmin } from "../_lib/admin-auth";
import { createServerSupabaseClient } from "../_lib/server-supabase";

export const dynamic = "force-dynamic";

const BUCKET = "organization-branding";
const MAX_FILE_SIZE = 2 * 1024 * 1024;
const EXTENSION_BY_TYPE: Record<string, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/webp": "webp",
};

const json = (body: Record<string, unknown>, status = 200) => Response.json(body, status === 200 ? undefined : { status });

export async function POST(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);

  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);

  const form = await request.formData().catch(() => null);
  const file = form?.get("logo");
  const scope = String(form?.get("scope") || "organization").trim();
  const requestedOrgId = String(form?.get("org_id") || "").trim();
  const superAdminBranding = scope === "super_admin";
  if (superAdminBranding && actor.role !== "super_admin") return json({ ok: false, code: "SUPER_ADMIN_REQUIRED" }, 403);
  const orgId = actor.role === "super_admin" ? requestedOrgId : actor.org_id;
  if ((!superAdminBranding && !orgId) || !(file instanceof File)) return json({ ok: false, code: "INVALID_INPUT" }, 400);
  if (actor.role !== "super_admin" && requestedOrgId && requestedOrgId !== actor.org_id) return json({ ok: false, code: "ORGANIZATION_FORBIDDEN" }, 403);

  const extension = EXTENSION_BY_TYPE[file.type];
  if (!extension || file.size <= 0 || file.size > MAX_FILE_SIZE) return json({ ok: false, code: "INVALID_LOGO_FILE" }, 400);

  if (!superAdminBranding) {
    const { data: organization } = await client.from("organizations").select("id").eq("id", orgId).maybeSingle();
    if (!organization) return json({ ok: false, code: "ORGANIZATION_NOT_FOUND" }, 404);
  }

  const { data: bucket } = await client.storage.getBucket(BUCKET);
  if (!bucket) {
    const { error: bucketError } = await client.storage.createBucket(BUCKET, {
      public: true,
      fileSizeLimit: MAX_FILE_SIZE,
      allowedMimeTypes: Object.keys(EXTENSION_BY_TYPE),
    });
    if (bucketError && !/already exists/i.test(bucketError.message)) return json({ ok: false, code: "LOGO_BUCKET_CREATE_FAILED" }, 500);
  }

  const path = superAdminBranding ? `super-admin/${actor.id}/logo-${Date.now()}.${extension}` : `${orgId}/logo-${Date.now()}.${extension}`;
  const bytes = await file.arrayBuffer();
  const { error: uploadError } = await client.storage.from(BUCKET).upload(path, bytes, {
    contentType: file.type,
    cacheControl: "3600",
    upsert: false,
  });
  if (uploadError) return json({ ok: false, code: "LOGO_UPLOAD_FAILED" }, 500);

  const { data: publicUrlData } = client.storage.from(BUCKET).getPublicUrl(path);
  const logoUrl = publicUrlData.publicUrl;
  const updateQuery = superAdminBranding
    ? client.from("profiles").update({ brand_logo_url: logoUrl }).eq("id", actor.id).eq("role", "super_admin")
    : client.from("organizations").update({ brand_logo_url: logoUrl }).eq("id", orgId);
  const { data: updated, error: updateError } = await updateQuery.select("*").maybeSingle();
  if (updateError || !updated) return json({ ok: false, code: "LOGO_URL_SAVE_FAILED" }, 500);

  return json({ ok: true, logoUrl, organization: updated });
}
