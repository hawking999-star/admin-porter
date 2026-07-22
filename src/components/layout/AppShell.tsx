import { useCallback, useEffect, useMemo, useState } from "react";
import { useIsFetching, useQueryClient } from "@tanstack/react-query";
import { NavLink, Outlet, useLocation } from "react-router-dom";
import { Menu, LogOut, PanelLeftClose, PanelLeftOpen, Search, ShieldCheck } from "lucide-react";
import { navGroups, allNavItems } from "@/lib/navigation";
import { APP_ENVIRONMENT, APP_VERSION } from "@/lib/appInfo";
import { useAuth } from "@/features/auth/AuthProvider";
import { Button } from "@/components/ui/button";
import { Sheet, SheetContent, SheetTitle, SheetTrigger } from "@/components/ui/sheet";
import { cn } from "@/lib/utils";
import { CommandPalette } from "@/components/layout/CommandPalette";
import { SystemHealthPopover } from "@/components/layout/SystemHealthPopover";
import { UpdatedAt } from "@/components/shared/UpdatedAt";

function Brand({ compact = false }: { compact?: boolean }) {
  return (
    <div className={cn("flex min-w-0 items-center", compact ? "justify-center" : "gap-3")}>
      <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-primary font-display text-xs font-bold tracking-tight text-primary-foreground shadow-[0_0_0_1px_rgba(255,255,255,.12)]">
        PTM
      </div>
      {!compact && (
        <div className="min-w-0 leading-tight">
          <div className="truncate font-display text-sm font-semibold text-white">PTM ADMIN</div>
          <div className="mt-0.5 text-[10px] font-semibold uppercase tracking-[0.16em] text-sidebar-foreground/45">
            Central operacional
          </div>
        </div>
      )}
    </div>
  );
}

function SidebarNav({ compact = false, onNavigate }: { compact?: boolean; onNavigate?: () => void }) {
  return (
    <nav className={cn("flex-1 overflow-y-auto py-3", compact ? "px-2" : "px-3")} aria-label="Navegação principal">
      <div className="space-y-5">
        {navGroups.map((group) => (
          <div key={group.label}>
            {!compact && (
              <div className="px-2.5 pb-1.5 text-[10px] font-semibold uppercase tracking-[0.16em] text-sidebar-foreground/35">
                {group.label}
              </div>
            )}
            <div className="space-y-1">
              {group.items.map((item) => (
                <NavLink
                  key={item.to}
                  to={item.to}
                  end={item.to === "/"}
                  onClick={onNavigate}
                  title={compact ? item.label : undefined}
                  className={({ isActive }) =>
                    cn(
                      "group relative flex h-10 items-center rounded-lg text-sm transition-colors",
                      compact ? "justify-center px-2" : "gap-3 px-3",
                      isActive
                        ? "bg-sidebar-accent font-semibold text-sidebar-accent-foreground"
                        : "text-sidebar-foreground/68 hover:bg-white/[0.06] hover:text-white",
                    )
                  }
                >
                  {({ isActive }) => (
                    <>
                      {isActive && <span className="absolute inset-y-2 left-0 w-0.5 rounded-r-full bg-success" />}
                      <item.icon className="h-[17px] w-[17px] shrink-0" />
                      {!compact && (
                        <>
                          <span className="min-w-0 flex-1 truncate">{item.label}</span>
                          {!item.ready && (
                            <span className="shrink-0 rounded-full border border-white/10 px-1.5 py-0.5 text-[8px] font-semibold uppercase tracking-wider text-sidebar-foreground/35">
                              Breve
                            </span>
                          )}
                        </>
                      )}
                    </>
                  )}
                </NavLink>
              ))}
            </div>
          </div>
        ))}
      </div>
    </nav>
  );
}

function SidebarFooter({ compact = false }: { compact?: boolean }) {
  const { session, signOut } = useAuth();

  return (
    <div className={cn("shrink-0 border-t border-sidebar-border", compact ? "p-2" : "p-3")}>
      {!compact && (
        <div className="mb-2 flex items-center justify-between rounded-lg border border-white/[0.07] bg-white/[0.035] px-3 py-2 text-[11px]">
          <span className="flex items-center gap-2 text-sidebar-foreground/55">
            <span className="h-1.5 w-1.5 rounded-full bg-success shadow-[0_0_8px_rgba(199,243,75,.55)]" />
            {APP_ENVIRONMENT}
          </span>
          <span className="font-medium tabular-nums text-sidebar-foreground/75">v{APP_VERSION}</span>
        </div>
      )}
      <div className={cn("flex items-center rounded-lg", compact ? "justify-center" : "gap-2 px-2 py-1")}>
        {!compact && (
          <div className="min-w-0 flex-1">
            <p className="truncate text-xs font-medium text-sidebar-foreground/85">Administrador</p>
            <p className="truncate text-[10px] text-sidebar-foreground/40" title={session?.user.email ?? undefined}>
              {session?.user.email}
            </p>
          </div>
        )}
        <Button
          variant="ghost"
          size="icon"
          onClick={() => void signOut()}
          title="Sair"
          aria-label="Sair"
          className="h-8 w-8 shrink-0 text-sidebar-foreground/55 hover:bg-white/10 hover:text-white"
        >
          <LogOut className="h-4 w-4" />
        </Button>
      </div>
    </div>
  );
}

export function AppShell() {
  const queryClient = useQueryClient();
  const activeFetches = useIsFetching();
  const [collapsed, setCollapsed] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);
  const [commandOpen, setCommandOpen] = useState(false);
  const [compact, setCompact] = useState(() => localStorage.getItem("ptm-admin-density") === "compact");
  const location = useLocation();
  const currentItem = useMemo(
    () => allNavItems.find((item) => item.to === location.pathname) ?? allNavItems[0],
    [location.pathname],
  );
  const pageUpdatedAt = useMemo(() => {
    const timestamps = queryClient.getQueryCache().getAll()
      .filter((query) => query.getObserversCount() > 0 && query.state.dataUpdatedAt > 0)
      .map((query) => query.state.dataUpdatedAt);
    return timestamps.length ? Math.max(...timestamps) : null;
  }, [activeFetches, location.pathname, queryClient]);

  useEffect(() => {
    localStorage.setItem("ptm-admin-density", compact ? "compact" : "comfortable");
  }, [compact]);

  const toggleCompact = useCallback(() => setCompact((value) => !value), []);
  const refreshActiveData = useCallback(() => {
    void queryClient.invalidateQueries({ type: "active" });
  }, [queryClient]);

  return (
    <div className="flex h-screen overflow-hidden bg-background text-foreground" data-density={compact ? "compact" : "comfortable"}>
      <aside
        className={cn(
          "hidden h-screen shrink-0 flex-col border-r border-sidebar-border bg-sidebar text-sidebar-foreground transition-[width] duration-200 md:flex",
          collapsed ? "w-[76px]" : "w-[248px]",
        )}
      >
        <div className={cn("flex h-16 shrink-0 items-center border-b border-sidebar-border", collapsed ? "justify-center px-2" : "px-4")}>
          <Brand compact={collapsed} />
        </div>
        <SidebarNav compact={collapsed} />
        <SidebarFooter compact={collapsed} />
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="z-30 flex h-16 shrink-0 items-center justify-between border-b border-border/80 bg-card/95 px-4 backdrop-blur-sm sm:px-6 lg:px-8">
          <div className="flex min-w-0 items-center gap-3">
            <Sheet open={mobileOpen} onOpenChange={setMobileOpen}>
              <SheetTrigger asChild>
                <Button variant="outline" size="icon" className="md:hidden" aria-label="Abrir menu">
                  <Menu className="h-4 w-4" />
                </Button>
              </SheetTrigger>
              <SheetContent side="left" className="flex w-[286px] flex-col border-sidebar-border bg-sidebar p-0 text-sidebar-foreground">
                <SheetTitle className="sr-only">Menu principal</SheetTitle>
                <div className="flex h-16 shrink-0 items-center border-b border-sidebar-border px-4">
                  <Brand />
                </div>
                <SidebarNav onNavigate={() => setMobileOpen(false)} />
                <SidebarFooter />
              </SheetContent>
            </Sheet>

            <Button
              variant="ghost"
              size="icon"
              className="hidden text-muted-foreground md:inline-flex"
              onClick={() => setCollapsed((value) => !value)}
              aria-label={collapsed ? "Expandir menu" : "Recolher menu"}
              title={collapsed ? "Expandir menu" : "Recolher menu"}
            >
              {collapsed ? <PanelLeftOpen className="h-4 w-4" /> : <PanelLeftClose className="h-4 w-4" />}
            </Button>

            <div className="min-w-0">
              <div className="flex items-center gap-2 text-[11px] font-medium text-muted-foreground">
                <span>PTM Admin</span>
                <span className="text-border">/</span>
                <span className="truncate">{currentItem.label}</span>
              </div>
              <p className="truncate text-sm font-semibold text-foreground">{currentItem.description}</p>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <SystemHealthPopover />
            <UpdatedAt value={pageUpdatedAt} loading={activeFetches > 0} className="hidden xl:inline-flex" />
            <Button variant="outline" size="sm" className="gap-2 px-2 sm:px-3" onClick={() => setCommandOpen(true)} aria-label="Abrir busca e comandos">
              <Search className="h-4 w-4" />
              <span className="hidden lg:inline">Buscar</span>
              <kbd className="hidden rounded border border-border bg-muted px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground xl:inline">Ctrl K</kbd>
            </Button>
            <div className="hidden h-8 items-center gap-2 rounded-full border border-border bg-background px-3 text-xs text-muted-foreground sm:flex">
              <ShieldCheck className="h-3.5 w-3.5 text-success-foreground" />
              <span>{APP_ENVIRONMENT}</span>
              <span className="text-border">•</span>
              <span className="tabular-nums">v{APP_VERSION}</span>
            </div>
          </div>
        </header>

        <main className="min-h-0 flex-1 overflow-y-auto overscroll-contain">
          <div className="mx-auto w-full max-w-[1600px] px-4 py-5 sm:px-6 sm:py-6 lg:px-8 lg:py-7">
            <Outlet />
          </div>
        </main>
      </div>
      <CommandPalette
        open={commandOpen}
        onOpenChange={setCommandOpen}
        compact={compact}
        onToggleCompact={toggleCompact}
        onRefresh={refreshActiveData}
      />
    </div>
  );
}
