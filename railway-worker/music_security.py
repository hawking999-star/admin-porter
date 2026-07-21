"""Guardas de segurança compartilhadas pelo resolver e pelo downloader."""

from __future__ import annotations

import ipaddress
import json
import re
import socket
from dataclasses import dataclass
from urllib.parse import parse_qs, urlparse

MAX_URL_LENGTH = 2048
MAX_METADATA_TEXT_LENGTH = 300
YOUTUBE_HOSTS = {"youtube.com", "www.youtube.com", "music.youtube.com"}
AUTOMATIC_PLAYLIST_PREFIXES = ("RD", "UL", "LL", "WL")
CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f]+")
SECRET_PATTERNS = (
    re.compile(r"(?i)(authorization\s*:\s*bearer\s+)[^\s,;]+"),
    re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"),
    re.compile(r"\bsb_secret_[A-Za-z0-9_-]+\b"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b"),
)


@dataclass(frozen=True)
class SafeMusicUrl:
    source: str
    resource_type: str
    resource_id: str
    normalized_url: str


def sanitize_text(value: object, max_length: int = MAX_METADATA_TEXT_LENGTH) -> str:
    text = CONTROL_CHARS.sub(" ", str(value or ""))
    return re.sub(r"\s+", " ", text).strip()[:max_length]


def sanitize_string_list(value: object, *, max_items: int = 20, max_length: int = 120) -> list[str]:
    if not isinstance(value, list):
        return []
    result: list[str] = []
    for item in value[:max_items]:
        cleaned = sanitize_text(item, max_length)
        if cleaned:
            result.append(cleaned)
    return result


def redact_sensitive(value: object, secrets: tuple[str, ...] = ()) -> str:
    text = str(value or "")
    for secret in secrets:
        if secret and len(secret) >= 8:
            text = text.replace(secret, "[REDACTED]")
    for pattern in SECRET_PATTERNS:
        text = pattern.sub(lambda match: f"{match.group(1)}[REDACTED]" if match.lastindex else "[REDACTED]", text)
    return CONTROL_CHARS.sub(" ", text)[:4000]


def sanitize_json(value: object, *, max_bytes: int = 1_000_000) -> object:
    """Mantém apenas JSON limitado, sem objetos executáveis ou textos gigantes."""
    encoded = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if len(encoded.encode("utf-8")) > max_bytes:
        raise ValueError("METADATA_TOO_LARGE")
    return json.loads(encoded)


def _url_parts(value: str):
    if not isinstance(value, str):
        raise ValueError("INVALID_URL")
    raw = value.strip()
    if not raw or len(raw) > MAX_URL_LENGTH or CONTROL_CHARS.search(raw):
        raise ValueError("INVALID_URL")
    try:
        parsed = urlparse(raw)
        port = parsed.port
    except ValueError as exc:
        raise ValueError("INVALID_URL") from exc
    if parsed.scheme not in {"http", "https"} or parsed.username or parsed.password or port:
        raise ValueError("INVALID_URL")
    return parsed


def parse_supported_music_url(value: str) -> SafeMusicUrl:
    parsed = _url_parts(value)
    host = (parsed.hostname or "").lower()
    segments = [segment for segment in parsed.path.split("/") if segment]

    if host == "open.spotify.com":
        if segments and re.fullmatch(r"intl-[a-z]{2}", segments[0], re.I):
            segments = segments[1:]
        if len(segments) != 2 or segments[0] not in {"track", "album", "playlist"}:
            raise ValueError("INVALID_URL")
        resource_id = segments[1]
        if not re.fullmatch(r"[A-Za-z0-9]{22}", resource_id):
            raise ValueError("INVALID_URL")
        resource_type = segments[0]
        return SafeMusicUrl(
            "spotify", resource_type, resource_id,
            f"https://open.spotify.com/{resource_type}/{resource_id}",
        )

    playlist_id = parse_qs(parsed.query).get("list", [""])[0]
    if playlist_id and (
        not re.fullmatch(r"[A-Za-z0-9_-]+", playlist_id)
        or playlist_id.upper().startswith(AUTOMATIC_PLAYLIST_PREFIXES)
    ):
        raise ValueError("INVALID_URL")

    if host == "youtu.be":
        if len(segments) != 1 or not re.fullmatch(r"[A-Za-z0-9_-]{11}", segments[0]):
            raise ValueError("INVALID_URL")
        if playlist_id:
            return SafeMusicUrl(
                "youtube", "playlist", playlist_id,
                f"https://www.youtube.com/playlist?list={playlist_id}",
            )
        return SafeMusicUrl(
            "youtube", "video", segments[0],
            f"https://www.youtube.com/watch?v={segments[0]}",
        )

    if host not in YOUTUBE_HOSTS:
        raise ValueError("INVALID_URL")
    if parsed.path == "/playlist" and playlist_id:
        return SafeMusicUrl(
            "youtube", "playlist", playlist_id,
            f"https://www.youtube.com/playlist?list={playlist_id}",
        )
    if parsed.path == "/watch":
        if playlist_id:
            return SafeMusicUrl(
                "youtube", "playlist", playlist_id,
                f"https://www.youtube.com/playlist?list={playlist_id}",
            )
        video_id = parse_qs(parsed.query).get("v", [""])[0]
        if re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
            return SafeMusicUrl(
                "youtube", "video", video_id,
                f"https://www.youtube.com/watch?v={video_id}",
            )
    raise ValueError("INVALID_URL")


def require_youtube_video_url(value: str) -> SafeMusicUrl:
    parsed = parse_supported_music_url(value)
    if parsed.source != "youtube" or parsed.resource_type != "video":
        raise ValueError("INVALID_YOUTUBE_VIDEO_URL")
    return parsed


def validate_server_endpoint(value: str, *, allow_private: bool = False) -> str:
    """Valida URL configurada no servidor e bloqueia redes internas por padrão."""
    raw = value.strip()
    if not raw or len(raw) > MAX_URL_LENGTH:
        raise ValueError("INVALID_RESOLVER_URL")
    try:
        parsed = urlparse(raw)
        port = parsed.port
    except ValueError as exc:
        raise ValueError("INVALID_RESOLVER_URL") from exc
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("INVALID_RESOLVER_URL")
    if parsed.query or parsed.fragment:
        raise ValueError("INVALID_RESOLVER_URL")
    if port not in (None, 443):
        raise ValueError("INVALID_RESOLVER_URL")

    if not allow_private:
        try:
            addresses = {
                item[4][0]
                for item in socket.getaddrinfo(parsed.hostname, port or 443, type=socket.SOCK_STREAM)
            }
        except socket.gaierror as exc:
            raise ValueError("INVALID_RESOLVER_URL") from exc
        for address in addresses:
            ip = ipaddress.ip_address(address)
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast:
                raise ValueError("PRIVATE_RESOLVER_URL_BLOCKED")
    return raw.rstrip("/")
