import { cn } from "@/lib/utils";

/**
 * Badge de status padrão do Admin PTM.
 * Única fonte de verdade para cores de status em todas as telas.
 *
 * Cores seguem a paleta Porter:
 * - Ativo / Online / Aprovada  → verde-limão (success) com texto navy
 * - Pendente / Alerta / Ocioso → âmbar (warning)
 * - Erro / Rejeitada / Bloqueado → vermelho (destructive)
 * - Em atendimento / Ação      → azul (primary)
 * - Offline / Fora do turno / Inativo → cinza
 */

type Tone = "success" | "warning" | "danger" | "info" | "neutral";

const TONE_CLASS: Record<Tone, string> = {
  success: "bg-success/30 text-success-foreground ring-success/50",
  warning: "bg-warning/15 text-warning-foreground ring-warning/40",
  danger: "bg-destructive/10 text-destructive ring-destructive/25",
  info: "bg-primary/10 text-primary ring-primary/25",
  neutral: "bg-muted text-muted-foreground ring-border",
};

const TONE_DOT: Record<Tone, string> = {
  success: "bg-success",
  warning: "bg-warning",
  danger: "bg-destructive",
  info: "bg-primary",
  neutral: "bg-muted-foreground/50",
};

/** Registro central de status conhecidos → rótulo PT-BR + tom de cor. */
const STATUS_REGISTRY: Record<string, { label: string; tone: Tone }> = {
  ativo: { label: "Ativo", tone: "success" },
  online: { label: "Online", tone: "success" },
  aprovada: { label: "Aprovada", tone: "success" },
  aprovado: { label: "Aprovado", tone: "success" },
  vinculado: { label: "Vinculado", tone: "success" },

  pendente: { label: "Pendente", tone: "warning" },
  ocioso: { label: "Ocioso", tone: "warning" },
  alerta: { label: "Alerta", tone: "warning" },
  parcial: { label: "Parcial", tone: "warning" },

  erro: { label: "Erro", tone: "danger" },
  rejeitada: { label: "Rejeitada", tone: "danger" },
  rejeitado: { label: "Rejeitado", tone: "danger" },
  bloqueado: { label: "Bloqueado", tone: "danger" },
  falhou: { label: "Falhou", tone: "danger" },

  em_atendimento: { label: "Em atendimento", tone: "info" },
  importando: { label: "Importando", tone: "info" },
  novo: { label: "Novo", tone: "info" },

  offline: { label: "Offline", tone: "neutral" },
  fora_do_turno: { label: "Fora do turno", tone: "neutral" },
  inativo: { label: "Inativo", tone: "neutral" },
  sem_login: { label: "Sem login", tone: "neutral" },
  em_breve: { label: "Em breve", tone: "neutral" },
};

export type StatusToneOrKey = Tone | keyof typeof STATUS_REGISTRY;

export function StatusBadge({
  status,
  label,
  tone,
  dot = true,
  className,
}: {
  /** Chave de status conhecida (ex.: "ativo") OU um tom direto ("success"). */
  status?: string;
  /** Rótulo customizado; sobrescreve o rótulo do registro. */
  label?: string;
  /** Força um tom, ignorando o registro. */
  tone?: Tone;
  dot?: boolean;
  className?: string;
}) {
  const key = (status ?? "").toLowerCase().replace(/\s+/g, "_");
  const registered = STATUS_REGISTRY[key];
  const resolvedTone: Tone =
    tone ?? registered?.tone ?? (isTone(key) ? (key as Tone) : "neutral");
  const resolvedLabel = label ?? registered?.label ?? status ?? "—";

  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-semibold ring-1",
        TONE_CLASS[resolvedTone],
        className,
      )}
    >
      {dot && <span className={cn("h-1.5 w-1.5 rounded-full", TONE_DOT[resolvedTone])} />}
      {resolvedLabel}
    </span>
  );
}

function isTone(v: string): v is Tone {
  return v === "success" || v === "warning" || v === "danger" || v === "info" || v === "neutral";
}
