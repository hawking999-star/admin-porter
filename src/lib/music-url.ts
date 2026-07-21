export type SupportedMusicSource = "youtube" | "spotify";

export type ParsedMusicUrl = {
  source: SupportedMusicSource;
  resourceType: "track" | "album" | "playlist" | "video";
  resourceId: string;
  originalUrl: string;
  normalizedUrl: string;
};

const SPOTIFY_ID = /^[A-Za-z0-9]{22}$/;
const YOUTUBE_VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;
const YOUTUBE_PLAYLIST_ID = /^[A-Za-z0-9_-]+$/;
const YOUTUBE_HOSTS = new Set(["youtube.com", "www.youtube.com", "music.youtube.com"]);
const AUTO_YOUTUBE_PLAYLIST_PREFIXES = ["RD", "UL", "LL", "WL"];

function isAutomaticYoutubePlaylist(id: string) {
  return AUTO_YOUTUBE_PLAYLIST_PREFIXES.some((prefix) => id.startsWith(prefix));
}

function parseSpotifyUrl(url: URL, originalUrl: string): ParsedMusicUrl | null {
  if (url.hostname !== "open.spotify.com" || url.port || url.username || url.password) return null;

  const segments = url.pathname.split("/").filter(Boolean);
  if (/^intl-[a-z]{2}$/i.test(segments[0] ?? "")) segments.shift();
  if (segments.length !== 2) return null;

  const [resourceType, resourceId] = segments;
  if (!["track", "album", "playlist"].includes(resourceType) || !SPOTIFY_ID.test(resourceId)) {
    return null;
  }

  return {
    source: "spotify",
    resourceType: resourceType as "track" | "album" | "playlist",
    resourceId,
    originalUrl,
    normalizedUrl: `https://open.spotify.com/${resourceType}/${resourceId}`,
  };
}

function youtubePlaylistResult(resourceId: string, originalUrl: string): ParsedMusicUrl | null {
  if (!YOUTUBE_PLAYLIST_ID.test(resourceId) || isAutomaticYoutubePlaylist(resourceId)) return null;
  return {
    source: "youtube",
    resourceType: "playlist",
    resourceId,
    originalUrl,
    normalizedUrl: `https://www.youtube.com/playlist?list=${resourceId}`,
  };
}

function youtubeVideoResult(resourceId: string, originalUrl: string): ParsedMusicUrl | null {
  if (!YOUTUBE_VIDEO_ID.test(resourceId)) return null;
  return {
    source: "youtube",
    resourceType: "video",
    resourceId,
    originalUrl,
    normalizedUrl: `https://www.youtube.com/watch?v=${resourceId}`,
  };
}

function parseYoutubeUrl(url: URL, originalUrl: string): ParsedMusicUrl | null {
  if (url.port || url.username || url.password) return null;

  const playlistId = url.searchParams.get("list");
  if (playlistId && (!YOUTUBE_PLAYLIST_ID.test(playlistId) || isAutomaticYoutubePlaylist(playlistId))) {
    return null;
  }

  if (url.hostname === "youtu.be") {
    const segments = url.pathname.split("/").filter(Boolean);
    if (segments.length !== 1) return null;
    if (playlistId) return youtubePlaylistResult(playlistId, originalUrl);
    return youtubeVideoResult(segments[0], originalUrl);
  }

  if (!YOUTUBE_HOSTS.has(url.hostname)) return null;

  if (url.pathname === "/playlist") {
    return playlistId ? youtubePlaylistResult(playlistId, originalUrl) : null;
  }

  if (url.pathname === "/watch") {
    if (playlistId) return youtubePlaylistResult(playlistId, originalUrl);
    return youtubeVideoResult(url.searchParams.get("v") ?? "", originalUrl);
  }

  return null;
}

export function parseMusicUrl(value: string): ParsedMusicUrl | null {
  const originalUrl = value;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > 2048) return null;

  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    return null;
  }

  if (url.protocol !== "https:" && url.protocol !== "http:") return null;

  if (url.hostname === "open.spotify.com") return parseSpotifyUrl(url, originalUrl);
  if (url.hostname === "youtu.be" || YOUTUBE_HOSTS.has(url.hostname)) {
    return parseYoutubeUrl(url, originalUrl);
  }
  return null;
}

export function normalizeMusicUrl(value: string): string | null {
  return parseMusicUrl(value)?.normalizedUrl ?? null;
}
