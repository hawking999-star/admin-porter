import { CalendarDays } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { PeriodPreset } from "@/lib/period";

type PeriodFilterProps = {
  value: PeriodPreset;
  customFrom: string;
  customTo: string;
  onValueChange: (value: PeriodPreset) => void;
  onCustomFromChange: (value: string) => void;
  onCustomToChange: (value: string) => void;
  className?: string;
};

export function PeriodFilter({
  value,
  customFrom,
  customTo,
  onValueChange,
  onCustomFromChange,
  onCustomToChange,
  className,
}: PeriodFilterProps) {
  return (
    <div className={className}>
      <Select value={value} onValueChange={(next) => onValueChange(next as PeriodPreset)}>
        <SelectTrigger className="h-10 min-w-40 bg-background">
          <span className="flex min-w-0 items-center gap-2">
            <CalendarDays className="h-4 w-4 shrink-0 text-muted-foreground" />
            <SelectValue />
          </span>
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="7d">7 dias</SelectItem>
          <SelectItem value="30d">30 dias</SelectItem>
          <SelectItem value="90d">90 dias</SelectItem>
          <SelectItem value="custom">Período personalizado</SelectItem>
        </SelectContent>
      </Select>

      {value === "custom" && (
        <div className="mt-2 grid grid-cols-2 gap-2">
          <Input type="date" aria-label="Data inicial" value={customFrom} max={customTo} onChange={(event) => onCustomFromChange(event.target.value)} />
          <Input type="date" aria-label="Data final" value={customTo} min={customFrom} onChange={(event) => onCustomToChange(event.target.value)} />
        </div>
      )}
    </div>
  );
}
