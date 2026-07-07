import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import type { Session, User } from "@supabase/supabase-js";
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

type OperatorUser = {
  id: string;
  role: string | null;
  active: boolean;
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

  const { data: operator, error: operatorError } = await supabase
    .from("operators")
    .select("id, role, active")
    .eq("auth_user_id", session.user.id)
    .eq("active", true)
    .maybeSingle();

  if (operatorError || operator) {
    return {
      adminUser: null,
      permissionError: "Entre com uma conta administrativa ativa.",
    };
  }

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
  const [session, setSession] = useState<Session | null>(null);
  const [adminUser, setAdminUser] = useState<AdminUser | null>(null);
  const [loading, setLoading] = useState(true);
  const [authError, setAuthError] = useState<string | null>(null);
  const [permissionError, setPermissionError] = useState<string | null>(null);
  const loadIdRef = useRef(0);

  useEffect(() => {
    let mounted = true;

    async function loadSession(nextSession: Session | null) {
      const loadId = ++loadIdRef.current;
      setLoading(true);
      setAuthError(null);
      setAdminUser(null);

      try {
        const result = await fetchAdminUser(nextSession);
        if (!mounted || loadId !== loadIdRef.current) return;

        setSession(nextSession);
        setAdminUser(result.adminUser);
        setPermissionError(result.permissionError);
      } catch (err) {
        if (!mounted || loadId !== loadIdRef.current) return;

        setSession(nextSession);
        setAdminUser(null);
        setPermissionError("Você não tem permissão para acessar o PTM ADMIN.");
        setAuthError(err instanceof Error ? err.message : "Falha ao validar o acesso administrativo.");
      } finally {
        if (mounted && loadId === loadIdRef.current) setLoading(false);
      }
    }

    supabase.auth.getSession().then(({ data, error }) => {
      if (error) {
        setAuthError(error.message);
        setLoading(false);
        return;
      }
      void loadSession(data.session);
    });

    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setTimeout(() => void loadSession(next), 0);
    });

    return () => {
      mounted = false;
      sub.subscription.unsubscribe();
    };
  }, []);

  const signOut = async () => {
    await supabase.auth.signOut();
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
