import { useEffect, useMemo, useState } from "react";
import { keepPreviousData, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Building2, FileSpreadsheet, Layers, ListChecks, Pencil, Puzzle, Settings2, Upload, X } from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import { EmptyState, ErrorState, FilterBar, PaginationFooter, RetryButton, SearchInput, StatCard, StatusBadge } from "@/components/shared";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useDebounce } from "@/hooks/useDebounce";
import { listUnitOptions, unitLabel } from "@/features/usuarios/queries";
import { CHALLENGE_KINDS, CHALLENGE_STATUSES, DEFAULT_CHALLENGE_RULES, type Challenge, type ChallengeActiveWindow, type ChallengeInput, type ChallengeRules, bulkUpdateChallenges, challengeKindLabel, challengeStatusBadge, countChallengeStats, getChallengeRules, listChallenges, saveChallengeRules, setChallengeStatus, upsertChallenge } from "./queries";
import { ChallengeBulkUnitDialog } from "./ChallengeBulkUnitDialog";
import { ChallengeImportDialog } from "./ChallengeImportDialog";

const PAGE_SIZE = 12;
type UnitOption = { id: string; name: string; city: string | null; state: string | null; code: string | null };

function errorMessage(error: unknown, fallback: string) {
  if (error instanceof Error) return error.message;
  if (error && typeof error === "object" && "message" in error && typeof error.message === "string") return error.message;
  return fallback;
}

const EMPTY_CHALLENGE: ChallengeInput = { unit_id: null, title: "", prompt: "", alternatives: ["", "", "", ""], correct: "A", status: "draft" };

function ChallengeDialog({ open, onOpenChange, units, challenge, onSaved }: { open: boolean; onOpenChange: (open: boolean) => void; units: UnitOption[]; challenge?: Challenge | null; onSaved: () => void }) {
  const [unitId, setUnitId] = useState(""); const [saving, setSaving] = useState(false);
  const [form, setForm] = useState<ChallengeInput>(EMPTY_CHALLENGE);
  const editing = Boolean(challenge);

  useEffect(() => {
    if (!open) return;
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
      if (!form.title.trim() || !form.prompt.trim() || form.alternatives.some((value) => !value.trim()) || !/^[ABCD]$/.test(form.correct)) throw new Error("Preencha título, enunciado, quatro alternativas e a correta (A-D).");
      await upsertChallenge({ ...form, unit_id: selectedUnitId }); toast.success(editing ? "Desafio atualizado." : "Desafio salvo como rascunho.");
      onSaved(); onOpenChange(false); setUnitId("");
    } catch (error) { toast.error(errorMessage(error, "Não foi possível salvar.")); } finally { setSaving(false); }
  }
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] max-w-xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{editing ? "Editar desafio" : "Novo desafio"}</DialogTitle>
          <DialogDescription>
            {editing ? "Altere o conteúdo e o condomínio deste desafio." : "Cadastre um desafio manualmente."} Os horários, tempos de resposta e punições são definidos em Regras.
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

function activeWindowSeconds(start: string, end: string): number {
  const toMinutes = (value: string) => {
    const [hours, minutes] = value.split(":").map(Number);
    return hours * 60 + minutes;
  };
  const startMinutes = toMinutes(start);
  const endMinutes = toMinutes(end);
  if (startMinutes === endMinutes) return 86_400;
  const durationMinutes = endMinutes > startMinutes
    ? endMinutes - startMinutes
    : 1_440 - startMinutes + endMinutes;
  return durationMinutes * 60;
}

function activeWindowSegments(window: ChallengeActiveWindow): Array<[number, number]> {
  const toMinutes = (value: string) => {
    const [hours, minutes] = value.split(":").map(Number);
    return hours * 60 + minutes;
  };
  const start = toMinutes(window.start);
  const end = toMinutes(window.end);
  return start < end ? [[start, end]] : [[start, 1_440], [0, end]];
}

function activeWindowsOverlap(first: ChallengeActiveWindow, second: ChallengeActiveWindow) {
  return activeWindowSegments(first).some(([firstStart, firstEnd]) =>
    activeWindowSegments(second).some(([secondStart, secondEnd]) =>
      Math.max(firstStart, secondStart) < Math.min(firstEnd, secondEnd),
    ),
  );
}

function activeWindowLabel(key: ChallengeActiveWindow["key"]) {
  return key === "daytime" ? "Período diurno" : "Período noturno";
}

function validateChallengeRules(rules: ChallengeRules): string | null {
  if (!Number.isFinite(rules.min_interval_seconds) || rules.min_interval_seconds < 1) {
    return "O tempo mínimo precisa ser maior que zero.";
  }
  if (!Number.isFinite(rules.max_interval_seconds) || rules.max_interval_seconds < rules.min_interval_seconds) {
    return "O tempo máximo precisa ser igual ou maior que o tempo mínimo.";
  }
  if (!Number.isFinite(rules.response_seconds) || rules.response_seconds < 1) {
    return "O tempo para responder precisa ser maior que zero.";
  }
  if (!Number.isFinite(rules.abandon_block_seconds) || rules.abandon_block_seconds < 0) {
    return "A punição por fechar o App não pode ser negativa.";
  }
  if (rules.error_block_seconds.some((seconds) => !Number.isFinite(seconds) || seconds < 0)) {
    return "Os tempos de bloqueio por resposta errada não podem ser negativos.";
  }

  const enabledWindows = (rules.active_windows ?? DEFAULT_CHALLENGE_RULES.active_windows).filter((window) => window.enabled);
  if (!enabledWindows.length) return "Ative pelo menos um período para os desafios.";
  for (const window of enabledWindows) {
    if (window.start === window.end) {
      return `${activeWindowLabel(window.key)} precisa ter horários diferentes.`;
    }
    const windowSeconds = activeWindowSeconds(window.start, window.end);
    if (rules.max_interval_seconds >= windowSeconds) {
      return `O tempo máximo precisa ser menor que ${timeLabel(windowSeconds)} em ${activeWindowLabel(window.key).toLowerCase()}.`;
    }
  }
  if (enabledWindows.length === 2 && activeWindowsOverlap(enabledWindows[0], enabledWindows[1])) {
    return "Os períodos diurno e noturno não podem se sobrepor.";
  }
  return null;
}

const CHALLENGE_RULE_ERROR_MESSAGES: Record<string, string> = {
  janela_intervalo_invalida: "O tempo máximo precisa ser igual ou maior que o tempo mínimo.",
  tempo_resposta_invalido: "O tempo para responder precisa ser maior que zero.",
  tempo_abandono_invalido: "A punição por fechar o App não pode ser negativa.",
  janela_horario_invalida: "O horário permitido informado é inválido.",
  janelas_horario_invalidas: "Os períodos permitidos informados são inválidos.",
  janela_horario_sem_duracao: "O início e o fim de cada período precisam ser diferentes.",
  janela_horario_sem_periodo_ativo: "Ative pelo menos um período para os desafios.",
  janelas_horario_sobrepostas: "Os períodos diurno e noturno não podem se sobrepor.",
  janela_horario_sem_espaco: "Não há espaço suficiente nos períodos para agendar o próximo desafio.",
  fuso_horario_invalido: "O fuso horário configurado é inválido.",
  intervalo_maior_que_janela_horaria: "O tempo máximo precisa ser menor que a faixa de horário permitida.",
  acesso_negado: "Seu acesso de Admin não está ativo.",
  permissao_insuficiente: "Seu perfil não tem permissão para alterar regras de desafios.",
  fora_do_escopo_da_unidade: "Seu perfil não pode alterar regras deste condomínio.",
};

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
  const queryClient = useQueryClient();
  const [scope, setScope] = useState("global");
  const [saving, setSaving] = useState(false);
  const unitId = scope === "global" ? null : scope;
  const rules = useQuery({ queryKey: ["challenge-rules", unitId], queryFn: () => getChallengeRules(unitId), enabled: open });
  const [draft, setDraft] = useState<ChallengeRules | null>(null);
  const value = draft ?? rules.data ?? DEFAULT_CHALLENGE_RULES;
  const activeWindows = value.active_windows ?? DEFAULT_CHALLENGE_RULES.active_windows;
  const updateNumber = (key: "min_interval_seconds" | "max_interval_seconds" | "response_seconds" | "abandon_block_seconds", next: number) => setDraft((current) => ({ ...(current ?? rules.data ?? DEFAULT_CHALLENGE_RULES), [key]: next }));
  const updateActiveWindow = (key: ChallengeActiveWindow["key"], patch: Partial<ChallengeActiveWindow>) => {
    setDraft((current) => {
      const base = current ?? rules.data ?? DEFAULT_CHALLENGE_RULES;
      return {
        ...base,
        active_windows: (base.active_windows ?? DEFAULT_CHALLENGE_RULES.active_windows).map((window) => window.key === key ? { ...window, ...patch } : window),
      };
    });
  };
  const updateErrorBlock = (index: number, next: number) => {
    setDraft((current) => {
      const base = current ?? rules.data ?? DEFAULT_CHALLENGE_RULES;
      const errorBlocks = [...base.error_block_seconds];
      errorBlocks[index] = next;
      return { ...base, error_block_seconds: errorBlocks };
    });
  };
  const handleOpenChange = (nextOpen: boolean) => {
    if (!nextOpen) setDraft(null);
    onOpenChange(nextOpen);
  };
  async function save() {
    const validationMessage = validateChallengeRules(value);
    if (validationMessage) {
      toast.error(validationMessage);
      return;
    }
    setSaving(true);
    try {
      await saveChallengeRules(unitId, value);
      setDraft(null);
      await queryClient.invalidateQueries({ queryKey: ["challenge-rules", unitId] });
      toast.success("Regras salvas e agendamentos atualizados.");
      onSaved();
      onOpenChange(false);
    } catch (error) {
      const message = errorMessage(error, "Não foi possível salvar regras.");
      if (message.includes("challenge_rules_conflict")) {
        setDraft(null);
        await queryClient.invalidateQueries({ queryKey: ["challenge-rules", unitId] });
        toast.error("Outro admin alterou estas regras. Os valores mais recentes foram recarregados; revise antes de salvar novamente.");
        return;
      }
      toast.error(CHALLENGE_RULE_ERROR_MESSAGES[message] ?? message);
    } finally {
      setSaving(false);
    }
  }
  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
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
            <div className="rounded-lg border border-blue-200 bg-blue-50 px-3 py-2 text-xs leading-relaxed text-blue-900 dark:border-blue-900/60 dark:bg-blue-950/30 dark:text-blue-100">
              {scope === "global"
                ? "Você está editando o padrão global. Condomínios que possuem regra própria continuarão usando os valores da regra própria. Para testar um condomínio específico, selecione-o acima."
                : "Você está editando uma regra própria. Estes valores têm prioridade sobre o padrão global para os Operadores deste condomínio."}
            </div>
          </div>

          <section className="space-y-4 rounded-xl border border-border p-4">
            <div>
              <h3 className="text-sm font-semibold">Períodos permitidos para desafios</h3>
              <p className="text-xs text-muted-foreground">
                Separe o dia em até dois períodos. Nos intervalos entre eles, o servidor não entrega desafios e agenda o próximo para a abertura seguinte. O fuso usado é o horário de Brasília.
              </p>
            </div>
            <div className="grid gap-3 lg:grid-cols-2">
              {activeWindows.map((window) => (
                <div key={window.key} className="space-y-3 rounded-lg border border-border bg-muted/20 p-3">
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <p className="text-sm font-semibold">{activeWindowLabel(window.key)}</p>
                      <p className="text-xs text-muted-foreground">
                        {window.key === "daytime" ? "Faixa principal durante o dia." : "Pode atravessar a madrugada, por exemplo 18:00–05:30."}
                      </p>
                    </div>
                    <div className="flex items-center gap-2">
                      <span className="text-xs text-muted-foreground">{window.enabled ? "Ativo" : "Inativo"}</span>
                      <Switch
                        checked={window.enabled}
                        onCheckedChange={(enabled) => updateActiveWindow(window.key, { enabled })}
                        aria-label={`${window.enabled ? "Desativar" : "Ativar"} ${activeWindowLabel(window.key).toLowerCase()}`}
                      />
                    </div>
                  </div>
                  <div className="grid gap-3 sm:grid-cols-2">
                    <TimeField label="Começa às" description="Primeiro horário permitido." value={window.start} onChange={(start) => updateActiveWindow(window.key, { start })} />
                    <TimeField label="Termina às" description="Nenhum desafio novo após este horário." value={window.end} onChange={(end) => updateActiveWindow(window.key, { end })} />
                  </div>
                  <p className="rounded-md bg-background/70 px-2.5 py-2 text-xs text-muted-foreground">
                    {window.enabled
                      ? <>Permitido de <strong>{window.start}</strong> até <strong>{window.end}</strong>{window.start > window.end ? " do dia seguinte" : ""}.</>
                      : "Este período não será usado pelo servidor."}
                  </p>
                </div>
              ))}
            </div>
            <div className="rounded-lg bg-muted/50 px-3 py-2 text-xs leading-relaxed text-muted-foreground">
              Para evitar desafios perto da troca de turno, deixe uma folga entre o fim de um período e o início do próximo. Exemplo: diurno até 17:30 e noturno a partir de 18:00.
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
          <Button variant="outline" onClick={() => handleOpenChange(false)}>Cancelar</Button>
          <Button disabled={saving || rules.isLoading} onClick={save}>{saving ? "Salvando..." : "Salvar regras"}</Button>
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
  const [importOpen, setImportOpen] = useState(false);
  const [editingChallenge, setEditingChallenge] = useState<Challenge | null>(null);
  const [rulesOpen, setRulesOpen] = useState(false);
  const [bulkUnitOpen, setBulkUnitOpen] = useState(false);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [bulkSaving, setBulkSaving] = useState(false);
  const queryClient = useQueryClient();
  const debouncedSearch = useDebounce(search, 300);
  const units = useQuery({ queryKey: ["challenges", "units"], queryFn: listUnitOptions, staleTime: 60_000 });
  const stats = useQuery({ queryKey: ["challenges", "stats"], queryFn: countChallengeStats, staleTime: 30_000 });
  const filters = useMemo(() => ({ page, pageSize: PAGE_SIZE, search: debouncedSearch, status, kind, unit }), [page, debouncedSearch, status, kind, unit]);
  const list = useQuery({ queryKey: ["challenges", "list", filters], queryFn: () => listChallenges(filters), placeholderData: keepPreviousData });
  const rows = list.data?.rows ?? [];
  const total = list.data?.total ?? 0;
  const selectedCount = selectedIds.length;
  const allPageSelected = rows.length > 0 && rows.every((challenge) => selectedIds.includes(challenge.id));

  useEffect(() => {
    setSelectedIds([]);
  }, [page, debouncedSearch, status, kind, unit]);
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
  const toggleSelected = (id: string, checked: boolean) => {
    setSelectedIds((current) => checked ? [...new Set([...current, id])] : current.filter((value) => value !== id));
  };
  const togglePage = (checked: boolean) => {
    const pageIds = rows.map((challenge) => challenge.id);
    setSelectedIds((current) => checked ? [...new Set([...current, ...pageIds])] : current.filter((id) => !pageIds.includes(id)));
  };
  const changeSelectedStatus = async (next: "active" | "inactive" | "archived") => {
    if (!selectedIds.length) return;
    setBulkSaving(true);
    try {
      await bulkUpdateChallenges({ challengeIds: selectedIds, status: next });
      toast.success(`${selectedIds.length} desafio(s) atualizado(s).`);
      setSelectedIds([]);
      refresh();
    } catch (error) {
      toast.error(errorMessage(error, "Não foi possível atualizar os desafios selecionados."));
      refresh();
    } finally {
      setBulkSaving(false);
    }
  };
  const changeSelectedUnit = async (targetUnitId: string | null) => {
    if (!selectedIds.length) return;
    setBulkSaving(true);
    try {
      await bulkUpdateChallenges({ challengeIds: selectedIds, changeUnit: true, unitId: targetUnitId });
      toast.success(`${selectedIds.length} desafio(s) direcionado(s) com sucesso.`);
      setBulkUnitOpen(false);
      setSelectedIds([]);
      refresh();
    } catch (error) {
      toast.error(errorMessage(error, "Não foi possível alterar o condomínio dos desafios selecionados."));
      refresh();
    } finally {
      setBulkSaving(false);
    }
  };

  return (
    <div>
      <PageHeader
        eyebrow="Engajamento"
        title="Desafios"
        description="Cadastre desafios e defina as janelas, punições e bloqueios que o servidor aplicará aos Operadores."
        action={<div className="flex flex-wrap gap-2"><Button variant="outline" onClick={() => setRulesOpen(true)}><Settings2 className="h-4 w-4" /> Regras</Button><Button variant="outline" onClick={() => setImportOpen(true)}><FileSpreadsheet className="h-4 w-4" /> Importar CSV</Button><Button onClick={() => setCreateOpen(true)}><Upload className="h-4 w-4" /> Novo desafio</Button></div>}
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

      {rows.length > 0 && (
        <Card className="mb-4 flex flex-col gap-3 p-3 sm:flex-row sm:items-center sm:justify-between">
          <label className="flex cursor-pointer items-center gap-2 text-sm font-medium">
            <Checkbox
              checked={allPageSelected ? true : selectedCount > 0 ? "indeterminate" : false}
              onCheckedChange={(checked) => togglePage(checked === true)}
              aria-label="Selecionar todos os desafios desta página"
            />
            {selectedCount ? `${selectedCount} selecionado(s)` : "Selecionar esta página"}
          </label>
          {selectedCount > 0 && (
            <div className="flex flex-wrap gap-2">
              <Button size="sm" variant="outline" disabled={bulkSaving} onClick={() => changeSelectedStatus("active")}>Ativar</Button>
              <Button size="sm" variant="outline" disabled={bulkSaving} onClick={() => changeSelectedStatus("inactive")}>Inativar</Button>
              <Button size="sm" variant="outline" disabled={bulkSaving} onClick={() => changeSelectedStatus("archived")}>Arquivar</Button>
              <Button size="sm" variant="outline" disabled={bulkSaving} onClick={() => setBulkUnitOpen(true)}><Building2 className="h-4 w-4" /> Alterar condomínio</Button>
              <Button size="sm" variant="ghost" disabled={bulkSaving} onClick={() => setSelectedIds([])}><X className="h-4 w-4" /> Limpar</Button>
            </div>
          )}
        </Card>
      )}

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
                <div className="flex items-start justify-between gap-3">
                  <div className="flex min-w-0 items-start gap-3">
                    <Checkbox
                      checked={selectedIds.includes(challenge.id)}
                      onCheckedChange={(checked) => toggleSelected(challenge.id, checked === true)}
                      aria-label={`Selecionar desafio ${challenge.title}`}
                    />
                    <h3 className="truncate font-semibold">{challenge.title}</h3>
                  </div>
                  <StatusBadge label={badge.label} tone={badge.tone} />
                </div>
                <p className="line-clamp-2 text-sm text-muted-foreground">{challenge.prompt}</p>
                <div className="flex flex-wrap gap-3 text-xs text-muted-foreground"><span>{challengeKindLabel(challenge.kind)}</span><span>Tempo definido nas regras</span><span>{challenge.unit_name ? unitLabel({ name: challenge.unit_name, city: challenge.unit_city, state: challenge.unit_state }) : "Global"}</span></div>
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
      <ChallengeImportDialog open={importOpen} onOpenChange={setImportOpen} units={units.data ?? []} onImported={refresh} />
      <ChallengeBulkUnitDialog open={bulkUnitOpen} onOpenChange={setBulkUnitOpen} units={units.data ?? []} selectedCount={selectedCount} saving={bulkSaving} onConfirm={(targetUnitId) => void changeSelectedUnit(targetUnitId)} />
      <RulesDialog open={rulesOpen} onOpenChange={setRulesOpen} units={units.data ?? []} onSaved={refresh} />
    </div>
  );
}
