import { createClient } from "@supabase/supabase-js";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const attempts = new Map<string, { count: number; resetAt: number }>();

function response(body: unknown, status = 200) {
  return Response.json(body, {
    status,
    headers: {
      ...CORS_HEADERS,
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

function getServiceKey() {
  const direct = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SECRET_KEY");
  if (direct) return direct;

  const secretKeys = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (!secretKeys) return null;

  try {
    const parsed = JSON.parse(secretKeys) as Record<string, string | undefined>;
    return parsed.default ?? Object.values(parsed).find(Boolean) ?? null;
  } catch {
    return null;
  }
}

function clientKey(req: Request) {
  return (req.headers.get("x-forwarded-for") ?? req.headers.get("cf-connecting-ip") ?? "unknown")
    .split(",")[0]
    .trim();
}

function rateLimited(req: Request) {
  const key = clientKey(req);
  const now = Date.now();
  const current = attempts.get(key);
  if (!current || current.resetAt <= now) {
    attempts.set(key, { count: 1, resetAt: now + 60_000 });
    return false;
  }
  current.count += 1;
  return current.count > 20;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return response({ error: "method_not_allowed" }, 405);
  if (rateLimited(req)) return response({ error: "rate_limited" }, 429);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = getServiceKey();
  if (!supabaseUrl || !serviceKey) return response({ error: "server_not_configured" }, 500);

  let identifier = "";
  try {
    const body = (await req.json()) as { identifier?: unknown };
    identifier = typeof body.identifier === "string" ? body.identifier.trim().toLowerCase() : "";
  } catch {
    return response({ error: "invalid_json" }, 400);
  }

  if (!identifier || identifier.length > 120) return response({ error: "invalid_identifier" }, 400);

  if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(identifier)) {
    return response({ email: identifier });
  }

  if (!/^[a-z0-9._-]{3,60}$/.test(identifier)) {
    return response({ error: "not_found" }, 404);
  }

  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: operator, error } = await supabase
    .from("operators")
    .select("auth_user_id")
    .ilike("username", identifier)
    .eq("active", true)
    .maybeSingle();

  if (error || !operator?.auth_user_id) return response({ error: "not_found" }, 404);

  const { data: userData, error: userError } = await supabase.auth.admin.getUserById(operator.auth_user_id);
  const email = userData?.user?.email?.toLowerCase();
  if (userError || !email) return response({ error: "not_found" }, 404);

  return response({ email });
});
