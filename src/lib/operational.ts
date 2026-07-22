import { supabase } from "@/lib/supabase";

export type HealthState = "healthy" | "degraded" | "offline" | "stalled" | "unknown";

export type OperationalHealth = {
  database_connected: boolean;
  generated_at: string;
  worker: {
    state: HealthState;
    status: string | null;
    last_seen_at: string | null;
    age_seconds: number | null;
    started_at: string | null;
    details: {
      version?: string;
      current_job_id?: string | null;
      activity?: string;
      activity_at?: string;
      r2_status?: string;
      r2_checked_at?: string;
      r2_message?: string;
    };
  };
  r2: {
    state: HealthState;
    last_checked_at: string | null;
    message: string | null;
  };
  imports: {
    state: HealthState;
    queued: number;
    running: number;
    completed: number;
    with_errors: number;
    oldest_queued_at: string | null;
    last_activity_at: string | null;
  };
  storage_cleanup: {
    queued: number;
    running: number;
    with_errors: number;
    last_activity_at: string | null;
  };
};

export type EntityHistoryRow = {
  id: string;
  action: string;
  entity_type: string;
  entity_id: string | null;
  reason: string | null;
  before_data: unknown;
  after_data: unknown;
  occurred_at: string;
  admin_name: string;
};

export async function getOperationalHealth(): Promise<OperationalHealth> {
  const { data, error } = await supabase.rpc("admin_integration_status");
  if (error) throw error;
  return data as OperationalHealth;
}

export async function listEntityHistory(entityId: string, entityTypes: string[]): Promise<EntityHistoryRow[]> {
  const { data, error } = await supabase.rpc("admin_entity_history", {
    p_entity_id: entityId,
    p_entity_types: entityTypes.length ? entityTypes : null,
    p_limit: 40,
  });
  if (error) throw error;
  return Array.isArray(data) ? data as EntityHistoryRow[] : [];
}
