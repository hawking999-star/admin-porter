import type { ReactNode } from "react";
import { Youtube, Link2, Music2, type LucideProps } from "lucide-react";
import { cn } from "@/lib/utils";
import { parseMusicUrl } from "@/lib/music-url";

/* ------------------------------------------------------------------ */
/*  Avatar com iniciais do operador                                    */
/* ------------------------------------------------------------------ */

export function initialsOf(name: string | null): string {
  if (!name) return "?";
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "?";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

export function OperatorAvatar({
  name,
  className,
}: {
  name: string | null;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex h-10 w-10 shrink-0 select-none items-center justify-center rounded-full",
        "bg-secondary text-xs font-semibold text-secondary-foreground",
        className,
      )}
    >
      {initialsOf(name)}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/*  Plataforma do link (Spotify / YouTube / outro / inválido)          */
/* ------------------------------------------------------------------ */

export type Platform = "spotify" | "youtube" | "other" | "invalid" | "none";

export function detectPlatform(url: string | null): Platform {
  if (!url) return "none";
  const parsed = parseMusicUrl(url);
  if (parsed) return parsed.source;

  try {
    const candidate = new URL(url);
    if (!["http:", "https:"].includes(candidate.protocol)) return "invalid";
    if (
      candidate.hostname === "open.spotify.com" ||
      candidate.hostname === "youtube.com" ||
      candidate.hostname === "www.youtube.com" ||
      candidate.hostname === "music.youtube.com" ||
      candidate.hostname === "youtu.be"
    ) {
      return "invalid";
    }
  } catch {
    return "invalid";
  }
  return "other";
}

export function SpotifyIcon({ className }: LucideProps) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" className={cn("size-4", className)} aria-hidden>
      <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm4.586 14.424a.622.622 0 0 1-.857.207c-2.348-1.435-5.304-1.76-8.785-.964a.622.622 0 1 1-.277-1.215c3.809-.87 7.077-.496 9.712 1.115a.623.623 0 0 1 .207.857zm1.224-2.724a.78.78 0 0 1-1.072.257c-2.687-1.652-6.785-2.131-9.965-1.166a.78.78 0 1 1-.452-1.491c3.632-1.102 8.147-.568 11.232 1.328a.78.78 0 0 1 .257 1.072zm.105-2.835C14.692 8.95 9.375 8.775 6.298 9.71a.936.936 0 1 1-.542-1.79c3.532-1.072 9.404-.865 13.115 1.338a.936.936 0 1 1-.956 1.607z" />
    </svg>
  );
}

const PLATFORM_META: Record<
  Platform,
  { label: string; icon: (p: LucideProps) => ReactNode; fg: string; bg: string; ring: string }
> = {
  spotify: {
    label: "Spotify",
    icon: (p) => <SpotifyIcon {...p} />,
    fg: "text-[#1DB954]",
    bg: "bg-[#1DB954]/10",
    ring: "ring-[#1DB954]/25",
  },
  youtube: {
    label: "YouTube",
    icon: (p) => <Youtube {...p} />,
    fg: "text-[#FF0000]",
    bg: "bg-[#FF0000]/10",
    ring: "ring-[#FF0000]/20",
  },
  other: {
    label: "Link",
    icon: (p) => <Link2 {...p} />,
    fg: "text-muted-foreground",
    bg: "bg-muted",
    ring: "ring-border",
  },
  invalid: {
    label: "Link inválido",
    icon: (p) => <Link2 {...p} />,
    fg: "text-destructive",
    bg: "bg-destructive/10",
    ring: "ring-destructive/20",
  },
  none: {
    label: "Sem link",
    icon: (p) => <Music2 {...p} />,
    fg: "text-muted-foreground",
    bg: "bg-muted",
    ring: "ring-border",
  },
};

export function platformMeta(p: Platform) {
  return PLATFORM_META[p];
}

/** Ícone circular da plataforma (usado como "capa" do card). */
export function PlatformIcon({ platform, className }: { platform: Platform; className?: string }) {
  const m = PLATFORM_META[platform];
  return (
    <div
      className={cn(
        "flex h-11 w-11 shrink-0 items-center justify-center rounded-xl ring-1",
        m.bg,
        m.ring,
        className,
      )}
    >
      {m.icon({ className: cn("size-5", m.fg) })}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/*  Badge de status de aprovação (cor própria por status)              */
/* ------------------------------------------------------------------ */

const STATUS_META: Record<string, { label: string; dot: string; cls: string }> = {
  pending: {
    label: "Pendente",
    dot: "bg-warning",
    cls: "bg-warning/15 text-warning-foreground ring-warning/40",
  },
  approved: {
    label: "Aprovada",
    dot: "bg-success",
    cls: "bg-success/30 text-success-foreground ring-success/50",
  },
  rejected: {
    label: "Rejeitada",
    dot: "bg-destructive",
    cls: "bg-destructive/10 text-destructive ring-destructive/25",
  },
  draft: {
    label: "Aguardando envio",
    dot: "bg-muted-foreground/50",
    cls: "bg-muted text-muted-foreground ring-border",
  },
};

export function StatusPill({ status, className }: { status: string; className?: string }) {
  const m = STATUS_META[status] ?? STATUS_META.draft;
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-semibold ring-1",
        m.cls,
        className,
      )}
    >
      <span className={cn("h-1.5 w-1.5 rounded-full", m.dot)} />
      {m.label}
    </span>
  );
}

/* ------------------------------------------------------------------ */
/*  Chip de filtro rápido (toggle)                                     */
/* ------------------------------------------------------------------ */

export function FilterChip({
  active,
  onClick,
  icon,
  children,
}: {
  active: boolean;
  onClick: () => void;
  icon?: ReactNode;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-xs font-medium",
        "cursor-pointer transition-all duration-150 [&_svg]:size-3.5",
        active
          ? "border-primary bg-primary text-primary-foreground shadow-sm"
          : "border-border bg-background text-muted-foreground hover:border-primary/40 hover:text-foreground",
      )}
    >
      {icon}
      {children}
    </button>
  );
}

/* ------------------------------------------------------------------ */
/*  Preview embutido (Spotify / YouTube) quando possível               */
/* ------------------------------------------------------------------ */

export function buildEmbed(url: string | null, platform: Platform): string | null {
  if (!url) return null;
  const parsed = parseMusicUrl(url);
  if (!parsed || parsed.source !== platform) return null;

  if (parsed.source === "spotify") {
    return `https://open.spotify.com/embed/${parsed.resourceType}/${parsed.resourceId}`;
  }
  if (parsed.resourceType === "playlist") {
    return `https://www.youtube.com/embed/videoseries?list=${parsed.resourceId}`;
  }
  return `https://www.youtube.com/embed/${parsed.resourceId}`;
}
