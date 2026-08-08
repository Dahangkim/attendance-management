export const dynamic = "force-dynamic";

export async function GET() {
  return Response.json({ staff: [], code: "STAFF_LOGIN_LIST_DISABLED" }, { status: 410, headers: { "Cache-Control": "no-store" } });
}
