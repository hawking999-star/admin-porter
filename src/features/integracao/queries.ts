import { supabase } from "@/lib/supabase";
import { getOperationalHealth, type OperationalHealth } from "@/lib/operational";

export type IntegrationQueueStatus = {
  queued: number;
  running: number;
  completed?: number;
  with_errors: number;
  last_activity_at: string | null;
};

export type IntegrationStatus = OperationalHealth;

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
  return getOperationalHealth();
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
