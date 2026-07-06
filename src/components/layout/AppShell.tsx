import { NavLink, Outlet } from "react-router-dom";
import { navGroups } from "@/lib/navigation";
import { useAuth } from "@/features/auth/AuthProvider";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { LogOut } from "lucide-react";

export function AppShell() {
  const { session, signOut } = useAuth();

  return (
    <div className="flex min-h-screen bg-background text-foreground">
      <aside className="flex w-64 shrink-0 flex-col border-r border-sidebar-border bg-sidebar text-sidebar-foreground">
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
              <div className="px-2 pb-1 text-[10px] font-semibold uppercase tracking-widest text-sidebar-foreground/50">
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
                        "flex items-center gap-3 rounded-md px-2.5 py-2 text-sm transition-colors",
                        isActive
                          ? "bg-sidebar-accent font-medium text-sidebar-accent-foreground"
                          : "text-sidebar-foreground/70 hover:bg-sidebar-accent/60 hover:text-sidebar-foreground",
                      )
                    }
                  >
                    <item.icon className="h-4 w-4 shrink-0" />
                    <span>{item.label}</span>
                    {!item.ready && (
                      <span className="ml-auto text-[9px] uppercase tracking-wide text-sidebar-foreground/40">
                        em breve
                      </span>
                    )}
                  </NavLink>
                ))}
              </div>
            </div>
          ))}
        </nav>

        <div className="border-t border-sidebar-border px-4 py-3">
          <div className="mb-2 flex items-center gap-2 text-[11px] text-sidebar-foreground/60">
            <span className="h-2 w-2 rounded-full bg-success" />
            PRODUÇÃO · V0.1
          </div>
          <div className="flex items-center justify-between gap-2">
            <span className="truncate text-xs text-sidebar-foreground/60">{session?.user.email}</span>
            <Button
              variant="ghost"
              size="icon"
              onClick={signOut}
              title="Sair"
              className="text-sidebar-foreground/70 hover:bg-sidebar-accent/60 hover:text-sidebar-foreground"
            >
              <LogOut className="h-4 w-4" />
            </Button>
          </div>
        </div>
      </aside>

      <main className="flex-1 overflow-y-auto">
        <div className="mx-auto max-w-6xl px-8 py-8">
          <Outlet />
        </div>
      </main>
    </div>
  );
}
