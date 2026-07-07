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
import { LogsPage } from "@/features/logs/LogsPage";
import { AtualizacoesPage } from "@/features/atualizacoes/AtualizacoesPage";
import { ComingSoonPage } from "@/components/shared";
import { BarChart3, Puzzle, ClipboardList, Code2 } from "lucide-react";

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
              <Route
                path="/challenges"
                element={
                  <ComingSoonPage
                    title="Challenges"
                    description="Desafios e regras de engajamento para os operadores."
                    icon={Puzzle}
                    planned={[
                      "Criação de desafios e regras",
                      "Metas por operador e por condomínio",
                      "Acompanhamento do progresso",
                      "Recompensas e reconhecimento",
                      "Histórico de desafios encerrados",
                    ]}
                  />
                }
              />
              <Route path="/musicas" element={<MusicasPage />} />
              <Route path="/feedback" element={<FeedbackPage />} />
              <Route
                path="/analytics"
                element={
                  <ComingSoonPage
                    title="Analytics"
                    description="Indicadores avançados da operação, presença e engajamento dos operadores."
                    icon={BarChart3}
                    planned={[
                      "Métricas por condomínio",
                      "Evolução das sessões ao longo do tempo",
                      "Tempo ocioso e em atendimento",
                      "Ranking operacional dos operadores",
                      "Exportação de relatórios",
                    ]}
                  />
                }
              />
              <Route path="/logs" element={<LogsPage />} />
              <Route
                path="/auditoria"
                element={
                  <ComingSoonPage
                    title="Auditoria"
                    description="Registro detalhado das ações administrativas feitas no painel."
                    icon={ClipboardList}
                    planned={[
                      "Histórico de alterações no painel",
                      "Autor e data de cada ação",
                      "Filtros por período e por área",
                      "Exportação da trilha de auditoria",
                    ]}
                  />
                }
              />
              <Route
                path="/atualizacoes"
                element={<AtualizacoesPage />}
              />
              <Route
                path="/integracao"
                element={
                  <ComingSoonPage
                    title="Integração"
                    description="Diagnóstico técnico e status das integrações da operação."
                    icon={Code2}
                    planned={[
                      "Status do worker de importação",
                      "Conexão com o Supabase",
                      "Filas de processamento de músicas",
                      "Verificação de credenciais e ambiente",
                    ]}
                  />
                }
              />
              <Route path="*" element={<Navigate to="/" replace />} />
            </Route>
          </Routes>
        </BrowserRouter>
        <Toaster richColors position="top-right" />
      </AuthProvider>
    </QueryClientProvider>
  );
}
