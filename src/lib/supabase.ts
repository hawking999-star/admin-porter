import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

if (!url || !anonKey) {
  throw new Error(
    "Faltam VITE_SUPABASE_URL ou VITE_SUPABASE_ANON_KEY. Copie .env.example para .env e preencha.",
  );
}

function assertPublicClientKey(key: string) {
  if (key.startsWith("sb_secret_")) {
    throw new Error("VITE_SUPABASE_ANON_KEY não pode receber uma secret key.");
  }
  const payload = key.split(".")[1];
  if (!payload) return;
  try {
    const normalized = payload.replace(/-/g, "+").replace(/_/g, "/");
    const decoded = JSON.parse(atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")));
    if (decoded?.role === "service_role") {
      throw new Error("A service_role não pode ser usada no frontend.");
    }
  } catch (error) {
    if (error instanceof Error && error.message.includes("service_role")) throw error;
    // Chaves publishable modernas não são JWT e são aceitas.
  }
}

assertPublicClientKey(anonKey);

export const supabase = createClient(url, anonKey, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    storageKey: "ptm.admin.auth",
  },
});
