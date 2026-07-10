import type { ReactNode } from "react";
import { Card } from "@/components/ui/card";
import { Table } from "@/components/ui/table";
import { cn } from "@/lib/utils";

export function DataTable({
  children,
  className,
  minWidth = 720,
  maxHeight = "min(68vh, 720px)",
}: {
  children: ReactNode;
  className?: string;
  minWidth?: number;
  maxHeight?: string;
}) {
  return (
    <Card className={cn("admin-table-shell overflow-hidden border-border/80 shadow-sm", className)}>
      <div className="overflow-auto overscroll-contain" style={{ maxHeight }}>
        <Table style={{ minWidth }}>{children}</Table>
      </div>
    </Card>
  );
}
