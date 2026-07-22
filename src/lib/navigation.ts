import {
  BarChart3,
  Building2,
  ClipboardList,
  Code2,
  BellRing,
  LayoutDashboard,
  MessageSquare,
  Music,
  Puzzle,
  Users,
  type LucideIcon,
} from "lucide-react";

export type NavItem = {
  to: string;
  label: string;
  description: string;
  icon: LucideIcon;
  /** false = tela ainda nao construida (mostra "Em breve") */
  ready?: boolean;
};

export type NavGroup = { label: string; items: NavItem[] };

export const navGroups: NavGroup[] = [
  {
    label: "Operação",
    items: [
      { to: "/", label: "Visão Geral", description: "Resumo da operação", icon: LayoutDashboard, ready: true },
      { to: "/condominios", label: "Condomínios", description: "Unidades e equipes", icon: Building2, ready: true },
      { to: "/usuarios", label: "Operadores", description: "Operadores e acessos", icon: Users, ready: true },
    ],
  },
  {
    label: "Conteúdo",
    items: [
      { to: "/challenges", label: "Desafios", description: "Desafios e regras", icon: Puzzle, ready: true },
      { to: "/musicas", label: "Músicas", description: "Playlists dos Operadores", icon: Music, ready: true },
      { to: "/feedback", label: "Feedback", description: "Retornos dos Operadores", icon: MessageSquare, ready: true },
    ],
  },
  {
    label: "Gestão e sistema",
    items: [
      { to: "/analytics", label: "Relatórios", description: "Métricas operacionais", icon: BarChart3, ready: true },
      { to: "/atualizacoes", label: "Atualizações", description: "Versões do app", icon: BellRing, ready: true },
      { to: "/integracao", label: "Integrações", description: "Filas e conexões", icon: Code2, ready: true },
      { to: "/logs", label: "Logs do sistema", description: "Eventos e diagnóstico", icon: ClipboardList, ready: true },
      { to: "/auditoria", label: "Auditoria", description: "Ações administrativas", icon: ClipboardList, ready: true },
    ],
  },
];

export const allNavItems = navGroups.flatMap((g) => g.items);
