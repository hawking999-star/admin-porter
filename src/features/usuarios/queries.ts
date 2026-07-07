import { supabase } from "@/lib/supabase";

/* ------------------------------- Rótulos --------------------------------- */

export const OPERATOR_ROLES = [
  { value: "operador", label: "Operador" },
  { value: "supervisor", label: "Supervisor" },
] as const;

export const ADMIN_ROLES = [
  { value: "superadmin", label: "Super admin" },
  { value: "unit_manager", label: "Gestor de unidade" },
  { value: "operations_manager", label: "Gestor de operação" },
  { value: "content_manager", label: "Gestor de conteúdo" },
  { value: "challenge_manager", label: "Gestor de challenges" },
  { value: "release_manager", label: "Gestor de versões" },
  { value: "auditor", label: "Auditor" },
  { value: "support_readonly", label: "Suporte (só leitura)" },
] as const;

export function operatorRoleLabel(v: string) {
  return OPERATOR_ROLES.find((r) => r.value === v)?.label ?? v;
}
export function adminRoleLabel(v: string) {
  return ADMIN_ROLES.find((r) => r.value === v)?.label ?? v;
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
    .order("name");
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

export async function listOperators(): Promise<Operator[]> {
  const { data, error } = await supabase
    .from("operators")
    .select(
      "id, display_name, username, unit_id, role, session_policy, active, auth_user_id, units(name, city, state), shifts(name, starts_at, ends_at)",
    )
    .order("display_name");
  if (error) throw error;

  return (data ?? []).map((o: any) => ({
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

export async function listAdminUsers(): Promise<AdminUser[]> {
  const { data, error } = await supabase
    .from("admin_users")
    .select("id, display_name, role, active, mfa_required, auth_user_id")
    .order("display_name");
  if (error) throw error;

  return (data ?? []).map((a: any) => ({
    id: a.id,
    display_name: a.display_name,
    role: a.role,
    active: a.active,
    mfa_required: a.mfa_required,
    has_login: Boolean(a.auth_user_id),
  }));
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
