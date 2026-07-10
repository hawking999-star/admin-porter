import type { ReactNode } from "react";
import { cn } from "@/lib/utils";
import { Card } from "@/components/ui/card";

/**
 * Seção com título padrão do Admin PTM (cabeçalho + conteúdo).
 * Usada para blocos de painel: "Status dos operadores", "Atividade recente" etc.
 */
export function SectionCard({
  title,
  description,
  icon,
  action,
  children,
  bodyClassName,
  className,
}: {
  title: string;
  description?: string;
  icon?: ReactNode;
  action?: ReactNode;
  children: ReactNode;
  bodyClassName?: string;
  className?: string;
}) {
  return (
    <Card className={cn("border-border/80 shadow-sm", className)}>
      <div className="flex items-start justify-between gap-3 border-b border-border/70 px-4 py-3.5 sm:px-5">
        <div className="flex min-w-0 items-center gap-2">
          {icon && <span className="shrink-0 text-muted-foreground">{icon}</span>}
          <div className="min-w-0">
            <h2 className="truncate text-sm font-semibold text-foreground">{title}</h2>
            {description && (
              <p className="truncate text-xs text-muted-foreground">{description}</p>
            )}
          </div>
        </div>
        {action}
      </div>
      <div className={cn("p-4 sm:p-5", bodyClassName)}>{children}</div>
    </Card>
  );
}
