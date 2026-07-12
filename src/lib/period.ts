export type PeriodPreset = "7d" | "30d" | "90d" | "custom";

export function todayInput() {
  return new Date().toISOString().slice(0, 10);
}

export function buildPeriodRange(preset: PeriodPreset, customFrom: string, customTo: string) {
  const now = new Date();
  const start = new Date(now);
  const end = new Date(now);

  if (preset === "custom") {
    const from = customFrom ? new Date(`${customFrom}T00:00:00`) : start;
    const to = customTo ? new Date(`${customTo}T23:59:59.999`) : end;
    return { startAt: from.toISOString(), endAt: to.toISOString() };
  }

  const days = preset === "7d" ? 7 : preset === "30d" ? 30 : 90;
  start.setDate(start.getDate() - (days - 1));
  start.setHours(0, 0, 0, 0);
  return { startAt: start.toISOString(), endAt: end.toISOString() };
}
