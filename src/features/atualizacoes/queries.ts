import { supabase } from "@/lib/supabase";

export type ReleaseStatus = "draft" | "testing" | "approved" | "released" | "blocked" | "superseded";

export type AppRelease = {
  id: string;
  version: string;
  channel: string;
  status: ReleaseStatus;
  is_current: boolean;
  mandatory: boolean;
  minimum_version: string | null;
  title: string | null;
  release_notes: string | null;
  manifest_key: string | null;
  installer_key: string | null;
  blockmap_key: string | null;
  sha512: string | null;
  size_bytes: number | null;
  created_at: string;
  updated_at: string;
  approved_at: string | null;
  released_at: string | null;
  blocked_at: string | null;
  block_reason: string | null;
  created_by_name: string | null;
  approved_by_name: string | null;
  released_by_name: string | null;
  blocked_by_name: string | null;
};

export type AppReleaseInput = {
  version?: string;
  title: string;
  release_notes: string;
  channel: string;
  status: "draft" | "testing";
  mandatory: boolean;
  minimum_version: string;
  manifest_key: string;
  installer_key: string;
  blockmap_key: string;
  sha512: string;
  size_bytes: string;
};

export const RELEASE_STATUSES: { value: ReleaseStatus | "all"; label: string }[] = [
  { value: "all", label: "Todos" },
  { value: "draft", label: "Rascunho" },
  { value: "testing", label: "Teste" },
  { value: "approved", label: "Aprovada" },
  { value: "released", label: "Liberada" },
  { value: "blocked", label: "Bloqueada" },
  { value: "superseded", label: "Substituída" },
];

export function statusLabel(status: string) {
  return RELEASE_STATUSES.find((s) => s.value === status)?.label ?? status;
}

export function releaseRequiredFieldsReady(release: AppRelease) {
  return Boolean(
    release.version &&
      release.title?.trim() &&
      release.manifest_key?.trim() &&
      release.installer_key?.trim() &&
      release.blockmap_key?.trim() &&
      release.sha512?.trim() &&
      release.size_bytes &&
      release.size_bytes > 0,
  );
}

function parseSize(value: string) {
  const clean = value.trim();
  return clean ? Number(clean) : null;
}

function inputParams(input: AppReleaseInput) {
  return {
    p_title: input.title.trim() || null,
    p_release_notes: input.release_notes.trim() || null,
    p_channel: input.channel.trim() || "stable",
    p_mandatory: input.mandatory,
    p_minimum_version: input.minimum_version.trim() || null,
    p_manifest_key: input.manifest_key.trim() || null,
    p_installer_key: input.installer_key.trim() || null,
    p_blockmap_key: input.blockmap_key.trim() || null,
    p_sha512: input.sha512.trim() || null,
    p_size_bytes: parseSize(input.size_bytes),
    p_status: input.status,
  };
}

export async function listAppReleases(): Promise<AppRelease[]> {
  const { data, error } = await supabase
    .from("app_releases")
    .select(
      `
      id, version, channel, status, is_current, mandatory, minimum_version, title, release_notes,
      manifest_key, installer_key, blockmap_key, sha512, size_bytes,
      created_at, updated_at, approved_at, released_at, blocked_at, block_reason,
      created_by_admin:admin_users!app_releases_created_by_fkey(display_name),
      approved_by_admin:admin_users!app_releases_approved_by_fkey(display_name),
      released_by_admin:admin_users!app_releases_released_by_fkey(display_name),
      blocked_by_admin:admin_users!app_releases_blocked_by_fkey(display_name)
      `,
    )
    .order("created_at", { ascending: false });

  if (error) throw error;

  return (data ?? []).map((row: any) => ({
    id: row.id,
    version: row.version,
    channel: row.channel,
    status: row.status,
    is_current: row.is_current,
    mandatory: row.mandatory,
    minimum_version: row.minimum_version ?? null,
    title: row.title ?? null,
    release_notes: row.release_notes ?? null,
    manifest_key: row.manifest_key ?? null,
    installer_key: row.installer_key ?? null,
    blockmap_key: row.blockmap_key ?? null,
    sha512: row.sha512 ?? null,
    size_bytes: row.size_bytes ?? null,
    created_at: row.created_at,
    updated_at: row.updated_at,
    approved_at: row.approved_at ?? null,
    released_at: row.released_at ?? null,
    blocked_at: row.blocked_at ?? null,
    block_reason: row.block_reason ?? null,
    created_by_name: row.created_by_admin?.display_name ?? null,
    approved_by_name: row.approved_by_admin?.display_name ?? null,
    released_by_name: row.released_by_admin?.display_name ?? null,
    blocked_by_name: row.blocked_by_admin?.display_name ?? null,
  }));
}

export async function createAppRelease(input: AppReleaseInput): Promise<string> {
  const { data, error } = await supabase.rpc("create_app_release", {
    p_version: input.version?.trim(),
    ...inputParams(input),
  });
  if (error) throw error;
  return data as string;
}

export async function updateAppRelease(id: string, input: AppReleaseInput): Promise<void> {
  const { error } = await supabase.rpc("update_app_release", {
    p_release_id: id,
    ...inputParams(input),
  });
  if (error) throw error;
}

export async function sendAppReleaseToTesting(release: AppRelease): Promise<void> {
  const { error } = await supabase.rpc("update_app_release", {
    p_release_id: release.id,
    p_title: release.title,
    p_release_notes: release.release_notes,
    p_mandatory: release.mandatory,
    p_minimum_version: release.minimum_version,
    p_manifest_key: release.manifest_key,
    p_installer_key: release.installer_key,
    p_blockmap_key: release.blockmap_key,
    p_sha512: release.sha512,
    p_size_bytes: release.size_bytes,
    p_status: "testing",
  });
  if (error) throw error;
}

export async function approveAppRelease(id: string): Promise<void> {
  const { error } = await supabase.rpc("approve_app_release", { p_release_id: id });
  if (error) throw error;
}

export async function releaseAppRelease(id: string): Promise<void> {
  const { error } = await supabase.rpc("release_app_release", { p_release_id: id });
  if (error) throw error;
}

export async function blockAppRelease(id: string, reason: string): Promise<void> {
  const { error } = await supabase.rpc("block_app_release", {
    p_release_id: id,
    p_reason: reason.trim(),
  });
  if (error) throw error;
}

export async function rollbackAppRelease(id: string): Promise<void> {
  const { error } = await supabase.rpc("rollback_app_release", { p_target_release_id: id });
  if (error) throw error;
}
