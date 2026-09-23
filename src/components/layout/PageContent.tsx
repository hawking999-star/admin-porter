import { Suspense } from "react";
import { Outlet, useLocation } from "react-router-dom";
import { RenderErrorBoundary } from "@/components/shared/RenderErrorBoundary";

function PageLoading() {
  return (
    <div className="space-y-5" aria-label="Carregando página" aria-busy="true">
      <div className="space-y-2 border-b border-border pb-5">
        <div className="h-3 w-28 animate-pulse rounded bg-muted" />
        <div className="h-8 w-56 animate-pulse rounded-md bg-muted" />
        <div className="h-4 w-full max-w-xl animate-pulse rounded bg-muted" />
      </div>
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        {Array.from({ length: 4 }).map((_, index) => (
          <div key={index} className="h-[88px] animate-pulse rounded-xl border border-border bg-card" />
        ))}
      </div>
      <div className="h-72 animate-pulse rounded-xl border border-border bg-card" />
    </div>
  );
}

export function PageContent() {
  const { pathname } = useLocation();
  return (
    <RenderErrorBoundary key={pathname}>
      <Suspense fallback={<PageLoading />}>
        <Outlet />
      </Suspense>
    </RenderErrorBoundary>
  );
}
