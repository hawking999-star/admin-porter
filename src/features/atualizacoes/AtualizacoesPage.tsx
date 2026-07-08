import type { ReactNode } from "react";
import { useEffect, useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  Check,
  FileText,
  History,
  Loader2,
  Plus,
  Rocket,
  RotateCcw,
  Search,
  ShieldAlert,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Switch } from "@/components/ui/switch";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { EmptyState, StatCard, ErrorState, RetryButton } from "@/components/shared";
import {
  approveAppRelease,
  blockAppRelease,
  createAppRelease,
  listAppReleases,
  releaseAppRelease,
  releaseRequiredFieldsReady,
  rollbackAppRelease,
  sendAppReleaseToTesting,
  statusLabel,
  updateAppRelease,
  RELEASE_STATUSES,
  type AppRelease,
  type AppReleaseInput,
  type ReleaseStatus,
} from "./queries";

const EMPTY_INPUT: AppReleaseInput = {
  version: "",
  title: "",
  release_notes: "",
  channel: "stable",
  status: "draft",
  mandatory: true,
  minimum_version: "",
  manifest_key: "",
  installer_key: "",
  blockmap_key: "",
  sha512: "",
  size_bytes: "",
};

const STATUS_CLASS: Record<ReleaseStatus, string> = {
  draft: "bg-muted text-muted-foreground",
  testing: "bg-primary/10 text-primary",
  approved: "bg-success/25 text-success-foreground",
  released: "bg-success/30 text-success-foreground",
  blocked: "bg-destructive/10 text-destructive",
  superseded: "bg-muted text-muted-foreground",
};

function fmtDate(iso: string | null) {
  if (!iso) return "-";
  return new Date(iso).toLocaleString("pt-BR", {
    day: "2-digit",
    month: "2-digit",
    year: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function fmtBytes(value: number | null) {
  if (!value) return "-";
  const mb = value / 1024 / 1024;
  return `${mb.toLocaleString("pt-BR", { maximumFractionDigits: 1 })} MB`;
}

function toInput(release: AppRelease): AppReleaseInput {
  return {
    version: release.version,
    title: release.title ?? "",
    release_notes: release.release_notes ?? "",
    channel: release.channel,
    status: release.status === "testing" ? "testing" : "draft",
    mandatory: release.mandatory,
    minimum_version: release.minimum_version ?? "",
    manifest_key: release.manifest_key ?? "",
    installer_key: release.installer_key ?? "",
    blockmap_key: release.blockmap_key ?? "",
    sha512: release.sha512 ?? "",
    size_bytes: release.size_bytes ? String(release.size_bytes) : "",
  };
}

export function AtualizacoesPage() {
  const qc = useQueryClient();
  const { data, isLoading, isError, error, isFetching } = useQuery({
    queryKey: ["app-releases"],
    queryFn: listAppReleases,
    staleTime: 20_000,
  });

  const [search, setSearch] = useState("");
  const [status, setStatus] = useState<string>("all");
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<AppRelease | null>(null);
  const [confirm, setConfirm] = useState<null | {
    release: AppRelease;
    action: "approve" | "release" | "block" | "rollback";
  }>(null);
  const [blockReason, setBlockReason] = useState("");

  const releases = data ?? [];
  const current = releases.find((r) => r.is_current && r.status === "released") ?? null;

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase();
    return releases.filter((release) => {
      if (status !== "all" && release.status !== status) return false;
      if (!term) return true;
      return [
        release.version,
        release.title,
        release.channel,
        release.status,
        release.manifest_key,
        release.installer_key,
        release.release_notes,
      ]
        .filter(Boolean)
        .join(" ")
        .toLowerCase()
        .includes(term);
    });
  }, [releases, search, status]);

  const stats = useMemo(
    () => ({
      total: releases.length,
      drafts: releases.filter((r) => r.status === "draft" || r.status === "testing").length,
      approved: releases.filter((r) => r.status === "approved").length,
      released: releases.filter((r) => r.status === "released").length,
    }),
    [releases],
  );

  const invalidate = () => qc.invalidateQueries({ queryKey: ["app-releases"] });

  const actionMutation = useMutation({
    mutationFn: async () => {
      if (!confirm) return;
      if (confirm.action === "approve") return approveAppRelease(confirm.release.id);
      if (confirm.action === "release") return releaseAppRelease(confirm.release.id);
      if (confirm.action === "rollback") return rollbackAppRelease(confirm.release.id);
      return blockAppRelease(confirm.release.id, blockReason);
    },
    onSuccess: () => {
      invalidate();
      toast.success("Ação registrada");
      setConfirm(null);
      setBlockReason("");
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível concluir", {
        description: err instanceof Error ? err.message : "Erro inesperado",
      });
    },
  });

  const testingMutation = useMutation({
    mutationFn: sendAppReleaseToTesting,
    onSuccess: () => {
      invalidate();
      toast.success("Versão enviada para teste");
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível enviar para teste", {
        description: err instanceof Error ? err.message : "Erro inesperado",
      });
    },
  });

  const releasedNotes = releases
    .filter((r) => r.status === "released" && r.release_notes?.trim())
    .sort((a, b) => +new Date(b.released_at ?? b.created_at) - +new Date(a.released_at ?? a.created_at));

  return (
    <>
      <PageHeader
        title="Atualizações"
        description="Aprovação e liberação das versões do app dos operadores."
        action={
          <Button
            size="sm"
            onClick={() => {
              setEditing(null);
              setDialogOpen(true);
            }}
          >
            <Plus className="h-4 w-4" /> Nova versão
          </Button>
        }
      />

      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard
          icon={<Rocket className="h-5 w-5" />}
          label="Atual em produção"
          value={current?.version ?? "-"}
          hint={current ? `Liberada em ${fmtDate(current.released_at)}` : "Nenhuma release ativa"}
          loading={isLoading}
        />
        <StatCard icon={<FileText className="h-5 w-5" />} label="Rascunho/teste" value={stats.drafts} loading={isLoading} />
        <StatCard icon={<Check className="h-5 w-5" />} label="Aprovadas" value={stats.approved} loading={isLoading} />
        <StatCard icon={<History className="h-5 w-5" />} label="Histórico liberado" value={stats.released} loading={isLoading} />
      </div>

      {current && (
        <Card className="mb-6 p-4 shadow-sm">
          <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <div className="mb-2 flex flex-wrap items-center gap-2">
                <Badge className="bg-success/30 text-success-foreground">Produção</Badge>
                <span className="font-display text-xl font-semibold">{current.version}</span>
                <span className="text-sm text-muted-foreground">{current.channel}</span>
              </div>
              <p className="font-medium">{current.title ?? "Sem título"}</p>
              {current.release_notes && (
                <p className="mt-1 max-w-3xl whitespace-pre-wrap text-sm text-muted-foreground">
                  {current.release_notes}
                </p>
              )}
            </div>
            <div className="grid gap-1 text-sm text-muted-foreground">
              <span>Obrigatória: {current.mandatory ? "sim" : "não"}</span>
              <span>Versão mínima: {current.minimum_version ?? "-"}</span>
              <span>Liberada por: {current.released_by_name ?? "-"}</span>
            </div>
          </div>
        </Card>
      )}

      <div className="mb-5 flex flex-wrap items-center gap-3">
        <div className="relative w-full max-w-md">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar versão, título, canal, arquivo..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="h-10 rounded-lg pl-9"
          />
        </div>
        <Select value={status} onValueChange={setStatus}>
          <SelectTrigger className="h-10 w-[180px] rounded-lg">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {RELEASE_STATUSES.map((item) => (
              <SelectItem key={item.value} value={item.value}>
                {item.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Button variant="outline" size="sm" onClick={invalidate} disabled={isFetching}>
          {isFetching ? <Loader2 className="h-4 w-4 animate-spin" /> : <History className="h-4 w-4" />}
          Atualizar
        </Button>
        {data && <span className="ml-auto text-sm text-muted-foreground">{filtered.length} de {data.length}</span>}
      </div>

      {isError ? (
        <Card className="shadow-sm">
          <ErrorState
            title="Não foi possível carregar as versões."
            description={(error as Error)?.message}
            action={<RetryButton onClick={invalidate} disabled={isFetching} />}
          />
        </Card>
      ) : (
        <Card className="overflow-hidden shadow-sm">
          <div className="overflow-x-auto">
            <Table className="min-w-[1040px]">
              <TableHeader>
                <TableRow>
                  <TableHead>Versão</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead>Arquivos</TableHead>
                  <TableHead>Notas</TableHead>
                  <TableHead>Responsáveis</TableHead>
                  <TableHead className="text-right">Ações</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {isLoading &&
                  Array.from({ length: 5 }).map((_, i) => (
                    <TableRow key={i}>
                      <TableCell colSpan={6}>
                        <Skeleton className="h-8 w-full" />
                      </TableCell>
                    </TableRow>
                  ))}

                {!isLoading && filtered.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={6}>
                      <EmptyState
                        icon={<Rocket className="h-6 w-6" />}
                        title="Nenhuma versão encontrada."
                        description="Registre uma versão em rascunho para iniciar o fluxo de aprovação."
                      />
                    </TableCell>
                  </TableRow>
                )}

                {!isLoading &&
                  filtered.map((release) => (
                    <ReleaseRow
                      key={release.id}
                      release={release}
                      onEdit={() => {
                        setEditing(release);
                        setDialogOpen(true);
                      }}
                      onConfirm={(action) => {
                        setBlockReason("");
                        setConfirm({ release, action });
                      }}
                      onSendToTesting={() => testingMutation.mutate(release)}
                      busyTesting={testingMutation.isPending}
                    />
                  ))}
              </TableBody>
            </Table>
          </div>
        </Card>
      )}

      {releasedNotes.length > 0 && (
        <section className="mt-8">
          <h2 className="mb-3 font-display text-lg font-semibold">Notas de atualização liberadas</h2>
          <div className="grid gap-3">
            {releasedNotes.map((release) => (
              <Card key={release.id} className="p-4 shadow-sm">
                <div className="mb-2 flex flex-wrap items-center gap-2">
                  <Badge variant="outline">Atualização do aplicativo</Badge>
                  <span className="font-semibold">{release.version}</span>
                  <span className="text-sm text-muted-foreground">{release.title ?? "Sem título"}</span>
                  <span className="ml-auto text-xs text-muted-foreground">{fmtDate(release.released_at)}</span>
                </div>
                <p className="whitespace-pre-wrap text-sm text-muted-foreground">{release.release_notes}</p>
              </Card>
            ))}
          </div>
        </section>
      )}

      <ReleaseDialog
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        release={editing}
        onSaved={() => {
          setDialogOpen(false);
          setEditing(null);
          invalidate();
        }}
      />

      <ConfirmActionDialog
        confirm={confirm}
        reason={blockReason}
        onReasonChange={setBlockReason}
        busy={actionMutation.isPending}
        onCancel={() => setConfirm(null)}
        onConfirm={() => actionMutation.mutate()}
      />
    </>
  );
}

function ReleaseRow({
  release,
  onEdit,
  onConfirm,
  onSendToTesting,
  busyTesting,
}: {
  release: AppRelease;
  onEdit: () => void;
  onConfirm: (action: "approve" | "release" | "block" | "rollback") => void;
  onSendToTesting: () => void;
  busyTesting: boolean;
}) {
  const ready = releaseRequiredFieldsReady(release);
  const canEdit = release.status === "draft" || release.status === "testing";
  const canSendToTesting = release.status === "draft";
  const canApprove = (release.status === "draft" || release.status === "testing") && ready;
  const canRelease = release.status === "approved" && ready;
  const canBlock = release.status !== "blocked" && release.status !== "superseded";
  const canRollback = (release.status === "released" || release.status === "superseded") && !release.is_current && ready;

  return (
    <TableRow>
      <TableCell className="align-top">
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-semibold">{release.version}</span>
          {release.is_current && <Badge className="bg-success/30 text-success-foreground">Atual</Badge>}
        </div>
        <div className="mt-1 text-xs text-muted-foreground">
          {release.channel} · {release.mandatory ? "obrigatória" : "opcional"} · mín. {release.minimum_version ?? "-"}
        </div>
        <div className="mt-1 text-xs text-muted-foreground">{release.title ?? "Sem título"}</div>
      </TableCell>
      <TableCell className="align-top">
        <span className={cn("inline-flex rounded-full px-2.5 py-1 text-xs font-semibold", STATUS_CLASS[release.status])}>
          {statusLabel(release.status)}
        </span>
        {!ready && (
          <p className="mt-2 text-xs text-destructive">
            Campos obrigatórios incompletos para liberar.
          </p>
        )}
      </TableCell>
      <TableCell className="max-w-[260px] align-top text-xs text-muted-foreground">
        <div className="truncate" title={release.manifest_key ?? ""}>Manifest: {release.manifest_key ?? "-"}</div>
        <div className="truncate" title={release.installer_key ?? ""}>Installer: {release.installer_key ?? "-"}</div>
        <div className="truncate" title={release.blockmap_key ?? ""}>Blockmap: {release.blockmap_key ?? "-"}</div>
        <div className="truncate" title={release.sha512 ?? ""}>SHA-512: {release.sha512 ?? "-"}</div>
        <div>{fmtBytes(release.size_bytes)}</div>
      </TableCell>
      <TableCell className="max-w-[240px] align-top">
        <p className="line-clamp-3 whitespace-pre-wrap text-sm text-muted-foreground">
          {release.release_notes ?? "-"}
        </p>
      </TableCell>
      <TableCell className="align-top text-xs text-muted-foreground">
        <div>Criada: {release.created_by_name ?? "-"} · {fmtDate(release.created_at)}</div>
        <div>Aprovada: {release.approved_by_name ?? "-"} · {fmtDate(release.approved_at)}</div>
        <div>Liberada: {release.released_by_name ?? "-"} · {fmtDate(release.released_at)}</div>
        <div>Bloqueada: {release.blocked_by_name ?? "-"} · {fmtDate(release.blocked_at)}</div>
        {release.block_reason && <div className="mt-1 text-destructive">Motivo: {release.block_reason}</div>}
      </TableCell>
      <TableCell className="align-top">
        <div className="flex flex-wrap justify-end gap-1.5">
          {canEdit && (
            <Button size="sm" variant="outline" onClick={onEdit}>
              Editar
            </Button>
          )}
          {canSendToTesting && (
            <Button size="sm" variant="outline" onClick={onSendToTesting} disabled={busyTesting}>
              {busyTesting && <Loader2 className="h-4 w-4 animate-spin" />}
              Enviar para teste
            </Button>
          )}
          {canApprove && (
            <Button size="sm" variant="outline" onClick={() => onConfirm("approve")}>
              <Check className="h-4 w-4" /> Aprovar
            </Button>
          )}
          {canRelease && (
            <Button size="sm" onClick={() => onConfirm("release")}>
              <Rocket className="h-4 w-4" /> Liberar
            </Button>
          )}
          {canBlock && (
            <Button size="sm" variant="outline" className="text-destructive" onClick={() => onConfirm("block")}>
              <ShieldAlert className="h-4 w-4" /> Bloquear
            </Button>
          )}
          {canRollback && (
            <Button size="sm" variant="outline" onClick={() => onConfirm("rollback")}>
              <RotateCcw className="h-4 w-4" /> Rollback
            </Button>
          )}
        </div>
      </TableCell>
    </TableRow>
  );
}

function ReleaseDialog({
  open,
  onOpenChange,
  release,
  onSaved,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  release: AppRelease | null;
  onSaved: () => void;
}) {
  const [input, setInput] = useState<AppReleaseInput>(EMPTY_INPUT);

  useEffect(() => {
    setInput(release ? toInput(release) : EMPTY_INPUT);
  }, [release, open]);

  const mutation = useMutation({
    mutationFn: async () => {
      if (release) {
        await updateAppRelease(release.id, input);
        return;
      }
      await createAppRelease(input);
    },
    onSuccess: () => {
      toast.success(release ? "Versão atualizada" : "Versão criada");
      onSaved();
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível salvar", {
        description: err instanceof Error ? err.message : "Erro inesperado",
      });
    },
  });

  const update = <K extends keyof AppReleaseInput>(key: K, value: AppReleaseInput[K]) =>
    setInput((cur) => ({ ...cur, [key]: value }));

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-3xl">
        <DialogHeader>
          <DialogTitle>{release ? `Editar ${release.version}` : "Nova versão"}</DialogTitle>
          <DialogDescription>
            A versão só chega ao Worker depois de aprovada e liberada explicitamente.
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Versão">
            <Input
              value={input.version ?? ""}
              onChange={(e) => update("version", e.target.value)}
              placeholder="1.0.6"
              disabled={Boolean(release)}
            />
          </Field>
          <Field label="Canal">
            <Input value={input.channel} onChange={(e) => update("channel", e.target.value)} placeholder="stable" />
          </Field>
          <Field label="Título">
            <Input value={input.title} onChange={(e) => update("title", e.target.value)} />
          </Field>
          <Field label="Status inicial">
            <Select value={input.status} onValueChange={(v) => update("status", v as "draft" | "testing")}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="draft">Rascunho</SelectItem>
                <SelectItem value="testing">Teste</SelectItem>
              </SelectContent>
            </Select>
          </Field>
          <Field label="Versão mínima">
            <Input value={input.minimum_version} onChange={(e) => update("minimum_version", e.target.value)} placeholder="1.0.0" />
          </Field>
          <Field label="Tamanho em bytes">
            <Input value={input.size_bytes} onChange={(e) => update("size_bytes", e.target.value)} inputMode="numeric" />
          </Field>
          <Field label="Manifest key">
            <Input value={input.manifest_key} onChange={(e) => update("manifest_key", e.target.value)} placeholder="stable/manifests/1.0.6.yml" />
          </Field>
          <Field label="Installer key">
            <Input value={input.installer_key} onChange={(e) => update("installer_key", e.target.value)} placeholder="stable/Porter-Music-Setup-1.0.6-x64.exe" />
          </Field>
          <Field label="Blockmap key">
            <Input value={input.blockmap_key} onChange={(e) => update("blockmap_key", e.target.value)} placeholder="stable/Porter-Music-Setup-1.0.6-x64.exe.blockmap" />
          </Field>
          <Field label="SHA-512">
            <Input value={input.sha512} onChange={(e) => update("sha512", e.target.value)} />
          </Field>
          <div className="flex items-center justify-between rounded-lg border border-border p-3 sm:col-span-2">
            <div>
              <Label>Atualização obrigatória</Label>
              <p className="text-xs text-muted-foreground">O Worker deve tratar como obrigatória quando liberada.</p>
            </div>
            <Switch checked={input.mandatory} onCheckedChange={(v) => update("mandatory", v)} />
          </div>
          <Field label="Notas da atualização" className="sm:col-span-2">
            <Textarea
              value={input.release_notes}
              onChange={(e) => update("release_notes", e.target.value)}
              rows={5}
              placeholder="Notas que aparecerão no histórico quando a versão estiver liberada."
            />
          </Field>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancelar
          </Button>
          <Button onClick={() => mutation.mutate()} disabled={mutation.isPending}>
            {mutation.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            Salvar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function Field({
  label,
  children,
  className,
}: {
  label: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("grid gap-1.5", className)}>
      <Label>{label}</Label>
      {children}
    </div>
  );
}

function ConfirmActionDialog({
  confirm,
  reason,
  onReasonChange,
  busy,
  onCancel,
  onConfirm,
}: {
  confirm: { release: AppRelease; action: "approve" | "release" | "block" | "rollback" } | null;
  reason: string;
  onReasonChange: (reason: string) => void;
  busy: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  const action = confirm?.action;
  const title =
    action === "approve"
      ? "Aprovar versão?"
      : action === "release"
        ? "Liberar em produção?"
        : action === "rollback"
          ? "Executar rollback?"
          : "Bloquear versão?";
  const description =
    action === "release"
      ? "A versão anterior será marcada como substituída e esta será a única ativa do canal."
      : action === "rollback"
        ? "A versão atual será substituída por esta versão anterior em uma única transação."
        : action === "block"
          ? "A versão bloqueada não será entregue pelo endpoint interno."
          : "A versão ficará pronta para liberação, mas ainda não será entregue ao Worker.";

  return (
    <AlertDialog open={Boolean(confirm)} onOpenChange={(open) => !open && onCancel()}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          <AlertDialogDescription>
            {confirm?.release.version} · {description}
          </AlertDialogDescription>
        </AlertDialogHeader>

        {action === "block" && (
          <div className="grid gap-2">
            <Label>Motivo do bloqueio</Label>
            <Textarea value={reason} onChange={(e) => onReasonChange(e.target.value)} rows={3} />
          </div>
        )}

        <AlertDialogFooter>
          <AlertDialogCancel disabled={busy}>Cancelar</AlertDialogCancel>
          <AlertDialogAction
            onClick={(event) => {
              event.preventDefault();
              onConfirm();
            }}
            disabled={busy || (action === "block" && !reason.trim())}
            className={cn(action === "block" && "bg-destructive text-destructive-foreground hover:bg-destructive/90")}
          >
            {busy && <Loader2 className="h-4 w-4 animate-spin" />}
            Confirmar
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
