import { supabase } from "@/lib/supabase";

export type IntegrationQueueStatus = {
  queued: number;
  running: number;
  completed?: number;
  with_errors: number;
  last_activity_at: string | null;
};

export type IntegrationStatus = {
  database_connected: boolean;
  imports: IntegrationQueueStatus;
  storage_cleanup: IntegrationQueueStatus;
};

export async function getIntegrationStatus(): Promise<IntegrationStatus> {
  const { data, error } = await supabase.rpc("admin_integration_status");
  if (error) throw error;

  const result = (data ?? {}) as Partial<IntegrationStatus>;
  const queue = (value: unknown): IntegrationQueueStatus => {
    const row = (value ?? {}) as Partial<IntegrationQueueStatus>;
    return {
      queued: Number(row.queued ?? 0),
      running: Number(row.running ?? 0),
      completed: row.completed == null ? undefined : Number(row.completed),
      with_errors: Number(row.with_errors ?? 0),
      last_activity_at: row.last_activity_at ?? null,
    };
  };

  return {
    database_connected: result.database_connected === true,
    imports: queue(result.imports),
    storage_cleanup: queue(result.storage_cleanup),
  };
}
