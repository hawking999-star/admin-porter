import { createClient } from "@supabase/supabase-js";

type ProvisionOperatorBody = {
  display_name?: string;
  username?: string;
  email?: string;
  password?: string;
  unit_id?: string;
  role?: string;
  session_policy?: string;
  active?: boolean;
};

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const OPERATOR_ADMIN_ROLES = new Set(["superadmin", "unit_manager", "operations_manager"]);

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

function bearerToken(req: Request) {
  const value = req.headers.get("Authorization") ?? "";
  const match = value.match(/^Bearer\s+(.+)$/i);
  return match?.[1] ?? null;
}

function cleanString(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}

function errorMessage(code: string) {
  const messages: Record<string, string> = {
    acesso_negado: "Acesso negado.",
    permissao_insuficiente: "Seu acesso não permite criar operadores.",
    fora_do_escopo_da_unidade: "Você não pode criar operador neste condomínio.",
    auth_user_required: "Falha ao criar o login do operador.",
    display_name_required: "Informe o nome do operador.",
    username_required: "Informe o usuário do operador.",
    username_invalid: "Usuário inválido. Use letras, números, ponto, hífen ou underline.",
    operator_role_invalid: "Cargo do operador inválido.",
    session_policy_invalid: "Política de sessão inválida.",
    unit_not_found_or_inactive: "Condomínio não encontrado ou inativo.",
  };
  return messages[code] ?? code;
}

function validateBody(body: ProvisionOperatorBody) {
  const displayName = cleanString(body.display_name);
  const username = cleanString(body.username).toLowerCase();
  const email = cleanString(body.email).toLowerCase();
  const password = typeof body.password === "string" ? body.password : "";
  const unitId = cleanString(body.unit_id);
  const role = cleanString(body.role) || "operador";
  const sessionPolicy = cleanString(body.session_policy) || "single";

  if (!displayName) return { error: "Informe o nome do operador." };
  if (!/^[a-z0-9._-]{3,60}$/.test(username)) {
    return { error: "Usuário inválido. Use letras, números, ponto, hífen ou underline." };
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return { error: "Informe um e-mail válido." };
  if (password.length < 6) return { error: "A senha precisa ter pelo menos 6 caracteres." };
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(unitId)) {
    return { error: "Condomínio inválido." };
  }
  if (!["operador", "supervisor"].includes(role)) return { error: "Cargo do operador inválido." };
  if (!["single", "multi"].includes(sessionPolicy)) return { error: "Política de sessão inválida." };

  return {
    value: {
      displayName,
      username,
      email,
      password,
      unitId,
      role,
      sessionPolicy,
      active: body.active ?? true,
    },
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return response({ ok: false, message: "Método não permitido." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = getServiceKey();
  if (!supabaseUrl || !anonKey || !serviceKey) {
    return response({ ok: false, message: "Função não configurada." }, 500);
  }

  const token = bearerToken(req);
  if (!token) return response({ ok: false, message: "Acesso negado." }, 401);

  let body: ProvisionOperatorBody;
  try {
    body = await req.json();
  } catch {
    return response({ ok: false, message: "JSON inválido." }, 400);
  }

  const validation = validateBody(body);
  if ("error" in validation) return response({ ok: false, message: validation.error }, 400);
  const input = validation.value;

  const serviceClient = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userData, error: userError } = await serviceClient.auth.getUser(token);
  if (userError || !userData.user) return response({ ok: false, message: "Acesso negado." }, 401);

  const { data: adminUser, error: adminError } = await serviceClient
    .from("admin_users")
    .select("id, role, active")
    .eq("auth_user_id", userData.user.id)
    .eq("active", true)
    .maybeSingle();

  if (adminError || !adminUser || !OPERATOR_ADMIN_ROLES.has(adminUser.role)) {
    return response({ ok: false, message: "Seu acesso não permite criar operadores." }, 403);
  }

  const { data: created, error: createError } = await serviceClient.auth.admin.createUser({
    email: input.email,
    password: input.password,
    email_confirm: true,
    user_metadata: {
      display_name: input.displayName,
      username: input.username,
      role: "operator",
    },
  });

  if (createError || !created.user) {
    return response({ ok: false, message: createError?.message ?? "Falha ao criar login do operador." }, 400);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });

  const { data: operatorId, error: profileError } = await userClient.rpc("admin_create_operator", {
    p_auth_user_id: created.user.id,
    p_display_name: input.displayName,
    p_username: input.username,
    p_unit_id: input.unitId,
    p_role: input.role,
    p_session_policy: input.sessionPolicy,
    p_active: input.active,
  });

  if (profileError || !operatorId) {
    await serviceClient.auth.admin.deleteUser(created.user.id);
    return response(
      {
        ok: false,
        message: errorMessage(profileError?.message ?? "Falha ao criar perfil do operador."),
      },
      400,
    );
  }

  return response({
    ok: true,
    operator_id: operatorId,
    auth_user_id: created.user.id,
    email: input.email,
  });
});
