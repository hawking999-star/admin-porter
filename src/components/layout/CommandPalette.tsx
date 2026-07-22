import { useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { Gauge, LayoutList, RefreshCw, Search, Zap } from "lucide-react";
import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandSeparator,
  CommandShortcut,
} from "@/components/ui/command";
import { allNavItems } from "@/lib/navigation";
import { todayInput } from "@/lib/period";

type CommandPaletteProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  compact: boolean;
  onToggleCompact: () => void;
  onRefresh: () => void;
};

export function CommandPalette({
  open,
  onOpenChange,
  compact,
  onToggleCompact,
  onRefresh,
}: CommandPaletteProps) {
  const navigate = useNavigate();

  const run = (action: () => void) => {
    action();
    onOpenChange(false);
  };

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      const typing = target?.matches("input, textarea, select, [contenteditable=true]");

      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        onOpenChange(!open);
        return;
      }
      if (typing) return;
      if (event.key === "/") {
        const search = document.querySelector<HTMLInputElement>("[data-global-search]");
        if (search) {
          event.preventDefault();
          search.focus();
        }
      }
      if (event.altKey && event.key.toLowerCase() === "r") {
        event.preventDefault();
        onRefresh();
      }
      if (event.altKey && event.key.toLowerCase() === "d") {
        event.preventDefault();
        onToggleCompact();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onOpenChange, onRefresh, onToggleCompact, open]);

  const today = todayInput();
  const savedViews = [
    {
      label: "Falhas de hoje",
      description: "Importações com erro registradas hoje",
      to: `/musicas?status=import_failed&period=custom&from=${today}&to=${today}`,
    },
    {
      label: "Playlists pendentes",
      description: "Envios aguardando revisão",
      to: "/musicas?status=pending",
    },
    {
      label: "Operadores em atenção",
      description: "Operadores com sinais operacionais de atenção",
      to: "/?status=attention",
    },
  ];

  return (
    <CommandDialog open={open} onOpenChange={onOpenChange}>
      <CommandInput placeholder="Buscar tela, filtro salvo ou ação..." />
      <CommandList>
        <CommandEmpty>Nenhuma tela ou ação encontrada.</CommandEmpty>
        <CommandGroup heading="Navegação">
          {allNavItems.map((item) => (
            <CommandItem key={item.to} value={`${item.label} ${item.description}`} onSelect={() => run(() => navigate(item.to))}>
              <item.icon className="h-4 w-4" />
              <span>{item.label}</span>
              <span className="ml-auto text-xs text-muted-foreground">{item.description}</span>
            </CommandItem>
          ))}
        </CommandGroup>
        <CommandSeparator />
        <CommandGroup heading="Filtros salvos">
          {savedViews.map((view) => (
            <CommandItem key={view.label} value={`${view.label} ${view.description}`} onSelect={() => run(() => navigate(view.to))}>
              <Zap className="h-4 w-4" />
              <div>
                <p>{view.label}</p>
                <p className="text-xs text-muted-foreground">{view.description}</p>
              </div>
            </CommandItem>
          ))}
        </CommandGroup>
        <CommandSeparator />
        <CommandGroup heading="Ações rápidas">
          <CommandItem onSelect={() => run(onRefresh)}>
            <RefreshCw className="h-4 w-4" /> Atualizar dados da tela
            <CommandShortcut>Alt R</CommandShortcut>
          </CommandItem>
          <CommandItem onSelect={() => run(onToggleCompact)}>
            {compact ? <LayoutList className="h-4 w-4" /> : <Gauge className="h-4 w-4" />}
            {compact ? "Usar modo confortável" : "Usar modo compacto"}
            <CommandShortcut>Alt D</CommandShortcut>
          </CommandItem>
          <CommandItem onSelect={() => run(() => document.querySelector<HTMLInputElement>("[data-global-search]")?.focus())}>
            <Search className="h-4 w-4" /> Focar busca da tela
            <CommandShortcut>/</CommandShortcut>
          </CommandItem>
        </CommandGroup>
      </CommandList>
    </CommandDialog>
  );
}
