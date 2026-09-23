import { expect, it } from "vitest";
import { describeR2Health } from "@/lib/r2-health";
import type { OperationalHealth } from "@/lib/operational";

function health(state: OperationalHealth["r2"]["state"], workerState: OperationalHealth["worker"]["state"] = "offline") {
  return {
    worker: { state: workerState },
    r2: { state, last_checked_at: "2026-09-22T22:00:00Z", message: "Bucket acessível pelo Worker" },
  } as OperationalHealth;
}

it("não apresenta sucesso histórico como disponibilidade atual com Worker offline", () => {
  const result = describeR2Health(health("unknown"));
  expect(result.state).toBe("unknown");
  expect(result.label).toBe("Sem verificação");
  expect(result.detail).toMatch(/^Worker offline/);
  expect(result.detail).toContain("Última verificação em");
});

it("aguarda uma medição quando ainda não existe sinal", () => {
  expect(describeR2Health().detail).toBe("Aguardando uma verificação do R2 pelo Worker.");
});

it("preserva resultados atuais de sucesso e falha", () => {
  expect(describeR2Health(health("healthy", "healthy")).label).toBe("Acessível");
  const failed = health("degraded", "healthy");
  failed.r2.message = "Acesso ao bucket negado";
  expect(describeR2Health(failed)).toEqual({ state: "degraded", label: "Atenção", detail: "Acesso ao bucket negado" });
});
