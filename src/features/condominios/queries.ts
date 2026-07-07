import { supabase } from "@/lib/supabase";

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

/** Rótulo curto e amigável do fuso (para listas). */
export function timezoneLabel(tz: string | null | undefined): string {
  switch (tz) {
    case "America/Noronha":
      return "Fernando de Noronha (GMT-2)";
    case "America/Manaus":
    case "America/Campo_Grande":
    case "America/Cuiaba":
    case "America/Porto_Velho":
    case "America/Boa_Vista":
      return "Amazônia (GMT-4)";
    case "America/Rio_Branco":
    case "America/Eirunepe":
      return "Acre (GMT-5)";
    default:
      return "Brasília (GMT-3)";
  }
}

/** Lista de condomínios (units) + contagem de operadores ativos por unidade. */
export async function listUnits(): Promise<Unit[]> {
  const { data: units, error } = await supabase
    .from("units")
    .select("id, code, name, address, city, state, timezone, active, created_at")
    .order("name");
  if (error) throw error;

  const { data: operators, error: opErr } = await supabase
    .from("operators")
    .select("unit_id")
    .eq("active", true)
    .limit(10000);
  if (opErr) throw opErr;

  const counts = new Map<string, number>();
  for (const op of (operators ?? []) as { unit_id: string | null }[]) {
    if (op.unit_id) counts.set(op.unit_id, (counts.get(op.unit_id) ?? 0) + 1);
  }

  return (units ?? []).map((u) => ({
    ...(u as Omit<Unit, "operator_count">),
    operator_count: counts.get(u.id) ?? 0,
  }));
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
