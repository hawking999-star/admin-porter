import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import type { Session, User } from "@supabase/supabase-js";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";

const AUTHORIZED_ADMIN_ROLES = new Set([
  "superadmin",
  "unit_manager",
  "operations_manager",
  "content_manager",
  "challenge_manager",
  "release_manager",
  "auditor",
  "support_readonly",
]);

export type AdminUser = {
  id: string;
  auth_user_id: string;
  display_name: string;
  role: string;
  active: boolean;
  mfa_required: boolean;
};

type AuthState = {
  session: Session | null;
  user: User | null;
  adminUser: AdminUser | null;
  isLoading: boolean;
  loading: boolean;
  isAuthorizedAdmin: boolean;
  authError: string | null;
  permissionError: string | null;
  signOut: () => Promise<void>;
};

const AuthContext = createContext<AuthState>({
  session: null,
  user: null,
  adminUser: null,
  isLoading: true,
  loading: true,
  isAuthorizedAdmin: false,
  authError: null,
  permissionError: null,
  signOut: async () => {},
});

async function fetchAdminUser(session: Session | null): Promise<{
  adminUser: AdminUser | null;
  permissionError: string | null;
}> {
  if (!session) return { adminUser: null, permissionError: null };

  // O acesso ao admin depende SÓ de estar em "Acessos ao painel" (admin_users)
  // com um papel ativo. Ser operador do app não bloqueia mais o admin: o mesmo
  // login pode ter os dois selos (app + painel).
  const { data, error } = await supabase
    .from("admin_users")
    .select("id, auth_user_id, display_name, role, active, mfa_required")
    .eq("auth_user_id", session.user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !data) {
    return {
      adminUser: null,
      permissionError: "Você não tem permissão para acessar o PTM ADMIN.",
    };
  }

  const adminUser = data as AdminUser;
  if (!AUTHORIZED_ADMIN_ROLES.has(adminUser.role)) {
    return {
      adminUser: null,
      permissionError: "Entre com uma conta administrativa ativa.",
    };
  }

  return { adminUser, permissionError: null };
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const [session, setSession] = useState<Session | null>(null);
  const [adminUser, setAdminUser] = useState<AdminUser | null>(null);
  const [loading, setLoading] = useState(true);
  const [authError, setAuthError] = useState<string | null>(null);
  const [permissionError, setPermissionError] = useState<string | null>(null);
  const loadIdRef = useRef(0);
  const loadedUserIdRef = useRef<string | null>(null);

  useEffect(() => {
    let mounted = true;
    let requestedUserId: string | null = null;
    const timers = new Set<ReturnType<typeof setTimeout>>();

    async function loadSession(nextSession: Session | null, loadId: number) {
      try {
        const result = await fetchAdminUser(nextSession);
        if (!mounted || loadId !== loadIdRef.current) return;

        loadedUserIdRef.current = nextSession?.user?.id ?? null;
        setSession(nextSession);
        setAdminUser(result.adminUser);
        setPermissionError(result.permissionError);
      } catch (err) {
        if (!mounted || loadId !== loadIdRef.current) return;

        loadedUserIdRef.current = nextSession?.user?.id ?? null;
        setSession(nextSession);
        setAdminUser(null);
        setPermissionError("Você não tem permissão para acessar o PTM ADMIN.");
        setAuthError(err instanceof Error ? err.message : "Falha ao validar o acesso administrativo.");
      } finally {
        if (mounted && loadId === loadIdRef.current) setLoading(false);
      }
    }

    function acceptSession(next: Session | null) {
      if (!mounted) return;
      const nextUserId = next?.user?.id ?? null;
      // Mesmo usuário (token renovado ou volta para a aba): atualiza a sessão
      // em silêncio, sem voltar para a tela de "Carregando" nem refazer as consultas.
      if (nextUserId && nextUserId === requestedUserId && nextUserId === loadedUserIdRef.current) {
        setSession(next);
        return;
      }

      // Bloqueia a tela e invalida respostas antigas antes de adiar a consulta
      // ao perfil (consultas Supabase não devem rodar dentro do callback de auth).
      const loadId = ++loadIdRef.current;
      setLoading(true);
      setAuthError(null);
      setAdminUser(null);
      setSession(null);
      loadedUserIdRef.current = null;
      if (nextUserId !== requestedUserId || nextUserId === null) {
        void queryClient.cancelQueries();
        queryClient.clear();
      }
      requestedUserId = nextUserId;
      const timer = setTimeout(() => {
        timers.delete(timer);
        if (mounted && loadId === loadIdRef.current) void loadSession(next, loadId);
      }, 0);
      timers.add(timer);
    }

    const initialLoadId = loadIdRef.current;
    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      acceptSession(next);
    });
    // Uma leitura inicial atrasada não pode desfazer um login/logout mais recente.
    void supabase.auth.getSession().then(({ data, error }) => {
      if (!mounted || loadIdRef.current !== initialLoadId) return;
      if (error) throw error;
      acceptSession(data.session);
    }).catch((error: unknown) => {
      if (!mounted || loadIdRef.current !== initialLoadId) return;
      setAuthError(error instanceof Error ? error.message : "Falha ao carregar a sessão.");
      setLoading(false);
    });

    return () => {
      mounted = false;
      ++loadIdRef.current;
      loadedUserIdRef.current = null;
      timers.forEach(clearTimeout);
      sub.subscription.unsubscribe();
    };
  }, [queryClient]);

  const signOut = async () => {
    try {
      const { error } = await supabase.auth.signOut();
      if (error) throw error;
    } catch (error) {
      const message = error instanceof Error ? error.message : "Não foi possível sair. Tente novamente.";
      setAuthError(message);
      toast.error(message);
    }
  };

  const isAuthorizedAdmin = Boolean(session && adminUser && !permissionError);

  return (
    <AuthContext.Provider
      value={{
        session,
        user: session?.user ?? null,
        adminUser,
        isLoading: loading,
        loading,
        isAuthorizedAdmin,
        authError,
        permissionError,
        signOut,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  return useContext(AuthContext);
}
