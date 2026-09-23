import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AuthProvider, useAuth } from "@/features/auth/AuthProvider";

const mock = vi.hoisted(() => ({
  listener: null as null | ((event: string, session: any) => void),
  getSession: vi.fn(),
  profile: vi.fn(),
  signOut: vi.fn(),
  toast: vi.fn(),
}));
vi.mock("sonner", () => ({ toast: { error: mock.toast } }));
vi.mock("@/lib/supabase", () => ({ supabase: {
  auth: {
    getSession: mock.getSession,
    signOut: mock.signOut,
    onAuthStateChange: (listener: typeof mock.listener) => {
      mock.listener = listener;
      return { data: { subscription: { unsubscribe: () => { mock.listener = null; } } } };
    },
  },
  from: () => {
    let userId: string;
    const query = {
      select: () => query,
      eq: (key: string, value: string) => { if (key === "auth_user_id") userId = value; return query; },
      maybeSingle: () => mock.profile(userId),
    };
    return query;
  },
} }));

function session(id: string, token = "initial") { return { user: { id }, access_token: token }; }
function profile(id: string) {
  return { data: { id, auth_user_id: id, display_name: id, role: "superadmin", active: true }, error: null };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

let root: Root;
let host: HTMLDivElement;
let client: QueryClient;
let auth: ReturnType<typeof useAuth>;
function Probe() {
  auth = useAuth();
  return <div>{auth.isLoading ? "loading" : auth.adminUser?.display_name ?? "signed-out"}</div>;
}
async function settle() {
  await act(async () => { await new Promise((resolve) => setTimeout(resolve, 5)); });
}
async function mount() {
  await act(async () => {
    root.render(<QueryClientProvider client={client}><AuthProvider><Probe /></AuthProvider></QueryClientProvider>);
  });
  await settle();
}
async function emit(id: string | null, event = "SIGNED_IN") {
  await act(async () => { mock.listener!(event, id ? session(id, event) : null); });
  await settle();
}

beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  mock.getSession.mockReset().mockResolvedValue({ data: { session: session("A") }, error: null });
  mock.profile.mockReset().mockImplementation(async (id: string) => profile(id));
  mock.signOut.mockReset().mockImplementation(async () => {
    mock.listener!("SIGNED_OUT", null);
    return { error: null };
  });
  mock.toast.mockClear();
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
});
afterEach(async () => {
  await act(async () => root.unmount());
  client.clear();
  host.remove();
  vi.unstubAllGlobals();
});

describe("isolamento de sessão", () => {
  it("limpa consultas e mutações ao sair", async () => {
    await mount();
    client.setQueryData(["private"], "A");
    client.getMutationCache().build(client, { mutationKey: ["private"] });
    await act(async () => { await auth.signOut(); });
    await settle();
    expect(host.textContent).toBe("signed-out");
    expect(client.getQueryCache().getAll()).toHaveLength(0);
    expect(client.getMutationCache().getAll()).toHaveLength(0);
  });

  it("remove o cache antes de validar outra conta e ignora consulta antiga concluída depois", async () => {
    await mount();
    client.setQueryData(["private"], "A");
    const late = deferred<string>();
    const oldQuery = client.fetchQuery({ queryKey: ["in-flight"], queryFn: () => late.promise }).catch(() => undefined);
    const nextProfile = deferred<ReturnType<typeof profile>>();
    mock.profile.mockReturnValueOnce(nextProfile.promise);
    await emit("B");
    expect(host.textContent).toBe("loading");
    expect(client.getQueryCache().getAll()).toHaveLength(0);
    await act(async () => { nextProfile.resolve(profile("B")); });
    expect(host.textContent).toBe("B");
    client.setQueryData(["in-flight"], "B");
    late.resolve("A");
    await oldQuery;
    expect(client.getQueryData(["in-flight"])).toBe("B");
    expect(client.getQueryData(["private"])).toBeUndefined();
  });

  it("preserva cache e perfil na renovação do token do mesmo usuário", async () => {
    await mount();
    client.setQueryData(["private"], "A");
    const calls = mock.profile.mock.calls.length;
    await emit("A", "TOKEN_REFRESHED");
    expect(host.textContent).toBe("A");
    expect(client.getQueryData(["private"])).toBe("A");
    expect(mock.profile).toHaveBeenCalledTimes(calls);
    expect(auth.session?.access_token).toBe("TOKEN_REFRESHED");
  });

  it("não restaura perfil pendente após logout", async () => {
    await mount();
    const lateProfile = deferred<ReturnType<typeof profile>>();
    mock.profile.mockReturnValueOnce(lateProfile.promise);
    await emit("B");
    await emit(null, "SIGNED_OUT");
    await act(async () => { lateProfile.resolve(profile("B")); });
    expect(host.textContent).toBe("signed-out");
    expect(auth.session).toBeNull();
  });

  it("ignora getSession inicial atrasado após um login mais recente", async () => {
    const initial = deferred<any>();
    mock.getSession.mockReturnValueOnce(initial.promise);
    await mount();
    await emit("B");
    await act(async () => { initial.resolve({ data: { session: session("A") }, error: null }); });
    expect(host.textContent).toBe("B");
  });

  it("mostra falha de logout sem fingir que a sessão terminou", async () => {
    await mount();
    mock.signOut.mockResolvedValueOnce({ error: new Error("Falha de conexão") });
    await act(async () => { await auth.signOut(); });
    expect(host.textContent).toBe("A");
    expect(mock.toast).toHaveBeenCalledWith("Falha de conexão");
  });
});
