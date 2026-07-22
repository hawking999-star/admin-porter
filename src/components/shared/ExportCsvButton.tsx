import { Download } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { downloadCsv, type CsvColumn } from "@/lib/csv";

export function ExportCsvButton<Row>({
  filename,
  rows,
  columns,
  label = "Exportar CSV",
}: {
  filename: string;
  rows: Row[];
  columns: CsvColumn<Row>[];
  label?: string;
}) {
  const exportRows = () => {
    downloadCsv(filename, rows, columns);
    toast.success(`${rows.length} registro(s) exportado(s).`);
  };

  return (
    <Button variant="outline" size="sm" onClick={exportRows} disabled={!rows.length}>
      <Download className="h-4 w-4" /> {label}
    </Button>
  );
}
