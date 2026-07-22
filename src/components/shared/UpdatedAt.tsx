import { Clock3 } from "lucide-react";
import { cn } from "@/lib/utils";

export function formatUpdatedAt(value: string | number | Date | null | undefined): string {
  if (!value) return "Aguardando atualização";
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) return "Horário indisponível";
  return `Atualizado em ${date.toLocaleString("pt-BR", {
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  })}`;
}

export function UpdatedAt({
  value,
  loading = false,
  className,
}: {
  value: string | number | Date | null | undefined;
  loading?: boolean;
  className?: string;
}) {
  return (
    <span className={cn("inline-flex items-center gap-1.5 text-[11px] text-muted-foreground", className)}>
      <Clock3 className={cn("h-3.5 w-3.5", loading && "animate-pulse")} />
      {loading ? "Atualizando..." : formatUpdatedAt(value)}
    </span>
  );
}
