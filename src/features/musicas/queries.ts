import { supabase } from "@/lib/supabase";

/* -------------------------------- Rótulos -------------------------------- */

export const PLAYLIST_STATUSES = [
  { value: "draft", label: "Aguardando link" },
  { value: "pending", label: "Pendente" },
  { value: "approved", label: "Aprovada" },
  { value: "rejected", label: "Rejeitada" },
] as const;

export const PLAYLIST_TYPES = [
  { value: "principal", label: "Principal" },
  { value: "secondary", label: "Secundária" },
] as const;

export type PlaylistApproval = "draft" | "pending" | "approved" | "rejected";
export type PlaylistType = "principal" | "secondary";

export function playlistStatusLabel(v: string) {
  return PLAYLIST_STATUSES.find((s) => s.value === v)?.label ?? v;
}
export function playlistTypeLabel(v: string) {
  return PLAYLIST_TYPES.find((t) => t.value === v)?.label ?? v;
}

/* --------------------------------- Dados --------------------------------- */

export type DownloadStatus = "queued" | "running" | "done" | "partial" | "error";

export type DownloadJob = {
  status: DownloadStatus;
  total: number;
  completed: number;
  failed: number;
  error: string | null;
};

export type Playlist = {
  id: string;
  name: string;
  type: PlaylistType;
  approval_status: PlaylistApproval;
  source_url: string | null;
  submitted_at: string | null;
  reviewed_at: string | null;
  rejection_reason: string | null;
  operator_name: string | null;
  unit_name: string | null;
  unit_city: string | null;
  unit_state: string | null;
  download: DownloadJob | null;
};

export async function listPlaylists(): Promise<Playlist[]> {
  const { data, error } = await supabase
    .from("playlists")
    .select(
      "id, name, type, approval_status, source_url, submitted_at, reviewed_at, rejection_reason, created_at, operators(display_name), units(name, city, state), download_jobs(status, total, completed, failed, error, created_at)",
    )
    .order("submitted_at", { ascending: false, nullsFirst: false })
    .order("created_at", { ascending: false });
  if (error) throw error;

  return (data ?? []).map((p: any) => {
    // pega o job de download mais recente da playlist (se houver)
    const jobs = Array.isArray(p.download_jobs) ? p.download_jobs : [];
    const latest = jobs
      .slice()
      .sort((a: any, b: any) => (a.created_at < b.created_at ? 1 : -1))[0];
    return {
      id: p.id,
      name: p.name,
      type: p.type,
      approval_status: p.approval_status,
      source_url: p.source_url ?? null,
      submitted_at: p.submitted_at ?? null,
      reviewed_at: p.reviewed_at ?? null,
      rejection_reason: p.rejection_reason ?? null,
      operator_name: p.operators?.display_name ?? null,
      unit_name: p.units?.name ?? null,
      unit_city: p.units?.city ?? null,
      unit_state: p.units?.state ?? null,
      download: latest
        ? {
            status: latest.status,
            total: latest.total ?? 0,
            completed: latest.completed ?? 0,
            failed: latest.failed ?? 0,
            error: latest.error ?? null,
          }
        : null,
    };
  });
}

export async function reviewPlaylist(
  id: string,
  action: "approve" | "reject",
  reason?: string,
): Promise<void> {
  const { error } = await supabase.rpc("admin_review_playlist", {
    p_playlist: id,
    p_action: action,
    p_reason: action === "reject" ? reason ?? null : null,
  });
  if (error) throw error;
}
