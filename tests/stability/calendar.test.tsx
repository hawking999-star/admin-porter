import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { Calendar } from "@/components/ui/calendar";

let host: HTMLDivElement;
let root: Root;
beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  vi.unstubAllGlobals();
});

it("seleciona uma data e navega entre meses com DayPicker 10", async () => {
  function DateFilter() {
    const [selected, setSelected] = useState<Date>();
    return <Calendar mode="single" defaultMonth={new Date(2026, 8, 1)} selected={selected} onSelect={setSelected} />;
  }
  await act(async () => root.render(<DateFilter />));
  const day = host.querySelector<HTMLButtonElement>(`button[data-day="${new Date(2026, 8, 23).toLocaleDateString()}"]`)!;
  expect(day).not.toBeNull();
  await act(async () => day.click());
  expect(host.querySelector<HTMLButtonElement>("button[data-selected-single=true]")?.dataset.day)
    .toBe(new Date(2026, 8, 23).toLocaleDateString());
  await act(async () => host.querySelector<HTMLButtonElement>(".rdp-button_next")!.click());
  expect(host.textContent).toContain("October");
  expect(host.querySelector("table")?.className).toContain("border-collapse");
});
