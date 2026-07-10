import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

export function FilterBar({
  children,
  resultText,
  className,
}: {
  children: ReactNode;
  resultText?: ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "sticky top-3 z-20 mb-4 flex flex-wrap items-center gap-2.5 rounded-xl border border-border/80 bg-card/95 p-3 shadow-sm backdrop-blur-sm",
        className,
      )}
    >
      <div className="flex min-w-0 flex-1 flex-wrap items-center gap-2.5">{children}</div>
      {resultText && (
        <span className="ml-auto shrink-0 rounded-md bg-muted px-2.5 py-1.5 text-xs font-medium tabular-nums text-muted-foreground">
          {resultText}
        </span>
      )}
    </div>
  );
}
