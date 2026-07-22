import { lazy, Suspense } from "react";
import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Toaster } from "@/components/ui/sonner";
import { AuthProvider, useAuth } from "@/features/auth/AuthProvider";
import { LoginPage } from "@/features/auth/LoginPage";
import { AppShell } from "@/components/layout/AppShell";

const OverviewPage = lazy(() => import("@/features/overview/OverviewPage").then((module) => ({ default: module.OverviewPage })));
const CondominiosPage = lazy(() => import("@/features/condominios/CondominiosPage").then((module) => ({ default: module.CondominiosPage })));
const UsuariosPage = lazy(() => import("@/features/usuarios/UsuariosPage").then((module) => ({ default: module.UsuariosPage })));
const FeedbackPage = lazy(() => import("@/features/feedback/FeedbackPage").then((module) => ({ default: module.FeedbackPage })));
const MusicasPage = lazy(() => import("@/features/musicas/MusicasPage").then((module) => ({ default: module.MusicasPage })));
const LogsPage = lazy(() => import("@/features/logs/LogsPage").then((module) => ({ default: module.LogsPage })));
const AtualizacoesPage = lazy(() => import("@/features/atualizacoes/AtualizacoesPage").then((module) => ({ default: module.AtualizacoesPage })));
const AnalyticsPage = lazy(() => import("@/features/analytics/AnalyticsPage").then((module) => ({ default: module.AnalyticsPage })));
const ChallengesPage = lazy(() => import("@/features/challenges/ChallengesPage").then((module) => ({ default: module.ChallengesPage })));
const IntegracaoPage = lazy(() => import("@/features/integracao/IntegracaoPage").then((module) => ({ default: module.IntegracaoPage })));
const AuditoriaPage = lazy(() => import("@/features/auditoria/AuditoriaPage").then((module) => ({ default: module.AuditoriaPage })));

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: false } },
});

function AccessDenied() {
  const { signOut, authError, permissionError } = useAuth();

  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="w-full max-w-md rounded-lg border border-border bg-card p-6 text-center shadow-sm">
        <h1 className="font-display text-xl font-semibold text-foreground">Acesso negado</h1>
        <p className="mt-3 text-sm text-muted-foreground">
          {permissionError ?? "Você não tem permissão para acessar o PTM ADMIN."}
        </p>
        <p className="mt-1 text-sm text-muted-foreground">
          Entre com uma conta administrativa ativa.
        </p>
        {authError && <p className="mt-3 text-xs text-destructive">{authError}</p>}
        <button
          type="button"
          className="mt-5 inline-flex h-9 items-center justify-center rounded-md border border-border px-4 text-sm font-medium text-foreground transition-colors hover:bg-muted"
          onClick={() => void signOut()}
        >
          Sair
        </button>
      </div>
    </div>
  );
}

function Protected({ children }: { children: React.ReactNode }) {
  const { session, isLoading, isAuthorizedAdmin } = useAuth();
  if (isLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center text-sm text-muted-foreground">
        Carregando...
      </div>
    );
  }
  if (!session) return <LoginPage />;
  if (!isAuthorizedAdmin) return <AccessDenied />;
  return <>{children}</>;
}

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

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter>
          <Suspense fallback={<PageLoading />}>
          <Routes>
            <Route
              element={
                <Protected>
                  <AppShell />
                </Protected>
              }
            >
              <Route path="/" element={<OverviewPage />} />
              <Route path="/condominios" element={<CondominiosPage />} />
              <Route path="/usuarios" element={<UsuariosPage />} />
              <Route path="/challenges" element={<ChallengesPage />} />
              <Route path="/musicas" element={<MusicasPage />} />
              <Route path="/feedback" element={<FeedbackPage />} />
              <Route path="/analytics" element={<AnalyticsPage />} />
              <Route path="/logs" element={<LogsPage />} />
              <Route path="/auditoria" element={<AuditoriaPage />} />
              <Route path="/atualizacoes" element={<AtualizacoesPage />} />
              <Route path="/integracao" element={<IntegracaoPage />} />
              <Route path="*" element={<Navigate to="/" replace />} />
            </Route>
          </Routes>
          </Suspense>
        </BrowserRouter>
        <Toaster richColors position="top-right" />
      </AuthProvider>
    </QueryClientProvider>
  );
}
