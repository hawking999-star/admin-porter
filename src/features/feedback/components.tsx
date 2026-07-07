import type { ComponentType } from "react";
import { Lightbulb, AlertTriangle, Heart, type LucideProps } from "lucide-react";
import { cn } from "@/lib/utils";
import { feedbackTypeLabel } from "./queries";

/* ------------------------------------------------------------------ */
/*  Configuração visual por tipo de feedback (apenas aparência)        */
/* ------------------------------------------------------------------ */

type TypeVisual = {
  icon: ComponentType<LucideProps>;
  /** cor do ícone + texto do badge */
  fg: string;
  /** fundo suave do círculo do ícone e do badge */
  bg: string;
  /** anel/borda sutil */
  ring: string;
};

const TYPE_VISUALS: Record<string, TypeVisual> = {
  suggestion: {
    icon: Lightbulb,
    fg: "text-primary",
    bg: "bg-primary/10",
    ring: "ring-primary/20",
  },
  problem: {
    icon: AlertTriangle,
    fg: "text-destructive",
    bg: "bg-destructive/10",
    ring: "ring-destructive/20",
  },
  praise: {
    icon: Heart,
    fg: "text-success-foreground",
    bg: "bg-success/30",
    ring: "ring-success/40",
  },
};

const FALLBACK_VISUAL: TypeVisual = {
  icon: Lightbulb,
  fg: "text-muted-foreground",
  bg: "bg-muted",
  ring: "ring-border",
};

export function typeVisual(type: string): TypeVisual {
  return TYPE_VISUALS[type] ?? FALLBACK_VISUAL;
}

/** Círculo com o ícone do tipo de feedback. */
export function FeedbackTypeIcon({ type, className }: { type: string; className?: string }) {
  const v = typeVisual(type);
  const Icon = v.icon;
  return (
    <div
      className={cn(
        "flex h-10 w-10 shrink-0 items-center justify-center rounded-xl ring-1",
        v.bg,
        v.ring,
        className,
      )}
    >
      <Icon className={cn("h-5 w-5", v.fg)} />
    </div>
  );
}

/** Badge suave (tinted) com o rótulo do tipo. */
export function FeedbackTypeBadge({ type }: { type: string }) {
  const v = typeVisual(type);
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-semibold ring-1",
        v.bg,
        v.fg,
        v.ring,
      )}
    >
      {feedbackTypeLabel(type)}
    </span>
  );
}

/* ------------------------------------------------------------------ */
/*  Avatar com iniciais do operador                                    */
/* ------------------------------------------------------------------ */

export function initialsOf(name: string | null): string {
  if (!name) return "?";
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "?";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

export function OperatorAvatar({ name, className }: { name: string | null; className?: string }) {
  return (
    <div
      className={cn(
        "flex h-7 w-7 shrink-0 select-none items-center justify-center rounded-full",
        "bg-secondary text-[11px] font-semibold text-secondary-foreground",
        className,
      )}
    >
      {initialsOf(name)}
    </div>
  );
}
