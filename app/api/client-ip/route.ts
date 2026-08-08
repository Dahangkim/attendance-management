import { resolveRequestIp } from "../_lib/client-ip";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const ip = await resolveRequestIp(request);
  return Response.json({ ip }, { headers: { "Cache-Control": "no-store" } });
}
