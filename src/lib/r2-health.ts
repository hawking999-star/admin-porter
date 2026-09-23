import type { HealthState, OperationalHealth } from "./operational";

export function describeR2Health(health?: OperationalHealth) {
  const state: HealthState = health?.r2?.state ?? "unknown";
  if (state !== "unknown") {
    return {
      state,
      label: state === "healthy" ? "Acessível" : "Atenção",
      detail: health?.r2?.message || "Verificação realizada pelo Worker.",
    };
  }

  const detail = health?.worker?.state === "offline"
    ? "Worker offline. O R2 está sem verificação atual."
    : "Aguardando uma verificação do R2 pelo Worker.";
  const checkedAt = health?.r2?.last_checked_at;
  const date = checkedAt ? new Date(checkedAt) : null;
  const previous = date && !Number.isNaN(date.getTime()) && health?.r2?.message
    ? ` Última verificação em ${date.toLocaleString("pt-BR")}: ${health.r2.message}.`
    : "";
  return { state, label: "Sem verificação", detail: detail + previous };
}
