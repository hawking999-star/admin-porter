import { supabase } from "@/lib/supabase";

export type PaginatedResult<T> = {
  rows: T[];
  total: number;
};

export type PageParams = {
  page: number;
  pageSize: number;
};

/* ------------------------------- Rótulos --------------------------------- */

export const OPERATOR_ROLES = [
  { value: "operador", label: "Operador" },
  { value: "supervisor", label: "Supervisor" },
] as const;

// Papéis selecionáveis no painel: por ora só Super admin (acesso total).
// Novos acessos nascem como superadmin. Dá para reintroduzir papéis depois.
export const ADMIN_ROLES = [
  { value: "superadmin", label: "Super admin" },
] as const;

// Rótulos completos para EXIBIR papéis antigos que ainda existam no banco.
const ADMIN_ROLE_LABELS: Record<string, string> = {
  superadmin: "Super admin",
  unit_manager: "Gestor de unidade",
  operations_manager: "Gestor de operação",
  content_manager: "Gestor de conteúdo",
  challenge_manager: "Gestor de challenges",
  release_manager: "Gestor de versões",
  auditor: "Auditor",
  support_readonly: "Suporte (só leitura)",
};

export function operatorRoleLabel(v: string) {
  return OPERATOR_ROLES.find((r) => r.value === v)?.label ?? v;
}
export function adminRoleLabel(v: string) {
  return ADMIN_ROLE_LABELS[v] ?? v;
}

/* --------------------------- Opções de unidade --------------------------- */

export type UnitOption = {
  id: string;
  name: string;
  city: string | null;
  state: string | null;
  code: string | null;
};

export async function listUnitOptions(): Promise<UnitOption[]> {
  const { data, error } = await supabase
    .from("units")
    .select("id, name, city, state, code")
    .eq("active", true)
    .order("name")
    .limit(500);
  if (error) throw error;
  return (data ?? []) as UnitOption[];
}

/**
 * Rótulo de um condomínio para telas e listas.
 * Sempre acrescenta a localidade (Cidade/UF) para diferenciar condomínios
 * com o mesmo nome. Se não houver cidade, usa o código como desempate.
 */
export function unitLabel(u: {
  name: string | null;
  city?: string | null;
  state?: string | null;
  code?: string | null;
}): string {
  const name = u.name ?? "—";
  const loc = [u.city, u.state].filter(Boolean).join("/");
  const suffix = loc || u.code || "";
  return suffix ? `${name} — ${suffix}` : name;
}

/* --------------------------------- Turno --------------------------------- */

export type ShiftKind = "12x36_dia" | "12x36_noite" | "6x1";

export const SHIFT_TYPES = [
  { value: "none", label: "Sem turno" },
  { value: "12x36_dia", label: "12x36 Diurno (06h–18h)" },
  { value: "12x36_noite", label: "12x36 Noturno (18h–06h)" },
  { value: "6x1", label: "6x1 (horário personalizado)" },
] as const;

/** Deriva o tipo de turno a partir do nome salvo no shift. */
export function shiftKindFromName(name: string | null): ShiftKind | null {
  if (!name) return null;
  const n = name.trim().toLowerCase();
  if (n.includes("diurno")) return "12x36_dia";
  if (n.includes("noturno")) return "12x36_noite";
  if (n.includes("6x1")) return "6x1";
  return null;
}

/** Rótulo curto do turno para listas (ex.: "12x36 Diurno · 06:00–18:00"). */
export function shiftLabel(kind: ShiftKind | null, start: string | null, end: string | null): string {
  if (!kind) return "—";
  const hhmm = (t: string | null) => (t ? t.slice(0, 5) : "");
  const hours = start && end ? ` · ${hhmm(start)}–${hhmm(end)}` : "";
  const name =
    kind === "12x36_dia" ? "12x36 Diurno" : kind === "12x36_noite" ? "12x36 Noturno" : "6x1";
  return `${name}${hours}`;
}

/* ------------------------ Operadores (operators) ------------------------- */

export type Operator = {
  id: string;
  display_name: string;
  username: string | null;
  unit_id: string;
  unit_name: string | null;
  unit_city: string | null;
  unit_state: string | null;
  role: string;
  session_policy: string;
  active: boolean;
  has_login: boolean;
  shift_kind: ShiftKind | null;
  shift_start: string | null;
  shift_end: string | null;
};

/** Criar operador COM login (vai pela Edge Function provision-operator). */
export type OperatorProvisionInput = {
  display_name: string;
  username: string;
  email: string;
  password: string;
  unit_id: string;
  role: string;
  session_policy: string;
  active: boolean;
};

/** Editar o perfil do operador (não mexe no login). */
export type OperatorUpdateInput = {
  display_name: string;
  username: string | null;
  unit_id: string;
  role: string;
  session_policy: string;
  active: boolean;
};

export type OperatorFilters = PageParams & {
  search?: string;
  unitId?: string;
  active?: "all" | "active" | "inactive";
  role?: "all" | string;
};

export type OperatorStats = {
  active: number;
  inactive: number;
  supervisors: number;
  noLogin: number;
};

function pageRange(page: number, pageSize: number) {
  const from = Math.max(0, page - 1) * pageSize;
  return { from, to: from + pageSize - 1 };
}

export async function listOperators(filters: OperatorFilters): Promise<PaginatedResult<Operator>> {
  const { from, to } = pageRange(filters.page, filters.pageSize);
  const term = filters.search?.trim();

  let query = supabase
    .from("operators")
    .select(
      "id, display_name, username, unit_id, role, session_policy, active, auth_user_id, units(name, city, state), shifts(name, starts_at, ends_at)",
      { count: "exact" },
    )
    .order("display_name");

  if (term) {
    const clean = term.replace(/[%,()]/g, "");
    if (clean) {
      const pattern = `%${clean}%`;
      query = query.or(`display_name.ilike.${pattern},username.ilike.${pattern}`);
    }
  }
  if (filters.unitId && filters.unitId !== "all") query = query.eq("unit_id", filters.unitId);
  if (filters.active === "active") query = query.eq("active", true);
  if (filters.active === "inactive") query = query.eq("active", false);
  if (filters.role && filters.role !== "all") query = query.eq("role", filters.role);

  const { data, error, count } = await query.range(from, to);
  if (error) throw error;

  const rows = (data ?? []).map((o: any) => ({
    id: o.id,
    display_name: o.display_name,
    username: o.username ?? null,
    unit_id: o.unit_id,
    unit_name: o.units?.name ?? null,
    unit_city: o.units?.city ?? null,
    unit_state: o.units?.state ?? null,
    role: o.role,
    session_policy: o.session_policy,
    active: o.active,
    has_login: Boolean(o.auth_user_id),
    shift_kind: shiftKindFromName(o.shifts?.name ?? null),
    shift_start: o.shifts?.starts_at ?? null,
    shift_end: o.shifts?.ends_at ?? null,
  }));

  return { rows, total: count ?? 0 };
}

export async function countOperatorStats(): Promise<OperatorStats> {
  const [active, inactive, supervisors, noLogin] = await Promise.all([
    supabase.from("operators").select("id", { count: "exact", head: true }).eq("active", true),
    supabase.from("operators").select("id", { count: "exact", head: true }).eq("active", false),
    supabase.from("operators").select("id", { count: "exact", head: true }).eq("role", "supervisor"),
    supabase.from("operators").select("id", { count: "exact", head: true }).is("auth_user_id", null),
  ]);

  const error = active.error ?? inactive.error ?? supervisors.error ?? noLogin.error;
  if (error) throw error;

  return {
    active: active.count ?? 0,
    inactive: inactive.count ?? 0,
    supervisors: supervisors.count ?? 0,
    noLogin: noLogin.count ?? 0,
  };
}

/** Define/atualiza o turno do operador (12x36 fixo; 6x1 com horário). */
export async function setOperatorShift(
  operatorId: string,
  kind: string,
  start?: string | null,
  end?: string | null,
): Promise<void> {
  const { error } = await supabase.rpc("admin_set_operator_shift", {
    p_operator: operatorId,
    p_kind: kind,
    p_start: kind === "6x1" ? start ?? null : null,
    p_end: kind === "6x1" ? end ?? null : null,
  });
  if (error) throw error;
}

/** E-mail de login do operador (para exibir no admin ao editar). */
export async function getOperatorEmail(operatorId: string): Promise<string | null> {
  const { data, error } = await supabase.rpc("admin_operator_email", { p_operator: operatorId });
  if (error) throw error;
  return (data as string | null) ?? null;
}

/** Cria o operador e o login (auth) de uma vez, via servidor. Retorna o id do operador. */
export async function provisionOperator(input: OperatorProvisionInput): Promise<string | null> {
  const { data, error } = await supabase.functions.invoke("provision-operator", { body: input });
  if (error) {
    let msg = error.message;
    try {
      const ctx: any = (error as any).context;
      if (ctx && typeof ctx.json === "function") {
        const j = await ctx.json();
        if (j?.message) msg = j.message;
      }
    } catch {
      /* ignora */
    }
    throw new Error(msg);
  }
  if (data && (data as any).ok === false) {
    throw new Error((data as any).message ?? "Erro ao criar operador.");
  }
  return (data as any)?.operator_id ?? null;
}

export async function updateOperator(id: string, input: OperatorUpdateInput): Promise<void> {
  const { error } = await supabase.rpc("admin_update_operator", {
    p_operator: id,
    p_display_name: input.display_name,
    p_username: input.username,
    p_unit_id: input.unit_id,
    p_role: input.role,
    p_session_policy: input.session_policy,
    p_active: input.active,
  });
  if (error) throw error;
}

/**
 * Ativa/desativa um operador reaproveitando o RPC de edição.
 * Mantém todos os demais campos e apenas troca o `active`.
 */
export async function setOperatorActive(op: Operator, active: boolean): Promise<void> {
  await updateOperator(op.id, {
    display_name: op.display_name,
    username: op.username,
    unit_id: op.unit_id,
    role: op.role,
    session_policy: op.session_policy,
    active,
  });
}

/* --------------------------- Acessos (admin_users) ----------------------- */

export type AdminUser = {
  id: string;
  display_name: string;
  role: string;
  active: boolean;
  mfa_required: boolean;
  has_login: boolean;
};

export type AdminUserInput = {
  display_name: string;
  role: string;
  active: boolean;
  mfa_required: boolean;
};

export async function listAdminUsers(filters: PageParams): Promise<PaginatedResult<AdminUser>> {
  const { from, to } = pageRange(filters.page, filters.pageSize);
  const { data, error, count } = await supabase
    .from("admin_users")
    .select("id, display_name, role, active, mfa_required, auth_user_id", { count: "exact" })
    .order("display_name")
    .range(from, to);
  if (error) throw error;

  const rows = (data ?? []).map((a: any) => ({
    id: a.id,
    display_name: a.display_name,
    role: a.role,
    active: a.active,
    mfa_required: a.mfa_required,
    has_login: Boolean(a.auth_user_id),
  }));

  return { rows, total: count ?? 0 };
}

export async function updateAdminUser(id: string, input: AdminUserInput): Promise<void> {
  const { error } = await supabase.rpc("admin_update_admin_user", {
    p_admin_user: id,
    p_display_name: input.display_name,
    p_role: input.role,
    p_active: input.active,
    p_mfa_required: input.mfa_required,
  });
  if (error) throw error;
}

/* ------------------------- Promoção (app <-> painel) --------------------- */

/** Dá acesso ao painel a um operador do app já existente (vira superadmin). */
export async function grantPanelAccess(operatorId: string, mfaRequired = false): Promise<void> {
  const { error } = await supabase.rpc("admin_grant_panel_access", {
    p_operator: operatorId,
    p_mfa_required: mfaRequired,
  });
  if (error) throw error;
}

export type GrantAppAccessInput = {
  username: string;
  unit_id: string;
  role: string;
  session_policy: string;
};

/** Dá acesso ao app a quem só tem acesso ao painel (cria perfil de operador). */
export async function grantAppAccess(adminUserId: string, input: GrantAppAccessInput): Promise<void> {
  const { error } = await supabase.rpc("admin_grant_app_access", {
    p_admin_user: adminUserId,
    p_username: input.username,
    p_unit_id: input.unit_id,
    p_role: input.role,
    p_session_policy: input.session_policy,
  });
  if (error) throw error;
}
