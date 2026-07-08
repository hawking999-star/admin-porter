import { NavLink, Outlet } from "react-router-dom";
import { navGroups } from "@/lib/navigation";
import { APP_ENVIRONMENT, APP_VERSION } from "@/lib/appInfo";
import { useAuth } from "@/features/auth/AuthProvider";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { LogOut } from "lucide-react";

export function AppShell() {
  const { session, signOut } = useAuth();

  return (
    <div className="flex min-h-screen bg-background text-foreground">
      <aside className="sticky top-0 hidden h-screen w-64 shrink-0 flex-col overflow-x-hidden border-r border-sidebar-border bg-sidebar text-sidebar-foreground md:flex">
        <div className="flex items-center gap-2 px-5 py-5">
          <div className="flex h-9 w-9 items-center justify-center rounded-md bg-primary font-display text-sm font-bold text-primary-foreground">
            PTM
          </div>
          <div className="leading-tight">
            <div className="font-display text-sm font-semibold">PTM</div>
            <div className="text-[10px] font-medium tracking-widest text-sidebar-accent-foreground">ADMIN</div>
          </div>
        </div>

        <nav className="flex-1 space-y-6 overflow-y-auto px-3 py-2">
          {navGroups.map((group) => (
            <div key={group.label}>
              <div className="px-2.5 pb-1.5 text-[10px] font-semibold uppercase tracking-widest text-sidebar-foreground/50">
                {group.label}
              </div>
              <div className="space-y-0.5">
                {group.items.map((item) => (
                  <NavLink
                    key={item.to}
                    to={item.to}
                    end={item.to === "/"}
                    className={({ isActive }) =>
                      cn(
                        "relative flex items-center gap-3 rounded-md px-2.5 py-2 text-sm transition-colors",
                        isActive
                          ? "bg-sidebar-accent font-medium text-sidebar-accent-foreground"
                          : "text-sidebar-foreground/70 hover:bg-sidebar-accent/60 hover:text-sidebar-foreground",
                      )
                    }
                  >
                    {({ isActive }) => (
                      <>
                        {isActive && (
                          <span className="absolute left-0 top-1/2 h-4 w-0.5 -translate-y-1/2 rounded-r-full bg-success" />
                        )}
                        <item.icon className="h-4 w-4 shrink-0" />
                        <span className="truncate">{item.label}</span>
                        {!item.ready && (
                          <span className="ml-auto shrink-0 text-[9px] font-medium uppercase tracking-widest text-sidebar-foreground/35">
                            Em breve
                          </span>
                        )}
                      </>
                    )}
                  </NavLink>
                ))}
              </div>
            </div>
          ))}
        </nav>

        <div className="shrink-0 border-t border-sidebar-border px-4 pb-4 pt-3">
          <dl className="space-y-2 text-[11px]">
            <div className="flex items-center justify-between gap-2">
              <dt className="text-sidebar-foreground/50">Ambiente</dt>
              <dd className="flex items-center gap-1.5 font-medium text-sidebar-foreground/90">
                <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-success" />
                {APP_ENVIRONMENT}
              </dd>
            </div>
            <div className="flex items-center justify-between gap-2">
              <dt className="text-sidebar-foreground/50">Versão</dt>
              <dd className="font-medium tabular-nums text-sidebar-foreground/90">v{APP_VERSION}</dd>
            </div>
          </dl>
          <div className="mt-3 flex items-center gap-1.5 rounded-md border border-sidebar-border bg-sidebar-accent/40 py-1.5 pl-2.5 pr-1.5">
            <span
              className="min-w-0 flex-1 truncate text-xs text-sidebar-foreground/80"
              title={session?.user.email ?? undefined}
            >
              {session?.user.email}
            </span>
            <Button
              variant="ghost"
              size="icon"
              onClick={signOut}
              title="Sair"
              aria-label="Sair"
              className="h-7 w-7 shrink-0 text-sidebar-foreground/60 hover:bg-sidebar-accent hover:text-sidebar-foreground"
            >
              <LogOut className="h-3.5 w-3.5" />
            </Button>
          </div>
        </div>
      </aside>

      <main className="min-w-0 flex-1 overflow-y-auto">
        <div className="border-b border-border bg-background px-4 py-3 md:hidden">
          <div className="mb-3 flex items-center justify-between gap-3">
            <div className="flex items-center gap-2">
              <div className="flex h-9 w-9 items-center justify-center rounded-md bg-primary font-display text-sm font-bold text-primary-foreground">
                PTM
              </div>
              <div className="leading-tight">
                <div className="font-display text-sm font-semibold">PTM Admin</div>
                <div className="text-[10px] font-medium uppercase tracking-widest text-muted-foreground">
                  {APP_ENVIRONMENT} · v{APP_VERSION}
                </div>
              </div>
            </div>
            <Button variant="ghost" size="icon" onClick={signOut} title="Sair">
              <LogOut className="h-4 w-4" />
            </Button>
          </div>
          <nav className="-mx-1 flex gap-1 overflow-x-auto px-1 pb-1">
            {navGroups.flatMap((group) =>
              group.items.map((item) => (
                <NavLink
                  key={item.to}
                  to={item.to}
                  end={item.to === "/"}
                  className={({ isActive }) =>
                    cn(
                      "flex shrink-0 items-center gap-1.5 rounded-md px-2.5 py-2 text-xs transition-colors",
                      isActive
                        ? "bg-primary text-primary-foreground"
                        : "bg-muted text-muted-foreground hover:text-foreground",
                    )
                  }
                >
                  <item.icon className="h-3.5 w-3.5" />
                  <span>{item.label}</span>
                </NavLink>
              )),
            )}
          </nav>
        </div>

        <div className="mx-auto max-w-[1240px] px-4 py-6 sm:px-6 md:py-8 lg:px-8">
          <Outlet />
        </div>
      </main>
    </div>
  );
}
