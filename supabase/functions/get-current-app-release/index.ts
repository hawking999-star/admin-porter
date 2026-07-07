import { createClient } from "@supabase/supabase-js";

type AppReleaseRow = {
  id: string;
  version: string;
  channel: string;
  status: "released";
  is_current: boolean;
  mandatory: boolean;
  minimum_version: string | null;
  title: string;
  release_notes: string | null;
  manifest_key: string;
  installer_key: string;
  blockmap_key: string;
  sha512: string;
  size_bytes: number;
  released_at: string;
};

function response(body: unknown, status = 200) {
  return Response.json(body, {
    status,
    headers: {
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

async function digest(value: string) {
  const bytes = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return new Uint8Array(hash);
}

async function secretsMatch(received: string | null, expected: string | undefined) {
  if (!received || !expected) return false;
  const [a, b] = await Promise.all([digest(received), digest(expected)]);
  if (a.length !== b.length) return false;

  let diff = 0;
  for (let i = 0; i < a.length; i += 1) {
    diff |= a[i] ^ b[i];
  }
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "GET") {
    return response({ error: "method_not_allowed" }, 405);
  }

  const internalSecret = Deno.env.get("PORTER_UPDATE_INTERNAL_SECRET");
  const receivedSecret = req.headers.get("X-Porter-Update-Secret");
  if (!(await secretsMatch(receivedSecret, internalSecret))) {
    return response({ error: "unauthorized" }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = getServiceKey();
  if (!supabaseUrl || !serviceKey) {
    return response({ error: "server_not_configured" }, 500);
  }

  const url = new URL(req.url);
  const channel = url.searchParams.get("channel")?.trim() || "stable";
  if (!/^[a-z0-9_-]{1,40}$/.test(channel)) {
    return response({ error: "invalid_channel" }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await supabase
    .from("app_releases")
    .select(
      "id, version, channel, status, is_current, mandatory, minimum_version, title, release_notes, manifest_key, installer_key, blockmap_key, sha512, size_bytes, released_at",
    )
    .eq("channel", channel)
    .eq("status", "released")
    .eq("is_current", true)
    .maybeSingle<AppReleaseRow>();

  if (error) {
    console.error("get-current-app-release query failed", error.message);
    return response({ error: "internal_error" }, 500);
  }

  if (!data) {
    return response({ error: "release_not_found" }, 404);
  }

  if (
    !data.manifest_key?.trim() ||
    !data.installer_key?.trim() ||
    !data.blockmap_key?.trim() ||
    !data.sha512?.trim() ||
    !data.size_bytes ||
    data.size_bytes <= 0
  ) {
    return response({ error: "release_not_found" }, 404);
  }

  return response({
    id: data.id,
    version: data.version,
    channel: data.channel,
    status: data.status,
    is_current: data.is_current,
    mandatory: data.mandatory,
    minimum_version: data.minimum_version,
    title: data.title,
    release_notes: data.release_notes,
    manifest_key: data.manifest_key,
    installer_key: data.installer_key,
    blockmap_key: data.blockmap_key,
    sha512: data.sha512,
    size_bytes: data.size_bytes,
    released_at: data.released_at,
  });
});
