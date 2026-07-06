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
  /** false = tela ainda não construída (mostra "Em breve") */
  ready?: boolean;
};

export type NavGroup = { label: string; items: NavItem[] };

export const navGroups: NavGroup[] = [
  {
    label: "Operação",
    items: [
      { to: "/", label: "Visão Geral", description: "Resumo da operação", icon: LayoutDashboard, ready: true },
      { to: "/condominios", label: "Condomínios", description: "Unidades e equipes", icon: Building2, ready: true },
      { to: "/usuarios", label: "Usuários", description: "Operadores e acessos", icon: Users, ready: true },
    ],
  },
  {
    label: "Engajamento",
    items: [
      { to: "/challenges", label: "Challenges", description: "Desafios e regras", icon: Puzzle },
      { to: "/musicas", label: "Músicas", description: "Playlists dos operadores", icon: Music, ready: true },
      { to: "/feedback", label: "Feedback", description: "Retornos dos operadores", icon: MessageSquare, ready: true },
    ],
  },
  {
    label: "Sistema",
    items: [
      { to: "/analytics", label: "Analytics", description: "Relatórios e métricas", icon: BarChart3 },
      { to: "/logs", label: "Logs", description: "Eventos e diagnóstico", icon: ClipboardList },
      { to: "/auditoria", label: "Auditoria", description: "Ações administrativas", icon: ClipboardList },
      { to: "/atualizacoes", label: "Atualizações", description: "Versões do app", icon: BellRing },
      { to: "/integracao", label: "Integração", description: "Diagnóstico técnico", icon: Code2 },
    ],
  },
];

export const allNavItems = navGroups.flatMap((g) => g.items);
