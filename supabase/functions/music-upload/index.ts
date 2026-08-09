import { HeadObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { createClient } from "@supabase/supabase-js";

type PrepareBody = {
  action: "prepare";
  item_id?: string;
  playlist_id?: string;
  filename?: string;
  mime?: string;
  size_bytes?: number;
  rights_statement?: string;
};

type CompleteBody = {
  action: "complete";
  session_id?: string;
};

type UploadSession = {
  session_id: string;
  staging_object_key: string;
  declared_mime: string;
  declared_size_bytes: number;
  expires_at: string;
};

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_UPLOAD_BYTES = 50 * 1024 * 1024;

function requiredEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`MISSING_ENV_${name}`);
  return value;
}

function serviceKey() {
  const direct = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SECRET_KEY");
  if (direct) return direct;
  const encoded = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (!encoded) throw new Error("MISSING_ENV_SUPABASE_SERVICE_ROLE_KEY");
  const parsed = JSON.parse(encoded) as Record<string, string | undefined>;
  const key = parsed.default ?? Object.values(parsed).find(Boolean);
  if (!key) throw new Error("MISSING_ENV_SUPABASE_SERVICE_ROLE_KEY");
  return key;
}

function allowedOrigins() {
  const defaults = [
    "http://localhost:5173",
    "https://admin-porter-music.vercel.app",
    "https://admin-porter-music-kaua-s-projects13.vercel.app",
    "https://admin-porter-music-git-main-kaua-s-projects13.vercel.app",
  ].join(",");
  return new Set(
    (Deno.env.get("ADMIN_ALLOWED_ORIGINS") ?? defaults)
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
  );
}

function corsHeaders(origin: string | null) {
  const allowed = origin && allowedOrigins().has(origin) ? origin : "";
  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "600",
    "Vary": "Origin",
  };
}

function response(origin: string | null, body: unknown, status = 200) {
  return Response.json(body, {
    status,
    headers: {
      ...corsHeaders(origin),
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

function publicError(error: unknown) {
  const raw = error instanceof Error ? error.message : String(error ?? "");
  const known = [
    "music_upload_item_not_found",
    "music_upload_playlist_not_found",
    "music_upload_request_not_approved",
    "music_upload_size_invalid",
    "music_upload_mime_invalid",
    "music_upload_extension_invalid",
    "music_upload_rights_required",
    "music_upload_session_not_found",
    "music_upload_session_already_used",
    "music_upload_session_expired",
    "music_upload_size_mismatch",
    "fora_do_escopo_da_unidade",
    "permissao_insuficiente",
    "acesso_negado",
  ].find((code) => raw.includes(code));
  return known ?? "music_upload_unavailable";
}

function statusForCode(code: string) {
  if (code === "acesso_negado") return 401;
  if (code === "fora_do_escopo_da_unidade" || code === "permissao_insuficiente") return 403;
  if (code.includes("not_found")) return 404;
  if (code.includes("already_used")) return 409;
  if (code.includes("expired")) return 410;
  if (code === "music_upload_unavailable") return 503;
  return 400;
}

function authHeader(req: Request) {
  const value = req.headers.get("Authorization")?.trim() ?? "";
  if (!/^Bearer\s+\S+$/i.test(value)) throw new Error("acesso_negado");
  return value;
}

function r2Client() {
  return new S3Client({
    region: "auto",
    endpoint: `https://${requiredEnv("R2_ACCOUNT_ID")}.r2.cloudflarestorage.com`,
    credentials: {
      accessKeyId: requiredEnv("R2_ACCESS_KEY_ID"),
      secretAccessKey: requiredEnv("R2_SECRET_ACCESS_KEY"),
    },
  });
}

async function authenticatedClient(req: Request) {
  const authorization = authHeader(req);
  const url = requiredEnv("SUPABASE_URL");
  const publishableKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (!publishableKey) throw new Error("MISSING_ENV_SUPABASE_ANON_KEY");
  const client = createClient(url, publishableKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.auth.getUser(authorization.replace(/^Bearer\s+/i, ""));
  if (error || !data.user) throw new Error("acesso_negado");
  return client;
}

async function prepare(req: Request, body: PrepareBody, origin: string | null) {
  const itemId = body.item_id && UUID_PATTERN.test(body.item_id) ? body.item_id : null;
  const playlistId = body.playlist_id && UUID_PATTERN.test(body.playlist_id) ? body.playlist_id : null;
  if ((itemId ? 1 : 0) + (playlistId ? 1 : 0) !== 1) {
    throw new Error(itemId ? "music_upload_playlist_not_found" : "music_upload_item_not_found");
  }
  const filename = body.filename?.trim() ?? "";
  const mime = body.mime?.trim().toLowerCase() ?? "";
  const sizeBytes = Number(body.size_bytes);
  const rightsStatement = body.rights_statement?.trim() ?? "";
  if (!filename || !Number.isSafeInteger(sizeBytes) || sizeBytes < 1 || sizeBytes > MAX_UPLOAD_BYTES) {
    throw new Error("music_upload_size_invalid");
  }
  const client = await authenticatedClient(req);
  const rpcName = itemId ? "admin_prepare_music_upload" : "admin_prepare_library_music_upload";
  const target = itemId ? { p_item_id: itemId } : { p_playlist_id: playlistId };
  const { data, error } = await client.rpc(rpcName, {
    ...target,
    p_filename: filename,
    p_mime: mime,
    p_size_bytes: sizeBytes,
    p_rights_statement: rightsStatement,
  });
  if (error) throw error;
  const session = data as UploadSession;
  const uploadUrl = await getSignedUrl(
    r2Client(),
    new PutObjectCommand({
      Bucket: requiredEnv("R2_BUCKET"),
      Key: session.staging_object_key,
      ContentType: session.declared_mime,
    }),
    { expiresIn: 600 },
  );
  return response(origin, {
    session_id: session.session_id,
    upload_url: uploadUrl,
    expires_at: session.expires_at,
    required_headers: { "Content-Type": session.declared_mime },
  });
}

async function complete(req: Request, body: CompleteBody, origin: string | null) {
  if (!body.session_id || !UUID_PATTERN.test(body.session_id)) throw new Error("music_upload_session_not_found");
  const client = await authenticatedClient(req);
  const { data, error } = await client.rpc("admin_confirm_music_upload_session", {
    p_session_id: body.session_id,
  });
  if (error) throw error;
  const session = data as UploadSession;
  const head = await r2Client().send(new HeadObjectCommand({
    Bucket: requiredEnv("R2_BUCKET"),
    Key: session.staging_object_key,
  }));
  const actualSize = Number(head.ContentLength ?? -1);
  if (actualSize !== Number(session.declared_size_bytes)) throw new Error("music_upload_size_mismatch");
  if ((head.ContentType ?? "").toLowerCase() !== session.declared_mime.toLowerCase()) {
    throw new Error("music_upload_mime_invalid");
  }
  const service = createClient(requiredEnv("SUPABASE_URL"), serviceKey(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: queued, error: queueError } = await service.rpc("worker_complete_music_upload_session", {
    p_session_id: body.session_id,
    p_verified_size_bytes: actualSize,
    p_etag: head.ETag ?? null,
  });
  if (queueError) throw queueError;
  return response(origin, queued, 202);
}

Deno.serve(async (req) => {
  const origin = req.headers.get("Origin");
  if (origin && !allowedOrigins().has(origin)) return response(origin, { error: "origin_not_allowed" }, 403);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(origin) });
  if (req.method !== "POST") return response(origin, { error: "method_not_allowed" }, 405);

  try {
    const body = await req.json() as PrepareBody | CompleteBody;
    if (body.action === "prepare") return await prepare(req, body, origin);
    if (body.action === "complete") return await complete(req, body, origin);
    return response(origin, { error: "invalid_action" }, 400);
  } catch (error) {
    const code = publicError(error);
    console.error("music-upload", code);
    return response(origin, { error: code }, statusForCode(code));
  }
});
