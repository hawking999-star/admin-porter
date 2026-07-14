export type UnitLabelInput = {
  name: string | null | undefined;
  city?: string | null;
  state?: string | null;
  code?: string | null;
};

/**
 * Rótulo compacto para diferenciar condomínios homônimos sem poluir a tela.
 * A localidade tem prioridade; o código é usado somente como fallback.
 */
export function unitLabel(unit: UnitLabelInput): string {
  const name = unit.name?.trim() || "—";
  const location = [unit.city, unit.state].filter(Boolean).join("/");
  const suffix = location || unit.code || "";
  return suffix ? `${name} — ${suffix}` : name;
}
