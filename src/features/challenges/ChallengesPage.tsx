import { useEffect, useMemo, useRef, useState } from "react";
import { keepPreviousData, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Download, FileSpreadsheet, FileUp, Layers, ListChecks, Pencil, Puzzle, Settings2, Upload, X } from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { EmptyState, ErrorState, FilterBar, PaginationFooter, RetryButton, SearchInput, StatCard, StatusBadge } from "@/components/shared";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useDebounce } from "@/hooks/useDebounce";
import { listUnitOptions, unitLabel } from "@/features/usuarios/queries";
import { CHALLENGE_KINDS, CHALLENGE_STATUSES, DEFAULT_CHALLENGE_RULES, type Challenge, type ChallengeInput, type ChallengeRules, challengeCsvTemplate, challengeKindLabel, challengeStatusBadge, countChallengeStats, getChallengeRules, listChallenges, saveChallengeRules, setChallengeStatus, upsertChallenge } from "./queries";

const PAGE_SIZE = 12;
type UnitOption = { id: string; name: string; city: string | null; state: string | null; code: string | null };

function downloadCsvTemplate() { const blob = new Blob([challengeCsvTemplate()], { type: "text/csv;charset=utf-8;" }); const url = URL.createObjectURL(blob); const link = document.createElement("a"); link.href = url; link.download = "modelo-desafio-multipla-escolha.csv"; link.click(); URL.revokeObjectURL(url); }
function csvColumns(row: string) { return [...row.matchAll(/(?:^|,)(?:"([^"]*)"|([^,]*))/g)].map((m) => (m[1] ?? m[2] ?? "").trim()); }
function errorMessage(error: unknown, fallback: string) {
  if (error instanceof Error) return error.message;
  if (error && typeof error === "object" && "message" in error && typeof error.message === "string") return error.message;
  return fallback;
}

const EMPTY_CHALLENGE: ChallengeInput = { unit_id: null, title: "", prompt: "", alternatives: ["", "", "", ""], correct: "A", status: "draft" };

function ChallengeDialog({ open, onOpenChange, units, challenge, onSaved }: { open: boolean; onOpenChange: (open: boolean) => void; units: UnitOption[]; challenge?: Challenge | null; onSaved: () => void }) {
  const [unitId, setUnitId] = useState(""); const [file, setFile] = useState<File | null>(null); const inputRef = useRef<HTMLInputElement>(null); const [saving, setSaving] = useState(false);
  const [form, setForm] = useState<ChallengeInput>(EMPTY_CHALLENGE);
  const editing = Boolean(challenge);

  useEffect(() => {
    if (!open) return;
    setFile(null);
    setUnitId(challenge ? (challenge.unit_id ?? "global") : "");
    setForm(challenge ? {
      id: challenge.id,
      unit_id: challenge.unit_id,
      title: challenge.title,
      prompt: challenge.prompt,
      alternatives: [...challenge.alternatives] as ChallengeInput["alternatives"],
      correct: challenge.correct,
      status: challenge.status,
    } : { ...EMPTY_CHALLENGE, alternatives: [...EMPTY_CHALLENGE.alternatives] });
  }, [challenge, open]);
  async function submit() {
    if (!unitId) return toast.error("Escolha o condomínio.");
    const selectedUnitId = unitId === "global" ? null : unitId;
    setSaving(true);
    try {
      if (file) {
        if (!file.name.toLowerCase().endsWith(".csv")) throw new Error("PDF ainda não é importado. Use CSV ou cadastro manual.");
        const rows = (await file.text()).replace(/^\uFEFF/, "").split(/\r?\n/).filter(Boolean).slice(1);
        if (!rows.length) throw new Error("A planilha não possui linhas de desafio.");
        for (const row of rows) { const c = csvColumns(row); if (c.length < 7 || !/^[ABCD]$/i.test(c[6] ?? "")) throw new Error(`Linha inválida: ${row}`); await upsertChallenge({ unit_id: selectedUnitId, title: c[0], prompt: c[1], alternatives: [c[2], c[3], c[4], c[5]], correct: c[6].toUpperCase(), status: "draft" }); }
        toast.success(`${rows.length} desafio(s) importado(s) como rascunho.`);
      } else {
        if (!form.title.trim() || !form.prompt.trim() || form.alternatives.some((value) => !value.trim()) || !/^[ABCD]$/.test(form.correct)) throw new Error("Preencha título, enunciado, quatro alternativas e a correta (A-D).");
        await upsertChallenge({ ...form, unit_id: selectedUnitId }); toast.success(editing ? "Desafio atualizado." : "Desafio salvo como rascunho.");
      }
      onSaved(); onOpenChange(false); setFile(null); setUnitId("");
    } catch (error) { toast.error(errorMessage(error, "Não foi possível salvar.")); } finally { setSaving(false); }
  }
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] max-w-xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{editing ? "Editar desafio" : "Novo desafio"}</DialogTitle>
          <DialogDescription>
            {editing ? "Altere o conteúdo e o condomínio deste desafio." : "Cadastre o conteúdo do desafio manualmente ou importe uma planilha CSV."} Os horários, tempos de resposta e punições são definidos em Regras.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4">
          <div className="space-y-1.5">
            <label className="text-sm font-semibold">Condomínio</label>
            <Select value={unitId} onValueChange={setUnitId}>
              <SelectTrigger><SelectValue placeholder="Selecione o condomínio" /></SelectTrigger>
              <SelectContent>
                <SelectItem value="global">Todos os condomínios (desafio geral)</SelectItem>
                {units.map((unit) => <SelectItem key={unit.id} value={unit.id}>{unitLabel(unit)}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>

          <div className="rounded-lg border border-blue-200 bg-blue-50 p-3 text-xs leading-relaxed text-blue-900 dark:border-blue-900/60 dark:bg-blue-950/30 dark:text-blue-100">
            Este cadastro contém somente pergunta, alternativas e resposta correta. Desafios gerais podem aparecer para Operadores de qualquer condomínio; os tempos e bloqueios seguem as regras aplicáveis a cada condomínio.
          </div>

          {!editing && <div className="flex flex-wrap items-center gap-2">
            <Button size="sm" variant="outline" onClick={downloadCsvTemplate}>
              <Download className="h-4 w-4" /> Baixar modelo atualizado
            </Button>
            <input ref={inputRef} className="hidden" type="file" accept=".csv,text/csv" onChange={(event) => setFile(event.target.files?.[0] ?? null)} />
            {file ? (
              <span className="inline-flex items-center gap-1.5 rounded-md border px-2.5 py-1.5 text-sm">
                <FileUp className="h-4 w-4" />{file.name}
                <button type="button" onClick={() => setFile(null)} aria-label="Remover arquivo"><X className="h-4 w-4" /></button>
              </span>
            ) : (
              <Button size="sm" variant="outline" onClick={() => inputRef.current?.click()}>
                <FileSpreadsheet className="h-4 w-4" /> Importar planilha CSV
              </Button>
            )}
          </div>}

          {!file && (
            <div className="space-y-3 rounded-lg border p-3">
              <Input placeholder="Título do desafio" value={form.title} onChange={(event) => setForm({ ...form, title: event.target.value })} />
              <Textarea placeholder="Pergunta ou enunciado" value={form.prompt} onChange={(event) => setForm({ ...form, prompt: event.target.value })} />
              <div className="grid gap-2 sm:grid-cols-2">
                {form.alternatives.map((value, index) => (
                  <Input key={index} placeholder={`Alternativa ${"ABCD"[index]}`} value={value} onChange={(event) => { const alternatives = [...form.alternatives] as ChallengeInput["alternatives"]; alternatives[index] = event.target.value; setForm({ ...form, alternatives }); }} />
                ))}
              </div>
              <div className="space-y-1.5">
                <label className="text-sm font-semibold">Alternativa correta</label>
                <Select value={form.correct} onValueChange={(correct) => setForm({ ...form, correct })}>
                  <SelectTrigger><SelectValue /></SelectTrigger>
                  <SelectContent>{["A", "B", "C", "D"].map((letter) => <SelectItem key={letter} value={letter}>Alternativa {letter}</SelectItem>)}</SelectContent>
                </Select>
              </div>
            </div>
          )}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>Cancelar</Button>
          <Button disabled={saving} onClick={submit}>{editing ? <Pencil className="h-4 w-4" /> : <Upload className="h-4 w-4" />} {editing ? "Salvar alterações" : "Salvar desafio"}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function timeLabel(totalSeconds: number) {
  if (!Number.isFinite(totalSeconds) || totalSeconds <= 0) return "0 segundos";
  if (totalSeconds < 60) return `${totalSeconds} segundo(s)`;
  const minutes = Math.floor(totalSeconds / 60);
  const secondsLeft = totalSeconds % 60;
  return secondsLeft ? `${minutes} min e ${secondsLeft}s` : `${minutes} minuto(s)`;
}

function RuleField({
  label,
  description,
  value,
  onChange,
}: {
  label: string;
  description: string;
  value: number;
  onChange: (value: number) => void;
}) {
  return (
    <label className="space-y-1.5">
      <span className="block text-sm font-semibold text-foreground">{label}</span>
      <span className="block min-h-8 text-xs leading-relaxed text-muted-foreground">{description}</span>
      <div className="relative">
        <Input
          type="number"
          min="1"
          value={value}
          onChange={(event) => onChange(Number(event.target.value))}
          className="pr-20"
        />
        <span className="pointer-events-none absolute inset-y-0 right-3 flex items-center text-xs text-muted-foreground">
          segundos
        </span>
      </div>
      <span className="block text-xs font-medium text-primary">Equivale a {timeLabel(value)}</span>
    </label>
  );
}

function TimeField({ label, description, value, onChange }: { label: string; description: string; value: string; onChange: (value: string) => void }) {
  return (
    <label className="space-y-1.5">
      <span className="block text-sm font-semibold text-foreground">{label}</span>
      <span className="block min-h-8 text-xs leading-relaxed text-muted-foreground">{description}</span>
      <Input type="time" step="60" value={value} onChange={(event) => onChange(event.target.value)} />
    </label>
  );
}

function RulesDialog({ open, onOpenChange, units, onSaved }: { open: boolean; onOpenChange: (open: boolean) => void; units: UnitOption[]; onSaved: () => void }) {
  const [scope, setScope] = useState("global");
  const unitId = scope === "global" ? null : scope;
  const rules = useQuery({ queryKey: ["challenge-rules", unitId], queryFn: () => getChallengeRules(unitId), enabled: open });
  const [draft, setDraft] = useState<ChallengeRules | null>(null);
  const value = draft ?? rules.data ?? DEFAULT_CHALLENGE_RULES;
  const updateNumber = (key: "min_interval_seconds" | "max_interval_seconds" | "response_seconds" | "abandon_block_seconds", next: number) => setDraft((current) => ({ ...(current ?? rules.data ?? DEFAULT_CHALLENGE_RULES), [key]: next }));
  const updateTime = (key: "active_window_start" | "active_window_end", next: string) => setDraft((current) => ({ ...(current ?? rules.data ?? DEFAULT_CHALLENGE_RULES), [key]: next }));
  const updateErrorBlock = (index: number, next: number) => {
    setDraft((current) => {
      const base = current ?? rules.data ?? DEFAULT_CHALLENGE_RULES;
      const errorBlocks = [...base.error_block_seconds];
      errorBlocks[index] = next;
      return { ...base, error_block_seconds: errorBlocks };
    });
  };
  async function save() { try { await saveChallengeRules(unitId, value); toast.success("Regras salvas."); onSaved(); onOpenChange(false); } catch (error) { toast.error(error instanceof Error ? error.message : "Não foi possível salvar regras."); } }
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] max-w-2xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Regras de desafios</DialogTitle>
          <DialogDescription>
            Defina quando os desafios aparecem e quanto dura cada punição. O servidor controla todos os tempos, mesmo se o App for fechado.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-5">
          <div className="space-y-1.5">
            <label className="text-sm font-semibold">Onde estas regras serão aplicadas?</label>
            <Select value={scope} onValueChange={(next) => { setScope(next); setDraft(null); }}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="global">Padrão global — usado por todos os condomínios sem regra própria</SelectItem>
                {units.map((unit) => <SelectItem key={unit.id} value={unit.id}>{unitLabel(unit)}</SelectItem>)}
              </SelectContent>
            </Select>
            <p className="text-xs text-muted-foreground">
              Ao escolher um condomínio, os valores salvos substituem o padrão global somente para os Operadores daquela unidade.
            </p>
          </div>

          <section className="space-y-3 rounded-xl border border-border p-4">
            <div>
              <h3 className="text-sm font-semibold">Horário permitido para desafios</h3>
              <p className="text-xs text-muted-foreground">
                Fora desta faixa, o servidor não entrega desafios e agenda o próximo para a abertura seguinte. O fuso usado é o horário de Brasília.
              </p>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <TimeField label="Começa às" description="Primeiro horário do dia em que um desafio pode aparecer." value={value.active_window_start} onChange={(next) => updateTime("active_window_start", next)} />
              <TimeField label="Termina às" description="A partir deste horário, nenhum novo desafio é apresentado." value={value.active_window_end} onChange={(next) => updateTime("active_window_end", next)} />
            </div>
            <div className="rounded-lg bg-muted/50 px-3 py-2 text-xs text-muted-foreground">
              {value.active_window_start === value.active_window_end
                ? "Horários iguais significam funcionamento durante 24 horas."
                : <>Os desafios podem aparecer diariamente entre <strong>{value.active_window_start}</strong> e <strong>{value.active_window_end}</strong>. Se o início for maior que o fim, a faixa atravessa a madrugada.</>}
            </div>
          </section>

          <section className="space-y-3 rounded-xl border border-border p-4">
            <div>
              <h3 className="text-sm font-semibold">Janela para o próximo desafio</h3>
              <p className="text-xs text-muted-foreground">
                O servidor sorteia um momento entre o mínimo e o máximo. Exemplo: 180–300 segundos significa que o desafio aparecerá aleatoriamente entre 3 e 5 minutos.
              </p>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <RuleField label="Tempo mínimo" description="O desafio nunca aparece antes deste tempo após o início do ciclo." value={value.min_interval_seconds} onChange={(next) => updateNumber("min_interval_seconds", next)} />
              <RuleField label="Tempo máximo" description="Limite para o servidor apresentar o desafio dentro da janela sorteada." value={value.max_interval_seconds} onChange={(next) => updateNumber("max_interval_seconds", next)} />
            </div>
            <div className="rounded-lg bg-muted/50 px-3 py-2 text-xs text-muted-foreground">
              Com os valores atuais, cada desafio aparece entre <strong>{timeLabel(value.min_interval_seconds)}</strong> e <strong>{timeLabel(value.max_interval_seconds)}</strong>.
            </div>
          </section>

          <section className="grid gap-4 rounded-xl border border-border p-4 sm:grid-cols-2">
            <RuleField label="Tempo para responder" description="Contagem iniciada quando o desafio aparece. Se acabar sem resposta, o Operador entra na tela de ociosidade." value={value.response_seconds} onChange={(next) => updateNumber("response_seconds", next)} />
            <RuleField label="Punição por fechar o App" description="Bloqueio aplicado no próximo login quando o App é fechado durante um desafio aberto." value={value.abandon_block_seconds} onChange={(next) => updateNumber("abandon_block_seconds", next)} />
          </section>

          <section className="space-y-3 rounded-xl border border-border p-4">
            <div>
              <h3 className="text-sm font-semibold">Bloqueio progressivo por resposta errada</h3>
              <p className="text-xs text-muted-foreground">
                A contagem reinicia a cada turno. Depois do 3º erro, continua sendo aplicado o tempo configurado para o 3º erro.
              </p>
            </div>
            <div className="grid gap-4 sm:grid-cols-3">
              {["1º erro", "2º erro", "3º erro ou mais"].map((label, index) => (
                <RuleField key={label} label={label} description={`Bloqueio após o ${label.toLowerCase()}.`} value={value.error_block_seconds[index] ?? 0} onChange={(next) => updateErrorBlock(index, next)} />
              ))}
            </div>
          </section>

          <div className="rounded-xl border border-blue-200 bg-blue-50 p-3 text-xs leading-relaxed text-blue-900 dark:border-blue-900/60 dark:bg-blue-950/30 dark:text-blue-100">
            <strong>Durante ligações:</strong> nenhum desafio novo aparece. Se já houver um desafio aberto, ele é pausado. Após o fim da ligação, o servidor espera 90 segundos antes de reagendar.
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>Cancelar</Button>
          <Button onClick={save}>Salvar regras</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function ChallengesPage() {
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");
  const [kind, setKind] = useState("all");
  const [unit, setUnit] = useState("all");
  const [page, setPage] = useState(1);
  const [createOpen, setCreateOpen] = useState(false);
  const [editingChallenge, setEditingChallenge] = useState<Challenge | null>(null);
  const [rulesOpen, setRulesOpen] = useState(false);
  const queryClient = useQueryClient();
  const debouncedSearch = useDebounce(search, 300);
  const units = useQuery({ queryKey: ["challenges", "units"], queryFn: listUnitOptions, staleTime: 60_000 });
  const stats = useQuery({ queryKey: ["challenges", "stats"], queryFn: countChallengeStats, staleTime: 30_000 });
  const filters = useMemo(() => ({ page, pageSize: PAGE_SIZE, search: debouncedSearch, status, kind, unit }), [page, debouncedSearch, status, kind, unit]);
  const list = useQuery({ queryKey: ["challenges", "list", filters], queryFn: () => listChallenges(filters), placeholderData: keepPreviousData });
  const rows = list.data?.rows ?? [];
  const total = list.data?.total ?? 0;
  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: ["challenges"] });
    void queryClient.invalidateQueries({ queryKey: ["challenge-rules"] });
  };
  const changeStatus = async (id: string, next: "draft" | "active" | "inactive" | "archived") => {
    try {
      await setChallengeStatus(id, next);
      toast.success("Status atualizado.");
      refresh();
    } catch (error) {
      toast.error(errorMessage(error, "Não foi possível atualizar o status."));
    }
  };

  return (
    <div>
      <PageHeader
        eyebrow="Engajamento"
        title="Desafios"
        description="Cadastre desafios e defina as janelas, punições e bloqueios que o servidor aplicará aos Operadores."
        action={<div className="flex gap-2"><Button variant="outline" onClick={() => setRulesOpen(true)}><Settings2 className="h-4 w-4" /> Regras</Button><Button onClick={() => setCreateOpen(true)}><Upload className="h-4 w-4" /> Novo desafio</Button></div>}
      />

      <div className="mb-5 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <StatCard icon={<Layers className="h-5 w-5" />} label="Total" value={stats.data?.total ?? 0} loading={stats.isLoading} />
        <StatCard icon={<Puzzle className="h-5 w-5" />} label="Ativos" value={stats.data?.active ?? 0} loading={stats.isLoading} />
        <StatCard icon={<FileSpreadsheet className="h-5 w-5" />} label="Rascunhos" value={stats.data?.draft ?? 0} loading={stats.isLoading} />
        <StatCard icon={<ListChecks className="h-5 w-5" />} label="Aplicações" value={stats.data?.applications ?? 0} hint="Registros reais" loading={stats.isLoading} />
      </div>

      <FilterBar resultText={list.isLoading ? "Carregando…" : `${total} desafio(s)`}>
        <SearchInput value={search} onChange={(value) => { setSearch(value); setPage(1); }} placeholder="Buscar por título ou enunciado" />
        <Select value={unit} onValueChange={(value) => { setUnit(value); setPage(1); }}>
          <SelectTrigger className="w-[190px]"><SelectValue placeholder="Condomínio" /></SelectTrigger>
          <SelectContent><SelectItem value="all">Todos</SelectItem><SelectItem value="global">Globais</SelectItem>{(units.data ?? []).map((item) => <SelectItem key={item.id} value={item.id}>{unitLabel(item)}</SelectItem>)}</SelectContent>
        </Select>
        <Select value={status} onValueChange={(value) => { setStatus(value); setPage(1); }}>
          <SelectTrigger className="w-[145px]"><SelectValue /></SelectTrigger>
          <SelectContent><SelectItem value="all">Todos status</SelectItem>{CHALLENGE_STATUSES.map((item) => <SelectItem key={item.value} value={item.value}>{item.label}</SelectItem>)}</SelectContent>
        </Select>
        <Select value={kind} onValueChange={(value) => { setKind(value); setPage(1); }}>
          <SelectTrigger className="w-[160px]"><SelectValue /></SelectTrigger>
          <SelectContent><SelectItem value="all">Todos tipos</SelectItem>{CHALLENGE_KINDS.map((item) => <SelectItem key={item.value} value={item.value}>{item.label}</SelectItem>)}</SelectContent>
        </Select>
      </FilterBar>

      {list.isError ? (
        <Card><ErrorState title="Não foi possível carregar os desafios." description={(list.error as Error).message} action={<RetryButton onClick={() => list.refetch()} />} /></Card>
      ) : rows.length === 0 && !list.isLoading ? (
        <Card><EmptyState icon={<Puzzle className="h-6 w-6" />} title="Ainda não há desafios." description="Crie um desafio ou importe um CSV para começar." action={<Button onClick={() => setCreateOpen(true)}>Novo desafio</Button>} /></Card>
      ) : (
        <div className="grid gap-3 md:grid-cols-2">
          {rows.map((challenge) => {
            const badge = challengeStatusBadge(challenge.status);
            return (
              <Card key={challenge.id} className="space-y-3 p-5">
                <div className="flex items-center justify-between gap-3"><h3 className="font-semibold">{challenge.title}</h3><StatusBadge label={badge.label} tone={badge.tone} /></div>
                <p className="line-clamp-2 text-sm text-muted-foreground">{challenge.prompt}</p>
                <div className="flex flex-wrap gap-3 text-xs text-muted-foreground"><span>{challengeKindLabel(challenge.kind)}</span><span>Tempo definido nas regras</span><span>{challenge.unit_name ?? "Global"}</span></div>
                <div className="flex gap-2 border-t pt-3">
                  <Button size="sm" variant="outline" onClick={() => setEditingChallenge(challenge)}><Pencil className="h-4 w-4" /> Editar</Button>
                  <Button size="sm" variant="outline" onClick={() => changeStatus(challenge.id, challenge.status === "active" ? "inactive" : "active")}>{challenge.status === "active" ? "Inativar" : "Ativar"}</Button>
                  {challenge.status !== "archived" && <Button size="sm" variant="ghost" onClick={() => changeStatus(challenge.id, "archived")}>Arquivar</Button>}
                </div>
              </Card>
            );
          })}
        </div>
      )}

      {total > 0 && <PaginationFooter page={page} pageSize={PAGE_SIZE} total={total} isLoading={list.isFetching} onPageChange={setPage} />}
      <ChallengeDialog open={createOpen} onOpenChange={setCreateOpen} units={units.data ?? []} onSaved={refresh} />
      <ChallengeDialog open={Boolean(editingChallenge)} onOpenChange={(open) => { if (!open) setEditingChallenge(null); }} units={units.data ?? []} challenge={editingChallenge} onSaved={refresh} />
      <RulesDialog open={rulesOpen} onOpenChange={setRulesOpen} units={units.data ?? []} onSaved={refresh} />
    </div>
  );
}
