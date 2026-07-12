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

export type PendingImportError = {
  playlist_id: string;
  playlist_name: string;
  playlist_type: string;
  approval_status: string;
  source_url: string | null;
  operator_name: string | null;
  unit_name: string | null;
  error_code: string | null;
  error_message: string | null;
  error_details: Record<string, unknown> | null;
  last_error_at: string | null;
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

export async function listPendingImportErrors(): Promise<PendingImportError[]> {
  const { data, error } = await supabase.rpc("admin_list_pending_import_errors", { p_limit: 100 });
  if (error) throw error;
  return (Array.isArray(data) ? data : []) as PendingImportError[];
}

export async function acknowledgeImportError(playlistId: string): Promise<void> {
  const { error } = await supabase.rpc("admin_acknowledge_playlist_import_error", {
    p_playlist_id: playlistId,
  });
  if (error) throw error;
}

export async function retryImport(playlistId: string): Promise<void> {
  const { error } = await supabase.rpc("admin_retry_playlist_import", {
    p_playlist: playlistId,
  });
  if (error) throw error;
}
