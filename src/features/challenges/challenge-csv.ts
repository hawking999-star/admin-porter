export const CHALLENGE_CSV_HEADERS = [
  "titulo",
  "enunciado",
  "alternativa_a",
  "alternativa_b",
  "alternativa_c",
  "alternativa_d",
  "correta",
] as const;

export type ChallengeCsvRow = {
  line: number;
  title: string;
  prompt: string;
  alternatives: [string, string, string, string];
  correct: string;
  errors: string[];
};

export type ChallengeCsvPreview = {
  rows: ChallengeCsvRow[];
  fileErrors: string[];
  validCount: number;
  invalidCount: number;
};

type CsvRecord = { line: number; cells: string[] };

function parseCsvRecords(source: string): { records: CsvRecord[]; error: string | null } {
  const text = source.replace(/^\uFEFF/, "");
  const records: CsvRecord[] = [];
  let cells: string[] = [];
  let cell = "";
  let line = 1;
  let recordLine = 1;
  let quoted = false;

  const pushRecord = () => {
    cells.push(cell.trim());
    if (cells.some((value) => value.length > 0)) records.push({ line: recordLine, cells });
    cells = [];
    cell = "";
  };

  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];

    if (character === '"') {
      if (quoted && text[index + 1] === '"') {
        cell += '"';
        index += 1;
      } else {
        quoted = !quoted;
      }
      continue;
    }

    if (character === "," && !quoted) {
      cells.push(cell.trim());
      cell = "";
      continue;
    }

    if ((character === "\n" || character === "\r") && !quoted) {
      if (character === "\r" && text[index + 1] === "\n") index += 1;
      pushRecord();
      line += 1;
      recordLine = line;
      continue;
    }

    if (character === "\n" || character === "\r") {
      if (character === "\r" && text[index + 1] === "\n") index += 1;
      cell += "\n";
      line += 1;
      continue;
    }

    cell += character;
  }

  if (quoted) return { records, error: `Aspas não foram fechadas a partir da linha ${recordLine}.` };
  if (cell.length > 0 || cells.length > 0) pushRecord();
  return { records, error: null };
}

function normalizeHeader(value: string) {
  return value.trim().toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");
}

function rowErrors(cells: string[]): string[] {
  const errors: string[] = [];
  if (cells.length !== CHALLENGE_CSV_HEADERS.length) {
    errors.push(`Esperadas 7 colunas, mas foram encontradas ${cells.length}.`);
    return errors;
  }

  const [title, prompt, ...rest] = cells;
  const alternatives = rest.slice(0, 4);
  const correct = rest[4]?.toUpperCase() ?? "";
  if (!title) errors.push("Título obrigatório.");
  else if (title.length > 200) errors.push("Título deve ter no máximo 200 caracteres.");
  if (!prompt) errors.push("Enunciado obrigatório.");
  else if (prompt.length > 2000) errors.push("Enunciado deve ter no máximo 2.000 caracteres.");
  alternatives.forEach((alternative, index) => {
    if (!alternative) errors.push(`Alternativa ${"ABCD"[index]} obrigatória.`);
    else if (alternative.length > 500) errors.push(`Alternativa ${"ABCD"[index]} deve ter no máximo 500 caracteres.`);
  });
  if (!/^[ABCD]$/.test(correct)) errors.push("A resposta correta precisa ser A, B, C ou D.");
  return errors;
}

export function parseChallengeCsv(source: string): ChallengeCsvPreview {
  const parsed = parseCsvRecords(source);
  const fileErrors: string[] = [];
  if (parsed.error) fileErrors.push(parsed.error);
  if (parsed.records.length === 0) fileErrors.push("O arquivo CSV está vazio.");

  const [header, ...dataRecords] = parsed.records;
  if (header) {
    const normalized = header.cells.map(normalizeHeader);
    const expected = CHALLENGE_CSV_HEADERS.map(normalizeHeader);
    if (normalized.length !== expected.length || normalized.some((value, index) => value !== expected[index])) {
      fileErrors.push(`Cabeçalho inválido. Use: ${CHALLENGE_CSV_HEADERS.join(", ")}.`);
    }
  }
  if (header && dataRecords.length === 0) fileErrors.push("A planilha não possui linhas de desafio.");
  if (dataRecords.length > 500) fileErrors.push("O arquivo pode conter no máximo 500 desafios por importação.");

  const rows: ChallengeCsvRow[] = dataRecords.map((record) => {
    const cells = record.cells.map((value) => value.trim());
    const padded = [...cells, "", "", "", "", "", "", ""].slice(0, 7);
    return {
      line: record.line,
      title: padded[0],
      prompt: padded[1],
      alternatives: [padded[2], padded[3], padded[4], padded[5]],
      correct: padded[6].toUpperCase(),
      errors: rowErrors(cells),
    };
  });

  const duplicateGroups = new Map<string, ChallengeCsvRow[]>();
  rows.forEach((row) => {
    if (!row.title || !row.prompt) return;
    const key = `${row.title.toLocaleLowerCase("pt-BR")}\u0000${row.prompt.toLocaleLowerCase("pt-BR")}`;
    duplicateGroups.set(key, [...(duplicateGroups.get(key) ?? []), row]);
  });
  duplicateGroups.forEach((group) => {
    if (group.length < 2) return;
    group.forEach((row) => {
      const otherLines = group.filter((candidate) => candidate !== row).map((candidate) => candidate.line).join(", ");
      row.errors.push(`Desafio duplicado no arquivo (também na linha ${otherLines}).`);
    });
  });

  return {
    rows,
    fileErrors,
    validCount: rows.filter((row) => row.errors.length === 0).length,
    invalidCount: rows.filter((row) => row.errors.length > 0).length,
  };
}
