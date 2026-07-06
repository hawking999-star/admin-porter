import { supabase } from "@/lib/supabase";

/* ----------------------------- Contagens --------------------------------- */

export type OverviewCounts = {
  units: number;
  operators: number;
  activeSessions: number;
  pendingFeedback: number;
};

export async function fetchOverviewCounts(): Promise<OverviewCounts> {
  const [units, operators, sessions, feedback] = await Promise.all([
    supabase.from("units").select("id", { count: "exact", head: true }).eq("active", true),
    supabase.from("operators").select("id", { count: "exact", head: true }).eq("active", true),
    supabase.from("operator_sessions").select("id", { count: "exact", head: true }).eq("status", "active"),
    supabase.from("feedback").select("id", { count: "exact", head: true }).eq("status", "new"),
  ]);

  return {
    units: units.count ?? 0,
    operators: operators.count ?? 0,
    activeSessions: sessions.count ?? 0,
    pendingFeedback: feedback.count ?? 0,
  };
}

/* -------------------------- Status dos operadores ------------------------ */

export type OperatorStatusRow = {
  operator_id: string;
  status: string;
  display_name: string;
  unit_name: string | null;
};

const STATUS_ORDER = ["active", "in_call", "idle", "blocked", "outside_shift", "offline"] as const;

export type StatusGroup = { status: string; label: string; count: number; operators: OperatorStatusRow[] };

const STATUS_LABELS: Record<string, string> = {
  active: "Online",
  idle: "Ocioso",
  in_call: "Em ligação",
  blocked: "Bloqueado",
  outside_shift: "Fora do turno",
  offline: "Offline",
};

export function statusLabel(s: string) {
  return STATUS_LABELS[s] ?? s;
}

export async function fetchOperatorStatuses(): Promise<StatusGroup[]> {
  const { data, error } = await supabase
    .from("operator_states")
    .select("operator_id, status, operators(display_name, unit_id, units(name))");
  if (error) throw error;

  const rows: OperatorStatusRow[] = (data ?? []).map((r: any) => ({
    operator_id: r.operator_id,
    status: r.status,
    display_name: r.operators?.display_name ?? "—",
    unit_name: r.operators?.units?.name ?? null,
  }));

  const map = new Map<string, OperatorStatusRow[]>();
  for (const r of rows) {
    const arr = map.get(r.status) ?? [];
    arr.push(r);
    map.set(r.status, arr);
  }

  return STATUS_ORDER.map((s) => ({
    status: s,
    label: STATUS_LABELS[s] ?? s,
    count: map.get(s)?.length ?? 0,
    operators: map.get(s) ?? [],
  }));
}

/* --------------------------- Atividade recente --------------------------- */

export type RecentActivity = {
  id: string;
  kind: "audit" | "session";
  title: string;
  detail: string | null;
  occurred_at: string;
};

export async function fetchRecentActivity(): Promise<RecentActivity[]> {
  const [audits, sessions] = await Promise.all([
    supabase
      .from("admin_audit_logs")
      .select("id, action, entity_type, occurred_at, admin_users(display_name)")
      .order("occurred_at", { ascending: false })
      .limit(10),
    supabase
      .from("operator_sessions")
      .select("id, status, started_at, ended_at, operators(display_name)")
      .order("started_at", { ascending: false })
      .limit(10),
  ]);

  if (audits.error) throw audits.error;
  if (sessions.error) throw sessions.error;

  const items: RecentActivity[] = [];

  for (const a of audits.data ?? []) {
    const who = (a as any).admin_users?.display_name ?? "Admin";
    items.push({
      id: a.id,
      kind: "audit",
      title: `${who} — ${a.action}`,
      detail: a.entity_type ?? null,
      occurred_at: a.occurred_at,
    });
  }

  for (const s of sessions.data ?? []) {
    const who = (s as any).operators?.display_name ?? "Operador";
    const action = s.status === "active" ? "iniciou sessão" : `sessão ${s.status}`;
    items.push({
      id: s.id,
      kind: "session",
      title: `${who} ${action}`,
      detail: null,
      occurred_at: s.started_at,
    });
  }

  items.sort((a, b) => new Date(b.occurred_at).getTime() - new Date(a.occurred_at).getTime());
  return items.slice(0, 15);
}
