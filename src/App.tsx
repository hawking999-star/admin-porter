import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Toaster } from "@/components/ui/sonner";
import { AuthProvider, useAuth } from "@/features/auth/AuthProvider";
import { LoginPage } from "@/features/auth/LoginPage";
import { AppShell } from "@/components/layout/AppShell";
import { CondominiosPage } from "@/features/condominios/CondominiosPage";
import { UsuariosPage } from "@/features/usuarios/UsuariosPage";
import { FeedbackPage } from "@/features/feedback/FeedbackPage";
import { MusicasPage } from "@/features/musicas/MusicasPage";
import { OverviewPage } from "@/features/overview/OverviewPage";
import { ComingSoon } from "@/features/common/ComingSoon";

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: false } },
});

function Protected({ children }: { children: React.ReactNode }) {
  const { session, loading } = useAuth();
  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center text-sm text-muted-foreground">
        Carregando...
      </div>
    );
  }
  if (!session) return <LoginPage />;
  return <>{children}</>;
}

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter>
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
              <Route path="/challenges" element={<ComingSoon title="Challenges" />} />
              <Route path="/musicas" element={<MusicasPage />} />
              <Route path="/feedback" element={<FeedbackPage />} />
              <Route path="/analytics" element={<ComingSoon title="Analytics" />} />
              <Route path="/logs" element={<ComingSoon title="Logs" />} />
              <Route path="/auditoria" element={<ComingSoon title="Auditoria" />} />
              <Route path="/atualizacoes" element={<ComingSoon title="Atualizações" />} />
              <Route path="/integracao" element={<ComingSoon title="Integração" />} />
              <Route path="*" element={<Navigate to="/" replace />} />
            </Route>
          </Routes>
        </BrowserRouter>
        <Toaster richColors position="top-right" />
      </AuthProvider>
    </QueryClientProvider>
  );
}
