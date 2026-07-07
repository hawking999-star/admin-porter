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
        "flex min-h-[92px] items-center gap-3.5 p-4 shadow-sm transition-all duration-200",
        clickable && "cursor-pointer hover:-translate-y-px hover:shadow-md",
        active ? "border-primary ring-1 ring-primary/30" : clickable && "hover:border-primary/40",
      )}
    >
      {icon && (
        <div
          className={cn(
            "flex h-11 w-11 shrink-0 items-center justify-center rounded-xl",
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
          <p className="font-display text-2xl font-bold leading-tight tracking-tight tabular-nums">
            {value}
          </p>
        )}
        <p className="truncate text-[13px] font-medium text-muted-foreground">{label}</p>
        {hint && !loading && (
          <p className="mt-0.5 truncate text-xs text-muted-foreground">{hint}</p>
        )}
      </div>
    </Card>
  );
}
