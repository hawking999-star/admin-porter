import assert from "node:assert/strict";
import test from "node:test";
import {
  buildSessionActivityItems,
  type SessionActivityRow,
} from "../src/features/overview/session-activity.ts";

function session(overrides: Partial<SessionActivityRow> & Pick<SessionActivityRow, "id">): SessionActivityRow {
  return {
    id: overrides.id,
    status: "ended",
    started_at: "2026-08-09T12:00:00-03:00",
    ended_at: "2026-08-09T12:03:00-03:00",
    end_reason: "operator_logout",
    app_version: "2.0.10",
    operators: { display_name: "OPERADOR TESTE" },
    ...overrides,
  };
}

test("mantém início e fim da mesma sessão como atividades separadas", () => {
  const erica = session({
    id: "erica-session",
    started_at: "2026-08-09T09:12:40-03:00",
    ended_at: "2026-08-09T12:21:10-03:00",
    operators: { display_name: "ERICA DE JESUS SILVA" },
  });

  const items = buildSessionActivityItems([erica], [erica]);

  assert.equal(items.length, 2);
  assert.deepEqual(items.map((item) => item.id), [
    "sess-start-erica-session",
    "sess-end-erica-session",
  ]);
  assert.equal(items[0].title, "Sessão de Erica de Jesus Silva foi iniciada");
  assert.equal(items[1].title, "Sessão de Erica de Jesus Silva foi encerrada no App");
  assert.equal(items[1].detail, "Duração: 3h 9min · App v2.0.10");
});

test("não colapsa duas sessões diferentes do mesmo operador", () => {
  const earlier = session({ id: "ian-earlier", operators: { display_name: "Ian Santana" } });
  const latest = session({
    id: "ian-latest",
    started_at: "2026-08-09T12:21:27-03:00",
    ended_at: "2026-08-09T12:24:45-03:00",
    operators: { display_name: "Ian Santana" },
  });

  const items = buildSessionActivityItems([earlier, latest], [earlier, latest]);

  assert.equal(items.length, 4);
  assert.equal(new Set(items.map((item) => item.id)).size, 4);
});

test("distingue encerramento administrativo, substituição, expiração e revogação", () => {
  const items = buildSessionActivityItems([], [
    session({ id: "admin", end_reason: "admin_stuck_call_recovery" }),
    session({ id: "superseded", status: "revoked", end_reason: "superseded_by_new_login" }),
    session({ id: "expired", status: "expired", end_reason: null }),
    session({ id: "revoked", status: "revoked", end_reason: null }),
  ]);

  assert.deepEqual(items.map((item) => item.title), [
    "Sessão de Operador Teste foi encerrada pelo Admin",
    "Sessão anterior de Operador Teste foi substituída por um novo login",
    "Sessão de Operador Teste expirou",
    "Sessão de Operador Teste foi revogada",
  ]);
});
