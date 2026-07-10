import type { ReactNode } from "react";
import { cn } from "@/lib/utils";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";

/**
 * Card de métrica padrão do Admin PTM.
 * Único em todo o admin — não duplicar por feature.
 *
 * Layout: ícone à esquerda, valor em destaque, rótulo abaixo e dica opcional.
 * Pode ser clicável (vira um filtro) passando `onClick`; `active` realça a borda.
 */
export function StatCard({
  icon,
  iconClassName,
  label,
  value,
  hint,
  active,
  onClick,
  loading,
}: {
  icon?: ReactNode;
  iconClassName?: string;
  label: string;
  value: ReactNode;
  hint?: ReactNode;
  active?: boolean;
  onClick?: () => void;
  loading?: boolean;
}) {
  const clickable = Boolean(onClick);
  return (
    <Card
      onClick={onClick}
      className={cn(
        "group flex min-h-[88px] items-center gap-3.5 overflow-hidden border-border/80 p-3.5 shadow-sm transition-colors",
        clickable && "cursor-pointer hover:bg-accent/35",
        active ? "border-primary ring-1 ring-primary/30" : clickable && "hover:border-primary/40",
      )}
    >
      {icon && (
        <div
          className={cn(
            "flex h-10 w-10 shrink-0 items-center justify-center rounded-lg",
            iconClassName ?? "bg-primary/10 text-primary",
          )}
        >
          {icon}
        </div>
      )}
      <div className="min-w-0">
        {loading ? (
          <Skeleton className="h-8 w-14" />
        ) : (
          <p className="font-display text-[22px] font-bold leading-tight tracking-tight tabular-nums">
            {value}
          </p>
        )}
        <p className="truncate text-xs font-medium text-muted-foreground">{label}</p>
        {hint && !loading && (
          <p className="mt-0.5 truncate text-xs text-muted-foreground">{hint}</p>
        )}
      </div>
    </Card>
  );
}
