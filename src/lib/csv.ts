export type CsvColumn<Row> = {
  header: string;
  value: (row: Row) => unknown;
};

function csvCell(value: unknown): string {
  const text = value == null
    ? ""
    : typeof value === "string"
      ? value
      : typeof value === "object"
        ? JSON.stringify(value)
        : String(value);
  return `"${text.replaceAll('"', '""')}"`;
}

export function downloadCsv<Row>(filename: string, rows: Row[], columns: CsvColumn<Row>[]): void {
  const header = columns.map((column) => csvCell(column.header)).join(",");
  const body = rows.map((row) => columns.map((column) => csvCell(column.value(row))).join(","));
  const blob = new Blob([String.fromCharCode(0xfeff) + [header, ...body].join("\r\n")], {
    type: "text/csv;charset=utf-8;",
  });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename.endsWith(".csv") ? filename : `${filename}.csv`;
  link.click();
  URL.revokeObjectURL(url);
}
