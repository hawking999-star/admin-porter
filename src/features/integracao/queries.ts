import { supabase } from "@/lib/supabase";
import { getOperationalHealth, type OperationalHealth } from "@/lib/operational";

export type IntegrationQueueStatus = {
  queued: number;
  running: number;
  completed?: number;
  with_errors: number;
  last_activity_at: string | null;
};

export type MusicImportHealth = {
  backend: "legacy" | "shadow" | "pgmq";
  limits: {
    active_playlists: number;
    tracks_per_playlist: number;
    youtube_global: number;
    uploads_global: number;
    youtube_spacing_seconds: number;
    worker_replica_target: number;
  };
  queues: Record<"control" | "tracks", {
    queue_name: string;
    queue_length: number;
    newest_msg_age_sec: number | null;
    oldest_msg_age_sec: number | null;
    total_messages: number;
  }>;
  tasks: {
    queued: number;
    processing: number;
    waiting_provider: number;
    waiting_review: number;
    dead_letter: number;
  };
  active_playlists: number;
  paused_playlists: number;
  provider: {
    provider: string;
    status: "healthy" | "degraded" | "blocked" | "probing";
    next_probe_at: string | null;
    last_success_at: string | null;
    error_code: string | null;
    error_message: string | null;
    circuit_open_seconds: number;
  };
  generated_at: string;
};

export type IntegrationStatus = OperationalHealth & { music_import: MusicImportHealth };

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
  const [health, importHealth] = await Promise.all([
    getOperationalHealth(),
    supabase.rpc("admin_music_import_health"),
  ]);
  if (importHealth.error) throw importHealth.error;
  return { ...health, music_import: importHealth.data as MusicImportHealth };
}

export async function resumeMusicProvider(): Promise<void> {
  const { error } = await supabase.rpc("admin_resume_music_provider", { p_provider: "youtube" });
  if (error) throw error;
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
