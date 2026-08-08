export const normalizeIpAddress = (value: string) => value.trim().toLowerCase().replace(/^\[|\]$/g, "").replace(/^::ffff:/, "").replace(/%[a-z0-9._-]+$/i, "").replace(/^(\d{1,3}(?:\.\d{1,3}){3}):\d+$/, "$1");

const isLocalAddress = (value: string) => {
  const ip = normalizeIpAddress(value);
  if (!ip || ip === "::1" || ip === "localhost" || ip.startsWith("127.") || ip.startsWith("10.") || ip.startsWith("192.168.")) return true;
  const secondOctet = Number(ip.match(/^172\.(\d+)\./)?.[1]);
  return Number.isFinite(secondOctet) && secondOctet >= 16 && secondOctet <= 31;
};

export async function resolveRequestIp(request: Request) {
  const forwarded = request.headers.get("cf-connecting-ip")
    || request.headers.get("x-real-ip")
    || request.headers.get("x-forwarded-for")?.split(",")[0]
    || "";
  const detected = normalizeIpAddress(forwarded);
  if (process.env.NODE_ENV === "production" || !isLocalAddress(detected)) return detected;

  try {
    const response = await fetch("https://api64.ipify.org?format=json", {
      cache: "no-store",
      signal: AbortSignal.timeout(2_500),
    });
    if (!response.ok) return detected;
    const data = await response.json() as { ip?: string };
    return normalizeIpAddress(data.ip || "") || detected;
  } catch {
    return detected;
  }
}
