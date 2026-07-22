import { useEffect, useRef, useState } from "react";
import { AlertCircle, CheckCircle2, Download, FileSpreadsheet, Loader2, Upload, X } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Progress } from "@/components/ui/progress";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { unitLabel, type UnitOption } from "@/features/usuarios/queries";
import { parseChallengeCsv, type ChallengeCsvPreview } from "./challenge-csv";
import { challengeCsvTemplate, importChallengesBatch } from "./queries";

type ImportPhase = "idle" | "parsing" | "ready" | "importing" | "success";

function errorMessage(error: unknown, fallback: string) {
  if (error instanceof Error) return error.message;
  if (error && typeof error === "object" && "message" in error && typeof error.message === "string") return error.message;
  return fallback;
}

function csvCell(value: string | number) {
  return `"${String(value).replaceAll('"', '""')}"`;
}

function downloadErrorReport(preview: ChallengeCsvPreview) {
  const rows = preview.rows
    .filter((row) => row.errors.length > 0)
    .map((row) => [row.line, row.title, row.errors.join(" | ")].map(csvCell).join(","));
  const content = String.fromCharCode(0xfeff) + ["linha,titulo,erros", ...rows].join("\r\n") + "\r\n";
  const url = URL.createObjectURL(new Blob([content], { type: "text/csv;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = "erros-importacao-desafios.csv";
  link.click();
  URL.revokeObjectURL(url);
}

function downloadTemplate() {
  const url = URL.createObjectURL(new Blob([challengeCsvTemplate()], { type: "text/csv;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = "modelo-desafio-multipla-escolha.csv";
  link.click();
  URL.revokeObjectURL(url);
}

export function ChallengeImportDialog({
  open,
  onOpenChange,
  units,
  onImported,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  units: UnitOption[];
  onImported: () => void;
}) {
  const inputRef = useRef<HTMLInputElement>(null);
  const parseVersion = useRef(0);
  const abortRef = useRef<AbortController | null>(null);
  const [file, setFile] = useState<File | null>(null);
  const [unitId, setUnitId] = useState("");
  const [preview, setPreview] = useState<ChallengeCsvPreview | null>(null);
  const [phase, setPhase] = useState<ImportPhase>("idle");
  const [progress, setProgress] = useState(0);
  const [importedCount, setImportedCount] = useState(0);

  useEffect(() => () => {
    parseVersion.current += 1;
    abortRef.current?.abort();
  }, []);

  const reset = () => {
    parseVersion.current += 1;
    abortRef.current?.abort();
    abortRef.current = null;
    setFile(null);
    setUnitId("");
    setPreview(null);
    setPhase("idle");
    setProgress(0);
    setImportedCount(0);
    if (inputRef.current) inputRef.current.value = "";
  };

  const handleOpenChange = (nextOpen: boolean) => {
    if (!nextOpen) reset();
    onOpenChange(nextOpen);
  };

  const chooseFile = async (nextFile: File | null) => {
    if (!nextFile) return;
    if (!nextFile.name.toLowerCase().endsWith(".csv")) {
      toast.error("Selecione um arquivo CSV.");
      return;
    }

    const version = parseVersion.current + 1;
    parseVersion.current = version;
    setFile(nextFile);
    setPreview(null);
    setImportedCount(0);
    setPhase("parsing");
    setProgress(15);

    try {
      const content = await nextFile.text();
      if (parseVersion.current !== version) return;
      setProgress(35);
      await new Promise<void>((resolve) => window.setTimeout(resolve, 0));
      const parsed = parseChallengeCsv(content);
      if (parseVersion.current !== version) return;
      setPreview(parsed);
      setProgress(50);
      setPhase("ready");
    } catch (error) {
      setPhase("idle");
      setProgress(0);
      toast.error(errorMessage(error, "Não foi possível ler o arquivo CSV."));
    }
  };

  const removeFile = () => {
    parseVersion.current += 1;
    setFile(null);
    setPreview(null);
    setPhase("idle");
    setProgress(0);
    if (inputRef.current) inputRef.current.value = "";
  };

  const cancelImport = () => {
    abortRef.current?.abort();
    abortRef.current = null;
    setPhase("ready");
    setProgress(50);
    toast.info("Importação cancelada. Nenhum desafio foi salvo.");
  };

  const runImport = async () => {
    if (!unitId) return toast.error("Escolha onde os desafios serão aplicados.");
    if (!preview || preview.rows.length === 0) return toast.error("Selecione e valide um arquivo CSV.");
    if (preview.fileErrors.length > 0 || preview.invalidCount > 0) {
      return toast.error("Corrija todas as linhas inválidas antes de importar.");
    }

    const controller = new AbortController();
    abortRef.current = controller;
    setPhase("importing");
    setProgress(75);
    try {
      const result = await importChallengesBatch(
        preview.rows.map((row) => ({
          title: row.title,
          prompt: row.prompt,
          alternatives: row.alternatives,
          correct: row.correct,
        })),
        unitId === "global" ? null : unitId,
        controller.signal,
      );
      if (controller.signal.aborted) return;
      setImportedCount(result.imported ?? preview.rows.length);
      setProgress(100);
      setPhase("success");
      onImported();
      toast.success(`${result.imported ?? preview.rows.length} desafio(s) importado(s) como rascunho.`);
    } catch (error) {
      if (controller.signal.aborted) return;
      setPhase("ready");
      setProgress(50);
      toast.error(errorMessage(error, "A importação falhou. Nenhum desafio foi salvo."));
    } finally {
      if (abortRef.current === controller) abortRef.current = null;
    }
  };

  const invalidRows = preview?.rows.filter((row) => row.errors.length > 0) ?? [];
  const canImport = Boolean(
    unitId && preview && preview.rows.length > 0 && preview.fileErrors.length === 0 && preview.invalidCount === 0,
  );

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="max-h-[92vh] max-w-4xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Importar desafios em lote</DialogTitle>
          <DialogDescription>
            Revise e valide todas as linhas antes de salvar. A gravação é transacional: ou todos os desafios entram, ou nenhum entra.
          </DialogDescription>
        </DialogHeader>

        {phase === "success" ? (
          <div className="flex min-h-64 flex-col items-center justify-center rounded-xl border border-success/30 bg-success/10 p-8 text-center">
            <CheckCircle2 className="h-12 w-12 text-success" />
            <h3 className="mt-4 text-lg font-semibold">Importação concluída</h3>
            <p className="mt-1 text-sm text-muted-foreground">
              {importedCount} desafio(s) foram salvos como rascunho e já estão disponíveis na biblioteca.
            </p>
          </div>
        ) : (
          <div className="space-y-5">
            <div className="grid gap-4 md:grid-cols-2">
              <div className="space-y-1.5">
                <label className="text-sm font-semibold">Aplicar em</label>
                <Select value={unitId} onValueChange={setUnitId} disabled={phase === "importing"}>
                  <SelectTrigger><SelectValue placeholder="Selecione o condomínio" /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="global">Todos os condomínios (desafio global)</SelectItem>
                    {units.map((unit) => <SelectItem key={unit.id} value={unit.id}>{unitLabel(unit)}</SelectItem>)}
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1.5">
                <label className="text-sm font-semibold">Arquivo CSV</label>
                <input
                  ref={inputRef}
                  className="hidden"
                  type="file"
                  accept=".csv,text/csv"
                  onChange={(event) => void chooseFile(event.target.files?.[0] ?? null)}
                />
                {file ? (
                  <div className="flex min-h-10 items-center justify-between gap-2 rounded-md border border-border px-3 py-2 text-sm">
                    <span className="flex min-w-0 items-center gap-2"><FileSpreadsheet className="h-4 w-4 shrink-0" /><span className="truncate">{file.name}</span></span>
                    <button type="button" onClick={removeFile} disabled={phase === "importing"} aria-label="Remover arquivo" className="rounded p-1 hover:bg-muted disabled:opacity-50"><X className="h-4 w-4" /></button>
                  </div>
                ) : (
                  <div className="grid grid-cols-2 gap-2">
                    <Button variant="outline" onClick={downloadTemplate}>
                      <Download className="h-4 w-4" /> Baixar modelo
                    </Button>
                    <Button variant="outline" onClick={() => inputRef.current?.click()}>
                      <Upload className="h-4 w-4" /> Selecionar CSV
                    </Button>
                  </div>
                )}
              </div>
            </div>

            {phase !== "idle" && (
              <div className="rounded-lg border border-border p-3">
                <div className="mb-2 flex items-center justify-between text-xs text-muted-foreground">
                  <span>{phase === "parsing" ? "Lendo e validando o arquivo" : phase === "importing" ? "Gravando transação no Supabase" : "Arquivo validado"}</span>
                  <span>{progress}%</span>
                </div>
                <Progress value={progress} />
              </div>
            )}

            {preview && (
              <>
                <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
                  <div className="rounded-lg border p-3"><p className="text-xs text-muted-foreground">Linhas</p><p className="text-xl font-semibold">{preview.rows.length}</p></div>
                  <div className="rounded-lg border p-3"><p className="text-xs text-muted-foreground">Válidas</p><p className="text-xl font-semibold text-success">{preview.validCount}</p></div>
                  <div className="rounded-lg border p-3"><p className="text-xs text-muted-foreground">Com erro</p><p className="text-xl font-semibold text-destructive">{preview.invalidCount}</p></div>
                  <div className="rounded-lg border p-3"><p className="text-xs text-muted-foreground">Destino</p><p className="truncate text-sm font-semibold">{unitId === "global" ? "Todos" : units.find((unit) => unit.id === unitId)?.name ?? "Não definido"}</p></div>
                </div>

                {preview.fileErrors.length > 0 && (
                  <div className="rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">
                    <div className="flex items-center gap-2 font-semibold"><AlertCircle className="h-4 w-4" /> Problemas no arquivo</div>
                    <ul className="mt-2 list-disc space-y-1 pl-5">{preview.fileErrors.map((message) => <li key={message}>{message}</li>)}</ul>
                  </div>
                )}

                {invalidRows.length > 0 && (
                  <div className="rounded-lg border border-destructive/30">
                    <div className="flex flex-wrap items-center justify-between gap-2 border-b border-destructive/20 bg-destructive/5 p-3">
                      <p className="text-sm font-semibold text-destructive">Relatório de erros por linha</p>
                      <Button size="sm" variant="outline" onClick={() => downloadErrorReport(preview)}>
                        <Download className="h-4 w-4" /> Baixar relatório
                      </Button>
                    </div>
                    <div className="max-h-48 overflow-y-auto p-3">
                      <ul className="space-y-3">
                        {invalidRows.map((row) => (
                          <li key={row.line} className="text-sm">
                            <p className="font-semibold">Linha {row.line}{row.title ? ` · ${row.title}` : ""}</p>
                            <ul className="mt-1 list-disc text-destructive pl-5">{row.errors.map((message) => <li key={message}>{message}</li>)}</ul>
                          </li>
                        ))}
                      </ul>
                    </div>
                  </div>
                )}

                {preview.rows.length > 0 && (
                  <div className="overflow-hidden rounded-lg border border-border">
                    <div className="border-b bg-muted/40 px-3 py-2 text-sm font-semibold">Pré-visualização das primeiras 20 linhas</div>
                    <div className="max-h-64 overflow-auto">
                      <table className="w-full min-w-[720px] text-left text-xs">
                        <thead className="sticky top-0 bg-background"><tr><th className="p-2">Linha</th><th className="p-2">Título</th><th className="p-2">Enunciado</th><th className="p-2">Correta</th><th className="p-2">Validação</th></tr></thead>
                        <tbody>
                          {preview.rows.slice(0, 20).map((row) => (
                            <tr key={row.line} className="border-t"><td className="p-2">{row.line}</td><td className="max-w-48 truncate p-2">{row.title || "—"}</td><td className="max-w-72 truncate p-2">{row.prompt || "—"}</td><td className="p-2">{row.correct || "—"}</td><td className="p-2">{row.errors.length ? <span className="text-destructive">Revisar</span> : <span className="text-success">Válida</span>}</td></tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  </div>
                )}
              </>
            )}
          </div>
        )}

        <DialogFooter>
          {phase === "success" ? (
            <Button onClick={() => handleOpenChange(false)}>Concluir</Button>
          ) : phase === "importing" ? (
            <Button variant="destructive" onClick={cancelImport}>Cancelar importação</Button>
          ) : (
            <>
              <Button variant="outline" onClick={() => handleOpenChange(false)}>Cancelar</Button>
              <Button onClick={() => void runImport()} disabled={!canImport || phase === "parsing"}>
                {phase === "parsing" ? <Loader2 className="h-4 w-4 animate-spin" /> : <Upload className="h-4 w-4" />}
                Importar {preview?.validCount ?? 0} desafio(s)
              </Button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
