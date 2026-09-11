import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migrationPath = new URL(
  "../supabase/migrations/20260910193000_superadmin_principal_track_limit.sql",
  import.meta.url,
);
const workerPath = new URL("../railway-worker/main.py", import.meta.url);
const migration = readFileSync(migrationPath, "utf8");
const worker = readFileSync(workerPath, "utf8");

test("cota elevada depende do dono ativo com papel superadmin", () => {
  assert.match(migration, /admin_account\.role = 'superadmin'/);
  assert.match(migration, /admin_account\.active is true/);
  assert.match(migration, /then 400 else 170 end/);
  assert.match(migration, /principal_track_limit_for_playlist\(new\.playlist_id\)/);
});

test("App e worker consultam a mesma regra do banco", () => {
  assert.match(migration, /'principal_track_limit', v_principal_limit/);
  assert.match(migration, /worker_get_principal_track_limit/);
  assert.match(worker, /MAX_TRACKS = max\(int\(env\("MAX_TRACKS", "400"\)\), 400\)/);
  assert.match(worker, /supabase\.rpc\(\s*"worker_get_principal_track_limit"/);
  assert.doesNotMatch(worker, /PRINCIPAL_TRACK_LIMIT = int\(env/);
});

test("uploads e lotes usam a cota calculada", () => {
  assert.match(migration, /v_link_count \+ v_pending_count >= v_principal_limit/);
  assert.match(migration, /v_count >= v_principal_limit/);
  assert.match(migration, /v_requested_count > v_principal_limit/);
});
