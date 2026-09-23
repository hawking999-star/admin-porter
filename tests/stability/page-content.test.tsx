import { act, lazy } from "react";
import { createRoot, type Root } from "react-dom/client";
import { MemoryRouter, Route, Routes, Outlet, Link } from "react-router-dom";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { PageContent } from "@/components/layout/PageContent";
import { RenderErrorBoundary } from "@/components/shared/RenderErrorBoundary";

let host: HTMLDivElement;
let root: Root;
beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  vi.spyOn(console, "error").mockImplementation(() => {});
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  vi.unstubAllGlobals();
});

async function renderPage(page: React.ReactNode) {
  await act(async () => root.render(
    <MemoryRouter>
      <Routes>
        <Route element={<><nav><Link to="/ok">Menu</Link></nav><main><Outlet /></main></>}>
          <Route element={<PageContent />}>
            <Route path="/" element={page} />
            <Route path="/ok" element={<p>Página funcionando</p>} />
          </Route>
        </Route>
      </Routes>
    </MemoryRouter>,
  ));
}

it("contém falha de renderização e permite navegar pelo menu para outra página", async () => {
  function Broken(): never { throw new Error("erro de renderização"); }
  await renderPage(<Broken />);
  expect(host.querySelector("nav")?.textContent).toBe("Menu");
  expect(host.querySelector("main [role=alert]")?.textContent).toContain("Não foi possível abrir esta tela");
  await act(async () => host.querySelector("a")!.click());
  expect(host.querySelector("[role=alert]")).toBeNull();
  expect(host.querySelector("main")?.textContent).toBe("Página funcionando");
});

it("mantém carregamento dentro do conteúdo e oferece recarga se um chunk falhar", async () => {
  let reject!: (reason: Error) => void;
  const promise = new Promise<{ default: () => React.ReactNode }>((_, fail) => { reject = fail; });
  const LazyPage = lazy(() => promise);
  await renderPage(<LazyPage />);
  expect(host.querySelector("nav")?.textContent).toBe("Menu");
  expect(host.querySelector('main [aria-label="Carregando página"]')).not.toBeNull();
  await act(async () => { reject(new Error("Failed to fetch dynamically imported module")); });
  expect(host.querySelector("main [role=alert]")).not.toBeNull();
  expect(host.querySelector("button")?.textContent).toBe("Recarregar página");
  const reload = vi.fn();
  vi.stubGlobal("window", { location: { reload } });
  await act(async () => host.querySelector("button")!.click());
  expect(reload).toHaveBeenCalledTimes(1);
  vi.unstubAllGlobals();
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
});

it("oferece recuperação para erros fora das páginas, como no layout", async () => {
  function BrokenShell(): never { throw new Error("layout"); }
  await act(async () => root.render(<RenderErrorBoundary><BrokenShell /></RenderErrorBoundary>));
  expect(host.querySelector("[role=alert]")).not.toBeNull();
  expect(host.querySelector("button")?.textContent).toBe("Recarregar página");
});
