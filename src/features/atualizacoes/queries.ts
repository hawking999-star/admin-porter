import { supabase } from "@/lib/supabase";

export type ReleaseStatus = "draft" | "testing" | "approved" | "released" | "blocked" | "superseded";

export type PaginatedResult<T> = {
  rows: T[];
  total: number;
};

export type PageParams = {
  page: number;
  pageSize: number;
};

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

const SEMVER_RE = /^\d+\.\d+\.\d+$/;

export type ReleaseContractFields = {
  version?: string | null;
  channel?: string | null;
  title?: string | null;
  manifest_key?: string | null;
  installer_key?: string | null;
  blockmap_key?: string | null;
  sha512?: string | null;
  size_bytes?: number | string | null;
};

function keyErrors(
  label: string,
  raw: string | null | undefined,
  suffix: string,
  required: boolean,
): string[] {
  const value = (raw ?? "").toString().trim();
  if (!value) return required ? [`${label} é obrigatório.`] : [];
  const errs: string[] = [];
  if (!value.startsWith("stable/")) errs.push(`${label} deve começar com "stable/".`);
  if (!value.endsWith(suffix)) errs.push(`${label} deve terminar em "${suffix}".`);
  return errs;
}

/**
 * Valida uma release contra o fluxo real de publicação (R2 privado + Cloudflare
 * Worker + Edge Function `get-current-app-release`). Estas regras espelham o
 * contrato descrito na aba e complementam as checagens já feitas no banco
 * (semver `X.Y.Z`, `size_bytes > 0`, título não vazio, unicidade de `is_current`).
 *
 * - `mode: "full"` → todos os campos obrigatórios; usado como gate de aprovar/liberar.
 * - `mode: "partial"` → versão/título/canal obrigatórios, mas chaves/sha512/tamanho
 *   só são validados quando preenchidos (permite salvar um rascunho ainda incompleto).
 */
export function validateReleaseContract(
  fields: ReleaseContractFields,
  mode: "full" | "partial" = "full",
): string[] {
  const errors: string[] = [];

  const version = (fields.version ?? "").toString().trim();
  if (!version) errors.push("Versão é obrigatória.");
  else if (!SEMVER_RE.test(version)) errors.push("Versão deve ser semântica no formato X.Y.Z (ex.: 1.0.6).");

  const channel = (fields.channel ?? "").toString().trim();
  if (channel !== "stable") errors.push('Canal deve ser exatamente "stable".');

  if (!(fields.title ?? "").toString().trim()) errors.push("Título é obrigatório.");

  const required = mode === "full";
  errors.push(...keyErrors("manifest_key", fields.manifest_key, ".yml", required));
  errors.push(...keyErrors("installer_key", fields.installer_key, ".exe", required));
  errors.push(...keyErrors("blockmap_key", fields.blockmap_key, ".blockmap", required));

  const sha = (fields.sha512 ?? "").toString().trim();
  if (!sha && required) errors.push("sha512 (valor Base64 do latest.yml) é obrigatório.");

  const sizeRaw = fields.size_bytes;
  const size = typeof sizeRaw === "string" ? Number(sizeRaw.trim()) : sizeRaw;
  if (sizeRaw === "" || sizeRaw === null || sizeRaw === undefined) {
    if (required) errors.push("size_bytes é obrigatório e deve ser um inteiro maior que zero.");
  } else if (typeof size !== "number" || !Number.isInteger(size) || size <= 0) {
    errors.push("size_bytes deve ser um inteiro maior que zero.");
  }

  return errors;
}

/** Erros que impedem aprovar/liberar uma release (contrato completo). */
export function releaseContractErrors(release: AppRelease): string[] {
  return validateReleaseContract(release, "full");
}

/** Uma release está pronta para aprovação/liberação quando não há erros de contrato. */
export function releaseRequiredFieldsReady(release: AppRelease): boolean {
  return releaseContractErrors(release).length === 0;
}

/** Erros que impedem salvar o formulário (rascunho pode ter chaves ainda vazias). */
export function releaseFormErrors(input: AppReleaseInput): string[] {
  return validateReleaseContract(input, "partial");
}

export type LatestYmlFields = {
  version: string;
  sha512: string;
  size_bytes: string;
  installer_key: string;
  blockmap_key: string;
  manifest_key: string;
};

/**
 * Lê um `latest.yml` gerado pelo electron-builder e extrai os campos de release,
 * evitando digitação manual de `sha512`/`size`/`version` (fonte principal de erro
 * e de divergência com o instalador). As chaves do R2 são montadas a partir do
 * canal informado seguindo a convenção do projeto — confira-as antes de salvar.
 *
 * Formato esperado (flat): `version:`, `path:` e `sha512:` no nível 0 e o `size:`
 * do primeiro item de `files:`.
 */
export function parseLatestYml(text: string, channel: string): LatestYmlFields {
  const src = text.replace(/\r\n/g, "\n");
  const pick = (re: RegExp) => src.match(re)?.[1]?.trim().replace(/^["']|["']$/g, "") ?? "";

  const version = pick(/^version:\s*(.+)$/m);
  const installerFile = pick(/^path:\s*(.+)$/m);
  const sha512 = pick(/^sha512:\s*(.+)$/m); // nível 0 = hash do instalador
  const size = pick(/^\s+size:\s*(\d+)\s*$/m); // primeiro files[].size

  const missing = [
    !version && "version",
    !installerFile && "path (instalador)",
    !sha512 && "sha512",
    !size && "size",
  ].filter(Boolean);
  if (missing.length > 0) {
    throw new Error(`latest.yml inválido ou incompleto. Faltou: ${missing.join(", ")}.`);
  }

  const ch = channel.trim() || "stable";
  return {
    version,
    sha512,
    size_bytes: size,
    installer_key: `${ch}/${installerFile}`,
    blockmap_key: `${ch}/${installerFile}.blockmap`,
    manifest_key: `${ch}/manifests/${version}.yml`,
  };
}

export type AppReleaseFilters = PageParams & {
  search?: string;
  status?: ReleaseStatus | "all";
};

export type AppReleaseStats = {
  drafts: number;
  approved: number;
  released: number;
};

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

function pageRange(page: number, pageSize: number) {
  const from = Math.max(0, page - 1) * pageSize;
  return { from, to: from + pageSize - 1 };
}

function mapRelease(row: any): AppRelease {
  return {
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
  };
}

const RELEASE_SELECT = `
  id, version, channel, status, is_current, mandatory, minimum_version, title, release_notes,
  manifest_key, installer_key, blockmap_key, sha512, size_bytes,
  created_at, updated_at, approved_at, released_at, blocked_at, block_reason,
  created_by_admin:admin_users!app_releases_created_by_fkey(display_name),
  approved_by_admin:admin_users!app_releases_approved_by_fkey(display_name),
  released_by_admin:admin_users!app_releases_released_by_fkey(display_name),
  blocked_by_admin:admin_users!app_releases_blocked_by_fkey(display_name)
`;

export async function listAppReleases(filters: AppReleaseFilters): Promise<PaginatedResult<AppRelease>> {
  const { from, to } = pageRange(filters.page, filters.pageSize);
  const term = filters.search?.trim().replace(/[%,()]/g, "");

  let query = supabase
    .from("app_releases")
    .select(RELEASE_SELECT, { count: "exact" })
    .order("created_at", { ascending: false });

  if (filters.status && filters.status !== "all") query = query.eq("status", filters.status);
  if (term) {
    const pattern = `%${term}%`;
    query = query.or(
      `version.ilike.${pattern},title.ilike.${pattern},channel.ilike.${pattern},status.ilike.${pattern},manifest_key.ilike.${pattern},installer_key.ilike.${pattern},release_notes.ilike.${pattern}`,
    );
  }

  const { data, error, count } = await query.range(from, to);
  if (error) throw error;

  return { rows: (data ?? []).map(mapRelease), total: count ?? 0 };
}

export async function getCurrentAppRelease(): Promise<AppRelease | null> {
  const { data, error } = await supabase
    .from("app_releases")
    .select(RELEASE_SELECT)
    .eq("is_current", true)
    .eq("status", "released")
    .order("released_at", { ascending: false, nullsFirst: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data ? mapRelease(data) : null;
}

export async function listReleasedNotes(): Promise<AppRelease[]> {
  const { data, error } = await supabase
    .from("app_releases")
    .select(RELEASE_SELECT)
    .eq("status", "released")
    .not("release_notes", "is", null)
    .order("released_at", { ascending: false, nullsFirst: false })
    .order("created_at", { ascending: false })
    .limit(5);
  if (error) throw error;
  return (data ?? []).filter((row: any) => row.release_notes?.trim()).map(mapRelease);
}

export async function countAppReleaseStats(): Promise<AppReleaseStats> {
  const [draft, testing, approved, released] = await Promise.all([
    supabase.from("app_releases").select("id", { count: "exact", head: true }).eq("status", "draft"),
    supabase.from("app_releases").select("id", { count: "exact", head: true }).eq("status", "testing"),
    supabase.from("app_releases").select("id", { count: "exact", head: true }).eq("status", "approved"),
    supabase.from("app_releases").select("id", { count: "exact", head: true }).eq("status", "released"),
  ]);

  const error = draft.error ?? testing.error ?? approved.error ?? released.error;
  if (error) throw error;

  return {
    drafts: (draft.count ?? 0) + (testing.count ?? 0),
    approved: approved.count ?? 0,
    released: released.count ?? 0,
  };
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
