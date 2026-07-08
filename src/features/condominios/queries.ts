import { supabase } from "@/lib/supabase";

export type PaginatedResult<T> = {
  rows: T[];
  total: number;
};

export type PageParams = {
  page: number;
  pageSize: number;
};

export type Unit = {
  id: string;
  code: string;
  name: string;
  address: string | null;
  city: string | null;
  state: string | null;
  timezone: string;
  active: boolean;
  created_at: string;
  operator_count: number;
};

export type UnitInput = {
  code: string;
  name: string;
  address: string | null;
  city: string | null;
  state: string | null;
  timezone: string;
  active: boolean;
};

export type UnitFilters = PageParams & {
  search?: string;
  active?: "all" | "active" | "inactive";
};

export type UnitStats = {
  active: number;
  inactive: number;
  operators: number;
  cities: number | null;
};

export function timezoneLabel(tz: string | null | undefined): string {
  switch (tz) {
    case "America/Noronha":
      return "Fernando de Noronha (GMT-2)";
    case "America/Manaus":
    case "America/Campo_Grande":
    case "America/Cuiaba":
    case "America/Porto_Velho":
    case "America/Boa_Vista":
      return "Amazonia (GMT-4)";
    case "America/Rio_Branco":
    case "America/Eirunepe":
      return "Acre (GMT-5)";
    default:
      return "Brasilia (GMT-3)";
  }
}

function pageRange(page: number, pageSize: number) {
  const from = Math.max(0, page - 1) * pageSize;
  return { from, to: from + pageSize - 1 };
}

export async function listUnits(filters: UnitFilters): Promise<PaginatedResult<Unit>> {
  const { from, to } = pageRange(filters.page, filters.pageSize);
  const term = filters.search?.trim();

  let query = supabase
    .from("units")
    .select("id, code, name, address, city, state, timezone, active, created_at", { count: "exact" })
    .order("name");

  if (term) {
    const clean = term.replace(/[%,()]/g, "");
    if (clean) {
      const pattern = `%${clean}%`;
      query = query.or(`name.ilike.${pattern},code.ilike.${pattern},city.ilike.${pattern}`);
    }
  }
  if (filters.active === "active") query = query.eq("active", true);
  if (filters.active === "inactive") query = query.eq("active", false);

  const { data: units, error, count } = await query.range(from, to);
  if (error) throw error;

  const unitIds = (units ?? []).map((u) => u.id);
  const counts = new Map<string, number>();

  if (unitIds.length > 0) {
    const { data: operators, error: opErr } = await supabase
      .from("operators")
      .select("unit_id")
      .eq("active", true)
      .in("unit_id", unitIds);
    if (opErr) throw opErr;

    for (const op of (operators ?? []) as { unit_id: string | null }[]) {
      if (op.unit_id) counts.set(op.unit_id, (counts.get(op.unit_id) ?? 0) + 1);
    }
  }

  const rows = (units ?? []).map((u) => ({
    ...(u as Omit<Unit, "operator_count">),
    operator_count: counts.get(u.id) ?? 0,
  }));

  return { rows, total: count ?? 0 };
}

export async function countUnitStats(): Promise<UnitStats> {
  const [active, inactive, operators] = await Promise.all([
    supabase.from("units").select("id", { count: "exact", head: true }).eq("active", true),
    supabase.from("units").select("id", { count: "exact", head: true }).eq("active", false),
    supabase.from("operators").select("id", { count: "exact", head: true }).eq("active", true),
  ]);

  const error = active.error ?? inactive.error ?? operators.error;
  if (error) throw error;

  return {
    active: active.count ?? 0,
    inactive: inactive.count ?? 0,
    operators: operators.count ?? 0,
    cities: null,
  };
}

export async function createUnit(input: UnitInput): Promise<void> {
  const { error } = await supabase.rpc("admin_create_unit", {
    p_code: input.code,
    p_name: input.name,
    p_address: input.address,
    p_city: input.city,
    p_state: input.state,
    p_timezone: input.timezone,
    p_active: input.active,
  });
  if (error) throw error;
}

export async function updateUnit(id: string, input: UnitInput): Promise<void> {
  const { error } = await supabase.rpc("admin_update_unit", {
    p_unit: id,
    p_code: input.code,
    p_name: input.name,
    p_address: input.address,
    p_city: input.city,
    p_state: input.state,
    p_timezone: input.timezone,
    p_active: input.active,
  });
  if (error) throw error;
}

/**
 * Ativa/desativa um condomínio reaproveitando o RPC de edição.
 * Mantém todos os demais campos e apenas troca o `active`.
 */
export async function setUnitActive(unit: Unit, active: boolean): Promise<void> {
  await updateUnit(unit.id, {
    code: unit.code,
    name: unit.name,
    address: unit.address,
    city: unit.city,
    state: unit.state,
    timezone: unit.timezone,
    active,
  });
}
