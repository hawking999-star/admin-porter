import { beforeEach, expect, it, vi } from "vitest";
import { exportAuditLogs, type AuditFilters } from "@/features/auditoria/queries";

const mock = vi.hoisted(() => ({ fetch: vi.fn() }));
vi.mock("@/lib/supabase", async () => {
  const { createClient } = await import("@supabase/supabase-js");
  return { supabase: createClient("https://test.invalid", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { fetch: mock.fetch },
  }) };
});

const filters: AuditFilters = {
  page: 7, pageSize: 25, search: "", action: "all", entityType: "all", adminId: "all", dateFrom: "", dateTo: "",
};
type Row = { id: string; occurred_at: string; action: string };
let rows: Row[];
let apiLimit: number;
let urls: URL[];
function fixture(size: number): Row[] {
  return Array.from({ length: size }, (_, index) => ({
    id: `00000000-0000-0000-0000-${(size - index).toString(16).padStart(12, "0")}`,
    occurred_at: index < 600 ? "2026-09-22T10:00:00+00:00" : "2026-09-21T10:00:00+00:00",
    action: "update",
  }));
}
function response(input: string | URL | Request) {
  const url = new URL(String(input)); urls.push(url);
  let batch = [...rows];
  const cursorFilter = url.searchParams.getAll("or").find((value) => value.includes("occurred_at.lt."));
  if (cursorFilter) {
    const [, date, id] = cursorFilter.match(/occurred_at\.lt\.(.*),and\(occurred_at\.eq\..*,id\.lt\.([^)]*)\)/)!;
    batch = batch.filter((row) => row.occurred_at < date || (row.occurred_at === date && row.id < id));
  }
  const limit = Number(url.searchParams.get("limit"));
  expect(limit).toBeLessThanOrEqual(500);
  expect(url.searchParams.get("order")).toBe("occurred_at.desc,id.desc");
  return new Response(JSON.stringify(batch.slice(0, Math.min(limit, apiLimit))), {
    status: 200, headers: { "Content-Type": "application/json" },
  });
}
beforeEach(() => {
  urls = []; rows = []; apiLimit = 500;
  mock.fetch.mockReset().mockImplementation(async (input: string) => response(input));
});

it("exporta resultado vazio sem marcar corte", async () => {
  expect(await exportAuditLogs(filters)).toEqual({ rows: [], truncated: false });
});

it("exporta múltiplos lotes e desempata datas por ID sem duplicar registros", async () => {
  rows = fixture(1205);
  const result = await exportAuditLogs(filters);
  expect(result.rows.map((row) => row.id)).toEqual(rows.map((row) => row.id));
  expect(result.truncated).toBe(false);
  expect(urls).toHaveLength(4);
});

it("continua buscando mesmo quando a API retorna menos registros que o lote pedido", async () => {
  rows = fixture(805); apiLimit = 87;
  const result = await exportAuditLogs(filters);
  expect(result.rows).toHaveLength(805);
  expect(result.truncated).toBe(false);
});

it.each([5000, 5001, 6000])("detecta corretamente o limite com %i registros", async (size) => {
  rows = fixture(size);
  const result = await exportAuditLogs(filters);
  expect(result.rows).toHaveLength(5000);
  expect(result.truncated).toBe(size > 5000);
});

it("mantém os filtros em todos os lotes e novas ações não deslocam os resultados", async () => {
  rows = fixture(800);
  const expectedIds = rows.map((row) => row.id);
  mock.fetch.mockImplementation(async (input: string) => {
    const result = response(input);
    if (urls.length === 1) rows.unshift({ id: "new", occurred_at: "2026-09-23T10:00:00+00:00", action: "update" });
    return result;
  });
  const result = await exportAuditLogs({ ...filters, search: "teste", action: "update", entityType: "unit", adminId: "admin", dateFrom: "2026-09-01", dateTo: "2026-09-22" });
  expect(result.rows.map((row) => row.id)).toEqual(expectedIds);
  for (const url of urls) {
    expect(url.searchParams.get("action")).toBe("eq.update");
    expect(url.searchParams.get("entity_type")).toBe("eq.unit");
    expect(url.searchParams.get("admin_user_id")).toBe("eq.admin");
    expect(url.searchParams.getAll("occurred_at")).toHaveLength(2);
    expect(url.searchParams.getAll("or")[0]).toContain("action.ilike.%teste%");
  }
});

it("rejeita a exportação inteira se um lote intermediário falhar", async () => {
  rows = fixture(800);
  mock.fetch.mockImplementation(async (input: string) => urls.length
    ? new Response(JSON.stringify({ message: "falha no segundo lote" }), { status: 400 })
    : response(input));
  await expect(exportAuditLogs(filters)).rejects.toMatchObject({ message: "falha no segundo lote" });
});
