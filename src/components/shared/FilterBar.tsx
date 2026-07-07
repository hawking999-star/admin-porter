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
    <div className={cn("mb-5 flex flex-wrap items-center gap-3", className)}>
      {children}
      {resultText && <span className="ml-auto text-sm text-muted-foreground">{resultText}</span>}
    </div>
  );
}
