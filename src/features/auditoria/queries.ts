import { supabase } from "@/lib/supabase";

export type AuditLogRow = {
  id: string;
  admin_user_id: string | null;
  admin_name: string | null;
  action: string;
  entity_type: string | null;
  entity_id: string | null;
  request_id: string | null;
  before_data: unknown;
  after_data: unknown;
  reason: string | null;
  ip_hash: string | null;
  user_agent: string | null;
  occurred_at: string;
};

export type AuditFilters = {
  page: number;
  pageSize: number;
  search: string;
  action: string;
  entityType: string;
  adminId: string;
  dateFrom: string;
  dateTo: string;
};

export type AuditFilterOptions = {
  actions: string[];
  entityTypes: string[];
  admins: Array<{ id: string; name: string }>;
};

const AUDIT_SELECT = "id, admin_user_id, action, entity_type, entity_id, request_id, before_data, after_data, reason, ip_hash, user_agent, occurred_at, admin_users(display_name)";

function applyAuditFilters(query: any, filters: AuditFilters) {
  let next = query;
  const term = filters.search.trim().replace(/[%,()]/g, "");
  if (term) next = next.or(`action.ilike.%${term}%,entity_type.ilike.%${term}%,reason.ilike.%${term}%`);
  if (filters.action !== "all") next = next.eq("action", filters.action);
  if (filters.entityType !== "all") next = next.eq("entity_type", filters.entityType);
  if (filters.adminId !== "all") next = next.eq("admin_user_id", filters.adminId);
  if (filters.dateFrom) next = next.gte("occurred_at", new Date(`${filters.dateFrom}T00:00:00`).toISOString());
  if (filters.dateTo) next = next.lte("occurred_at", new Date(`${filters.dateTo}T23:59:59.999`).toISOString());
  return next;
}

function mapAuditRow(row: any): AuditLogRow {
  return {
    id: row.id,
    admin_user_id: row.admin_user_id ?? null,
    admin_name: row.admin_users?.display_name ?? null,
    action: row.action,
    entity_type: row.entity_type ?? null,
    entity_id: row.entity_id ?? null,
    request_id: row.request_id ?? null,
    before_data: row.before_data ?? null,
    after_data: row.after_data ?? null,
    reason: row.reason ?? null,
    ip_hash: row.ip_hash ?? null,
    user_agent: row.user_agent ?? null,
    occurred_at: row.occurred_at,
  };
}

export async function listAuditLogs(filters: AuditFilters): Promise<{ rows: AuditLogRow[]; total: number }> {
  const from = Math.max(0, filters.page - 1) * filters.pageSize;
  const to = from + filters.pageSize - 1;
  const query = applyAuditFilters(
    supabase.from("admin_audit_logs").select(AUDIT_SELECT, { count: "exact" }),
    filters,
  );
  const { data, error, count } = await query.order("occurred_at", { ascending: false }).range(from, to);
  if (error) throw error;
  return { rows: (data ?? []).map(mapAuditRow), total: count ?? 0 };
}

export async function listAuditFilterOptions(): Promise<AuditFilterOptions> {
  const { data, error } = await supabase
    .from("admin_audit_logs")
    .select("action, entity_type, admin_user_id, admin_users(display_name)")
    .order("occurred_at", { ascending: false })
    .limit(2000);
  if (error) throw error;

  const actions = new Set<string>();
  const entityTypes = new Set<string>();
  const admins = new Map<string, string>();
  for (const row of data ?? []) {
    if (row.action) actions.add(row.action);
    if (row.entity_type) entityTypes.add(row.entity_type);
    if (row.admin_user_id) admins.set(row.admin_user_id, (row.admin_users as any)?.display_name ?? "Administrador");
  }
  return {
    actions: [...actions].sort((a, b) => actionLabel(a).localeCompare(actionLabel(b), "pt-BR")),
    entityTypes: [...entityTypes].sort((a, b) => entityTypeLabel(a).localeCompare(entityTypeLabel(b), "pt-BR")),
    admins: [...admins].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name, "pt-BR")),
  };
}

export async function exportAuditLogs(filters: AuditFilters): Promise<AuditLogRow[]> {
  const query = applyAuditFilters(supabase.from("admin_audit_logs").select(AUDIT_SELECT), filters);
  const { data, error } = await query.order("occurred_at", { ascending: false }).range(0, 4999);
  if (error) throw error;
  return (data ?? []).map(mapAuditRow);
}

const ACTION_LABELS: Record<string, string> = {
  playlist_approved: "Playlist aprovada",
  playlist_rejected: "Playlist rejeitada",
  playlist_request_reimported: "Playlist reenfileirada",
  operator_created: "Operador criado",
  operator_updated: "Operador atualizado",
  operator_status_changed: "Status do Operador alterado",
  operator_registered_name_corrected: "Nome cadastral corrigido",
  operator_display_name_corrected: "Nome de exibição corrigido",
  unit_created: "Condomínio criado",
  unit_updated: "Condomínio atualizado",
  unit_status_changed: "Status do condomínio alterado",
  feedback_status_changed: "Feedback atualizado",
  app_release_created: "Versão criada",
  app_release_edited: "Versão editada",
  app_release_approved: "Versão aprovada",
  app_release_released: "Versão publicada",
  app_release_superseded: "Versão substituída",
  app_release_blocked: "Versão bloqueada",
  app_release_rollback: "Rollback de versão",
  panel_access_granted: "Acesso ao painel concedido",
  app_access_granted: "Acesso ao app concedido",
  statistics_reset: "Estatísticas zeradas",
  statistics_reset_selective: "Estatísticas zeradas por categoria",
  storage_deletion_jobs_requeued: "Limpeza R2 reenfileirada",
  insert: "Registro criado",
  update: "Registro atualizado",
};

const ENTITY_LABELS: Record<string, string> = {
  analytics: "Analytics",
  operator: "Operadores",
  operators: "Operadores",
  admin_user: "Administradores",
  admin_users: "Administradores",
  unit: "Condomínios",
  units: "Condomínios",
  playlist: "Músicas e playlists",
  playlists: "Músicas e playlists",
  playlist_requests: "Músicas e playlists",
  playlist_track: "Músicas e playlists",
  music_storage: "Armazenamento R2",
  feedback: "Feedback",
  app_release: "Atualizações",
  operator_display_name_moderation_term: "Moderação de nomes",
};

export function actionLabel(action: string): string {
  return ACTION_LABELS[action] ?? action.replace(/_/g, " ").replace(/^./, (value) => value.toUpperCase());
}

export function entityTypeLabel(entityType: string | null): string {
  if (!entityType) return "Sistema";
  return ENTITY_LABELS[entityType] ?? entityType.replace(/_/g, " ").replace(/^./, (value) => value.toUpperCase());
}

export function formatAuditDate(value: string): string {
  return new Date(value).toLocaleString("pt-BR", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}
