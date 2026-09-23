import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { MemoryRouter, useLocation } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { AuditoriaPage } from "@/features/auditoria/AuditoriaPage";
import { CondominiosPage } from "@/features/condominios/CondominiosPage";
import { LogsPage } from "@/features/logs/LogsPage";
import { useUrlFilterPatch, useUrlFilterState } from "@/hooks/useUrlFilterState";

const mock = vi.hoisted(() => ({ audit: vi.fn(), units: vi.fn(), logs: vi.fn(), export: vi.fn(), success: vi.fn(), warning: vi.fn(), error: vi.fn() }));
vi.mock("sonner", () => ({ toast: { success: mock.success, warning: mock.warning, error: mock.error } }));
vi.mock("@/lib/supabase", () => ({ supabase: {} }));
vi.mock("@/features/auditoria/queries", async (original) => ({
  ...await original<object>(),
  listAuditLogs: mock.audit,
  exportAuditLogs: mock.export,
  listAuditFilterOptions: async () => ({ actions: [], entityTypes: [], admins: [] }),
}));
vi.mock("@/features/condominios/queries", async (original) => ({
  ...await original<object>(),
  listUnits: mock.units,
  countUnitStats: async () => ({ active: 0, inactive: 0, operators: 0, cities: 0 }),
}));
vi.mock("@/features/logs/queries", async (original) => ({
  ...await original<object>(), fetchLogs: mock.logs,
}));

let host: HTMLDivElement;
let root: Root;
let client: QueryClient;
function LocationProbe() { return <output>{useLocation().search}</output>; }
beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  for (const fetch of [mock.audit, mock.units, mock.logs]) fetch.mockReset().mockResolvedValue({ rows: [], total: 100 });
  mock.export.mockReset(); mock.success.mockClear(); mock.warning.mockClear(); mock.error.mockClear();
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
});
afterEach(async () => {
  await act(async () => root.unmount()); client.clear(); host.remove(); vi.unstubAllGlobals();
});
async function settle() { await act(async () => { await new Promise((resolve) => setTimeout(resolve, 400)); }); }
async function mount(page: React.ReactNode, search: string) {
  await act(async () => root.render(
    <QueryClientProvider client={client}><MemoryRouter initialEntries={[`/${search}`]}>
      {page}<LocationProbe />
    </MemoryRouter></QueryClientProvider>,
  ));
  await settle();
}
function button(label: string) { return [...host.querySelectorAll("button")].find((b) => b.textContent?.trim() === label)!; }

it.each([
  ["Auditoria", <AuditoriaPage />, "?q=teste&action=update&area=unit&admin=someone&from=2026-09-01&to=2026-09-22&keep=yes", mock.audit],
  ["Condomínios", <CondominiosPage />, "?q=teste&active=inactive&keep=yes", mock.units],
  ["Logs", <LogsPage />, "?q=teste&actor=Ana&category=evento&level=error&from=2026-09-01&to=2026-09-22&keep=yes", mock.logs],
])("%s limpa todos os filtros, preserva parâmetros alheios e volta à primeira página", async (_, page, search, fetch) => {
  await mount(page, search);
  await act(async () => button("Próxima").click());
  await settle();
  expect(fetch.mock.lastCall?.[0].page).toBe(2);
  await act(async () => button("Limpar filtros").click());
  await settle();
  expect(host.querySelector("output")?.textContent).toBe("?keep=yes");
  expect(fetch.mock.lastCall?.[0].page).toBe(1);
  expect(fetch.mock.lastCall?.[0].search).toBe("");
});

it("o patch remove filtros de período de uma vez e mantém os valores padrão", async () => {
  function Probe() {
    const patch = useUrlFilterPatch();
    const [period] = useUrlFilterState("period", "7d");
    return <><span data-period>{period}</span><button onClick={() => patch({ unit: null, status: null, period: null, from: null, to: null })}>Limpar</button></>;
  }
  await mount(<Probe />, "?unit=x&status=active&period=custom&from=2026-09-01&to=2026-09-22&keep=yes");
  await act(async () => button("Limpar").click());
  expect(host.querySelector("output")?.textContent).toBe("?keep=yes");
  expect(host.querySelector("[data-period]")?.textContent).toBe("7d");
});

it("avisa quando o CSV é limitado e não anuncia exportação completa", async () => {
  const createUrl = vi.fn(() => "blob:test");
  vi.stubGlobal("URL", class extends URL { static createObjectURL = createUrl; static revokeObjectURL = vi.fn(); });
  vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});
  mock.export.mockResolvedValue({ rows: [], truncated: true });
  await mount(<AuditoriaPage />, "?keep=yes");
  await act(async () => button("Exportar CSV").click());
  expect(createUrl).toHaveBeenCalledTimes(1);
  expect(mock.warning.mock.lastCall?.[0]).toContain("há mais resultados. Reduza o período");
  expect(mock.success).not.toHaveBeenCalled();
});

it("não inicia download nem anuncia sucesso quando a exportação falha", async () => {
  const createUrl = vi.fn();
  vi.stubGlobal("URL", class extends URL { static createObjectURL = createUrl; });
  mock.export.mockRejectedValue(new Error("Falha no segundo lote"));
  await mount(<AuditoriaPage />, "?keep=yes");
  await act(async () => button("Exportar CSV").click());
  expect(createUrl).not.toHaveBeenCalled();
  expect(mock.success).not.toHaveBeenCalled();
  expect(mock.error).toHaveBeenCalled();
  expect(button("Exportar CSV").disabled).toBe(false);
});
