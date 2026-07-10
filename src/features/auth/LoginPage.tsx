import { useState } from "react";
import {
  Activity,
  BarChart3,
  CheckCircle2,
  Eye,
  EyeOff,
  Headphones,
  ListMusic,
  LockKeyhole,
  Mail,
  Music2,
  Play,
  ShieldCheck,
  Users,
  Waves,
} from "lucide-react";
import { supabase } from "@/lib/supabase";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "sonner";

const REMEMBERED_EMAIL_KEY = "ptm-admin:remembered-email";

function BrandMark({ compact = false }: { compact?: boolean }) {
  return (
    <div
      className={`relative flex shrink-0 items-center justify-center rounded-2xl bg-primary text-primary-foreground shadow-[0_12px_30px_color-mix(in_srgb,var(--primary)_28%,transparent)] ${compact ? "h-11 w-11" : "h-16 w-16"}`}
      aria-hidden="true"
    >
      <div className="absolute inset-[5px] rounded-xl border border-primary-foreground/45" />
      <BarChart3 className={compact ? "h-6 w-6" : "h-9 w-9"} strokeWidth={2.4} />
    </div>
  );
}

function FeaturePill({ icon, title, detail }: { icon: React.ReactNode; title: string; detail: string }) {
  return (
    <div className="flex min-w-0 items-center gap-3 px-4 py-3.5">
      <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-primary/18 text-primary">
        {icon}
      </div>
      <div className="min-w-0">
        <p className="truncate text-sm font-semibold text-sidebar-foreground">{title}</p>
        <p className="truncate text-xs text-sidebar-foreground/62">{detail}</p>
      </div>
    </div>
  );
}

function OperationCard({
  icon,
  title,
  detail,
  tone,
  path,
}: {
  icon: React.ReactNode;
  title: string;
  detail: string;
  tone: string;
  path: string;
}) {
  return (
    <div className="min-w-0 px-5 py-3 first:pl-0 last:pr-0 lg:border-r lg:border-sidebar-foreground/12 lg:last:border-r-0">
      <div className="flex items-center gap-3">
        <div className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-full ${tone}`}>{icon}</div>
        <div className="min-w-0">
          <p className="truncate text-base font-semibold text-sidebar-foreground">{title}</p>
          <p className="truncate text-xs text-sidebar-foreground/60">{detail}</p>
        </div>
      </div>
      <svg viewBox="0 0 180 30" className="mt-4 h-7 w-full" aria-hidden="true">
        <path d={path} fill="none" stroke="currentColor" strokeWidth="2" className="text-primary" />
      </svg>
    </div>
  );
}

export function LoginPage() {
  const rememberedEmail = localStorage.getItem(REMEMBERED_EMAIL_KEY) ?? "";
  const [email, setEmail] = useState(rememberedEmail);
  const [password, setPassword] = useState("");
  const [rememberAccess, setRememberAccess] = useState(Boolean(rememberedEmail));
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);

  const onSubmit = async (event: React.FormEvent) => {
    event.preventDefault();
    setLoading(true);
    const cleanEmail = email.trim();
    const { error } = await supabase.auth.signInWithPassword({ email: cleanEmail, password });
    setLoading(false);

    if (error) {
      toast.error("Não foi possível entrar", { description: error.message });
      return;
    }

    if (rememberAccess) localStorage.setItem(REMEMBERED_EMAIL_KEY, cleanEmail);
    else localStorage.removeItem(REMEMBERED_EMAIL_KEY);
  };

  return (
    <main className="grid min-h-svh bg-background lg:grid-cols-2">
      <section className="relative hidden min-h-svh overflow-hidden bg-sidebar px-10 py-10 text-sidebar-foreground lg:flex xl:px-16 xl:py-14">
        <div className="absolute -bottom-40 -right-32 h-[560px] w-[560px] rounded-full bg-primary/25 blur-3xl" />
        <div className="absolute -left-36 -top-44 h-96 w-96 rounded-full bg-secondary/55 blur-3xl" />
        <svg className="absolute right-0 top-8 h-[46%] w-[62%] text-primary opacity-15" viewBox="0 0 600 360" aria-hidden="true">
          {Array.from({ length: 11 }).map((_, index) => (
            <path
              key={index}
              d={`M0 ${52 + index * 20} C150 ${20 + index * 22}, 300 ${110 + index * 12}, 600 ${40 + index * 22}`}
              fill="none"
              stroke="currentColor"
              strokeWidth="1"
            />
          ))}
          {Array.from({ length: 12 }).map((_, index) => (
            <rect key={`bar-${index}`} x={390 + index * 16} y={210 - index * 7} width="8" height={28 + index * 8} rx="2" fill="currentColor" />
          ))}
        </svg>

        <div className="relative z-10 mx-auto flex w-full max-w-3xl flex-col justify-between">
          <div>
            <div className="inline-flex items-center gap-2 rounded-full border border-sidebar-foreground/12 bg-sidebar-foreground/5 px-4 py-2 text-xs font-medium tracking-wide text-sidebar-foreground/70">
              <ShieldCheck className="h-4 w-4 text-primary" />
              PLATAFORMA DE GESTÃO PORTER MUSIC
            </div>

            <div className="mt-14 max-w-xl">
              <h1 className="font-display text-5xl font-semibold leading-[1.08] tracking-tight xl:text-6xl">
                Música. Operação.
                <span className="mt-1 block text-primary">Controle.</span>
              </h1>
              <p className="mt-6 max-w-lg text-lg leading-8 text-sidebar-foreground/72">
                Gerencie playlists, aprovações de músicas, Operadores e rotinas do Porter Music em um só painel, com visibilidade e segurança operacional.
              </p>
            </div>

            <div className="relative mt-10 flex h-28 max-w-xl items-center justify-center xl:mt-12">
              <div className="absolute inset-0 rounded-full bg-primary/10 blur-3xl" />
              <div className="relative flex h-20 w-20 items-center justify-center rounded-full border border-primary/35 bg-primary/10 text-primary shadow-[0_0_60px_color-mix(in_srgb,var(--primary)_24%,transparent)]">
                <Play className="ml-1 h-8 w-8 fill-current" />
              </div>
              <Waves className="absolute left-12 h-12 w-12 text-primary/25" />
              <Activity className="absolute right-12 h-12 w-12 text-primary/25" />
            </div>

            <div className="mt-7 grid max-w-2xl divide-y divide-sidebar-foreground/10 rounded-2xl border border-sidebar-foreground/12 bg-sidebar-foreground/[0.045] backdrop-blur-sm sm:grid-cols-3 sm:divide-x sm:divide-y-0">
              <FeaturePill icon={<Headphones className="h-5 w-5" />} title="Operação musical" detail="Gestão centralizada" />
              <FeaturePill icon={<Music2 className="h-5 w-5" />} title="Playlists" detail="Fluxo acompanhado" />
              <FeaturePill icon={<ShieldCheck className="h-5 w-5" />} title="Segurança" detail="Acesso monitorado" />
            </div>

            <div className="mt-7 max-w-2xl rounded-2xl border border-sidebar-foreground/12 bg-sidebar-foreground/[0.045] p-5 backdrop-blur-sm">
              <p className="text-xs font-medium uppercase tracking-wide text-sidebar-foreground/65">Visão da operação</p>
              <div className="mt-4 grid border-t border-sidebar-foreground/10 pt-3 lg:grid-cols-3">
                <OperationCard
                  icon={<ListMusic className="h-5 w-5" />}
                  title="Playlists"
                  detail="Organização contínua"
                  tone="bg-primary/12 text-primary"
                  path="M0 25 L14 22 L28 23 L42 18 L56 20 L70 13 L84 17 L98 9 L112 21 L126 16 L140 19 L154 10 L168 12 L180 5"
                />
                <OperationCard
                  icon={<CheckCircle2 className="h-5 w-5" />}
                  title="Aprovações"
                  detail="Processo auditável"
                  tone="bg-secondary/45 text-sidebar-foreground"
                  path="M0 23 L16 20 L32 21 L48 16 L64 18 L80 11 L96 15 L112 6 L128 20 L144 17 L160 12 L180 4"
                />
                <OperationCard
                  icon={<Users className="h-5 w-5" />}
                  title="Operadores"
                  detail="Visibilidade central"
                  tone="bg-success/18 text-success"
                  path="M0 24 L18 20 L36 21 L54 16 L72 18 L90 10 L108 15 L126 6 L144 17 L162 9 L180 12"
                />
              </div>
            </div>
          </div>

          <div className="mt-8 flex items-center gap-3 text-xs text-sidebar-foreground/58">
            <LockKeyhole className="h-4 w-4" />
            Gestão segura de playlists, músicas e dados operacionais do Porter Music.
          </div>
        </div>
      </section>

      <section className="relative flex min-h-svh items-center justify-center overflow-hidden px-4 py-8 sm:px-8">
        <div className="absolute -right-20 -top-20 h-72 w-72 rounded-full bg-primary/8 blur-3xl" />
        <div className="absolute -bottom-28 -left-20 h-80 w-80 rounded-full bg-secondary/8 blur-3xl" />
        <svg className="absolute bottom-0 left-0 h-60 w-full text-primary opacity-[0.045]" viewBox="0 0 800 220" preserveAspectRatio="none" aria-hidden="true">
          {Array.from({ length: 12 }).map((_, index) => (
            <path key={index} d={`M0 ${90 + index * 10} C180 ${10 + index * 13}, 430 ${190 - index * 4}, 800 ${45 + index * 11}`} fill="none" stroke="currentColor" />
          ))}
        </svg>

        <div className="relative z-10 w-full max-w-xl rounded-3xl border border-border/70 bg-card/95 p-7 shadow-2xl backdrop-blur sm:p-10 xl:p-14">
          <div className="flex items-center gap-4">
            <BrandMark />
            <div>
              <h2 className="font-display text-2xl font-semibold text-foreground sm:text-3xl">PTM Admin</h2>
              <p className="mt-1 text-sm text-muted-foreground">Acesso administrativo</p>
            </div>
          </div>

          <form onSubmit={onSubmit} className="mt-10 space-y-5">
            <div className="space-y-2">
              <Label htmlFor="email">E-mail</Label>
              <div className="relative">
                <Mail className="pointer-events-none absolute left-3.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                <Input
                  id="email"
                  type="email"
                  autoComplete="email"
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  placeholder="Digite seu e-mail"
                  className="h-11 pl-10"
                  required
                />
              </div>
            </div>

            <div className="space-y-2">
              <Label htmlFor="password">Senha</Label>
              <div className="relative">
                <LockKeyhole className="pointer-events-none absolute left-3.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                <Input
                  id="password"
                  type={showPassword ? "text" : "password"}
                  autoComplete="current-password"
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                  placeholder="Digite sua senha"
                  className="h-11 px-10"
                  required
                />
                <button
                  type="button"
                  onClick={() => setShowPassword((visible) => !visible)}
                  className="absolute right-3 top-1/2 -translate-y-1/2 rounded-md p-1 text-muted-foreground transition-colors hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                  aria-label={showPassword ? "Ocultar senha" : "Mostrar senha"}
                >
                  {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                </button>
              </div>
            </div>

            <label className="flex w-fit cursor-pointer items-center gap-2.5 text-xs text-muted-foreground">
              <input
                type="checkbox"
                checked={rememberAccess}
                onChange={(event) => setRememberAccess(event.target.checked)}
                className="h-4 w-4 rounded border-input accent-primary"
              />
              Lembrar meu e-mail
            </label>

            <Button type="submit" className="h-11 w-full gap-2 text-sm font-semibold shadow-lg shadow-primary/20" disabled={loading}>
              <LockKeyhole className="h-4 w-4" />
              {loading ? "Entrando..." : "Entrar"}
            </Button>
          </form>

          <div className="my-7 flex items-center gap-4 text-[11px] text-muted-foreground">
            <span className="h-px flex-1 bg-border" />
            Acesso seguro e monitorado
            <span className="h-px flex-1 bg-border" />
          </div>

          <div className="flex items-center gap-3 rounded-xl border border-border bg-muted/35 px-4 py-3.5">
            <ShieldCheck className="h-6 w-6 shrink-0 text-primary" />
            <div>
              <p className="text-xs font-semibold text-foreground">Acesso seguro</p>
              <p className="mt-0.5 text-[11px] text-muted-foreground">Sessão protegida e acesso administrativo controlado</p>
            </div>
          </div>

          <div className="mt-7 flex items-center justify-center gap-3 text-xs text-muted-foreground lg:hidden">
            <BrandMark compact />
            Plataforma de gestão Porter Music
          </div>
        </div>
      </section>
    </main>
  );
}
