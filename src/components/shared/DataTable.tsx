import type { ReactNode } from "react";
import { Card } from "@/components/ui/card";
import { Table } from "@/components/ui/table";
import { cn } from "@/lib/utils";

export function DataTable({
  children,
  className,
  minWidth = 720,
}: {
  children: ReactNode;
  className?: string;
  minWidth?: number;
}) {
  return (
    <Card className={cn("overflow-hidden shadow-sm", className)}>
      <div className="overflow-x-auto">
        <Table style={{ minWidth }}>{children}</Table>
      </div>
    </Card>
  );
}
