import { Button } from "@/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

const PAGE_SIZE_OPTIONS = [10, 25, 50, 100];

type PaginationFooterProps = {
  page: number;
  pageSize: number;
  total: number;
  isLoading?: boolean;
  onPageChange: (page: number) => void;
  onPageSizeChange?: (pageSize: number) => void;
};

export function PaginationFooter({
  page,
  pageSize,
  total,
  isLoading = false,
  onPageChange,
  onPageSizeChange,
}: PaginationFooterProps) {
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const from = total === 0 ? 0 : (page - 1) * pageSize + 1;
  const to = Math.min(page * pageSize, total);

  return (
    <div className="mt-3 flex flex-wrap items-center justify-between gap-3 text-sm text-muted-foreground">
      <span>
        {total === 0 ? "Nenhum registro" : `Mostrando ${from}-${to} de ${total} registros`}
      </span>
      <div className="flex items-center gap-2">
        {onPageSizeChange && (
          <Select
            value={String(pageSize)}
            onValueChange={(value) => onPageSizeChange(Number(value))}
            disabled={isLoading}
          >
            <SelectTrigger className="h-8 w-[118px] rounded-md">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {PAGE_SIZE_OPTIONS.map((option) => (
                <SelectItem key={option} value={String(option)}>
                  {option} por pagina
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        )}
        <Button
          type="button"
          variant="outline"
          size="sm"
          disabled={isLoading || page <= 1}
          onClick={() => onPageChange(Math.max(1, page - 1))}
        >
          Anterior
        </Button>
        <span className="min-w-20 text-center text-xs">
          Pagina {page} de {totalPages}
        </span>
        <Button
          type="button"
          variant="outline"
          size="sm"
          disabled={isLoading || page >= totalPages}
          onClick={() => onPageChange(Math.min(totalPages, page + 1))}
        >
          Proxima
        </Button>
      </div>
    </div>
  );
}
