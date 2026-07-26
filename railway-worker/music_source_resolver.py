"""Resolução segura de fontes musicais sem baixar áudio do Spotify."""

from __future__ import annotations

import json
import os
import re
import unicodedata
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeoutError
from dataclasses import asdict, dataclass
from difflib import SequenceMatcher
from typing import Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

from SpotipyFree import Spotify as FreeSpotify

from music_security import (
    parse_supported_music_url,
    sanitize_json,
    sanitize_string_list,
    sanitize_text,
    validate_server_endpoint,
)

MAX_RESOLVER_RESPONSE_BYTES = 5 * 1024 * 1024
MAX_RESOLVER_TRACKS = 1000
ALLOWED_MATCH_STATUSES = {
    "resolving",
    "resolved",
    "review_recommended",
    "not_found",
    "failed",
}


class _NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        raise HTTPError(req.full_url, code, "Resolver redirect blocked", headers, fp)


@dataclass(frozen=True)
class ResolvedSpotifyTrack:
    position: int
    spotifyTrackId: str | None
    spotifyUrl: str
    title: str
    artists: list[str]
    album: str | None
    durationMs: int | None
    youtubeUrl: str | None
    youtubeVideoId: str | None
    matchConfidence: float | None
    matchStatus: str
    errorMessage: str | None = None


@dataclass(frozen=True)
class ResolvedMusicCollection:
    source: str
    sourceUrl: str
    tracks: list[ResolvedSpotifyTrack]


class MusicSourceResolver(Protocol):
    """Contrato para resolvers locais ou serviços remotos internos."""

    def resolve(self, url: str) -> ResolvedMusicCollection: ...


def youtube_video_id(url: str | None) -> str | None:
    if not url:
        return None
    try:
        parsed = urlparse(url)
    except ValueError:
        return None
    host = (parsed.hostname or "").lower()
    if host == "youtu.be":
        candidate = parsed.path.strip("/").split("/", 1)[0]
    elif host in {"youtube.com", "www.youtube.com", "music.youtube.com"}:
        candidate = parse_qs(parsed.query).get("v", [""])[0]
    else:
        return None
    return candidate if re.fullmatch(r"[A-Za-z0-9_-]{11}", candidate or "") else None


def _spotify_url(song: dict) -> str | None:
    external_urls = song.get("external_urls")
    external_url = (
        external_urls.get("spotify")
        if isinstance(external_urls, dict)
        else None
    )
    value = song.get("url") or song.get("spotify_url") or external_url
    if isinstance(value, str) and value.strip():
        try:
            parsed = parse_supported_music_url(value)
            if parsed.source == "spotify" and parsed.resource_type == "track":
                return parsed.normalized_url
        except ValueError:
            return None
    track_id = song.get("id") or song.get("song_id") or song.get("track_id")
    if isinstance(track_id, str) and re.fullmatch(r"[A-Za-z0-9]{22}", track_id):
        return f"https://open.spotify.com/track/{track_id}"
    return None


def _artists(song: dict) -> list[str]:
    value = song.get("artists")
    if isinstance(value, list):
        names: list[str] = []
        for item in value:
            raw_name = item.get("name") if isinstance(item, dict) else item
            name = sanitize_text(raw_name, 120)
            if name:
                names.append(name)
        if names:
            return sanitize_string_list(names)
    artist = sanitize_text(song.get("artist"), 120)
    return [artist] if artist else []


def _duration_ms_from_seconds(value: object) -> int | None:
    try:
        duration = float(value)
    except (TypeError, ValueError):
        return None
    return int(duration * 1000) if duration >= 0 else None


def _safe_duration_ms(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        duration = int(value)
    except (TypeError, ValueError):
        return None
    return duration if 0 <= duration <= 24 * 60 * 60 * 1000 else None


VERSION_ATTENTION_TERMS = (
    "live",
    "ao vivo",
    "remix",
    "cover",
    "karaoke",
    "instrumental",
    "sped up",
    "slowed",
    "nightcore",
    "acoustic",
    "acustico",
    "reverb",
    "remastered",
)


def normalise_match_text(value: object) -> str:
    text = (
        unicodedata.normalize("NFKD", str(value or ""))
        .encode("ascii", "ignore")
        .decode("ascii")
    )
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def _first_text(song: dict, keys: tuple[str, ...]) -> str | None:
    for key in keys:
        value = song.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _first_duration(song: dict, keys: tuple[str, ...]) -> int | None:
    for key in keys:
        duration = _duration_ms_from_seconds(song.get(key))
        if duration is not None:
            return duration
    return None


def classify_spotify_match(
    song: dict,
    *,
    title: str,
    artists: list[str],
    duration_ms: int | None,
    video_id: str | None,
) -> tuple[str, str | None]:
    """Classifica por sinais; confiança isolada nunca bloqueia o resultado."""
    if not video_id:
        return "not_found", "Não foi possível localizar esta música no YouTube."

    candidate_title = (
        _first_text(song, ("youtube_title", "download_title", "matched_title"))
        or title
    )
    candidate_artist = (
        _first_text(song, ("youtube_artist", "download_artist", "matched_artist"))
        or ", ".join(artists)
    )
    candidate_duration = _first_duration(
        song,
        ("youtube_duration", "download_duration", "matched_duration"),
    )
    source_title = normalise_match_text(title)
    source_artist = normalise_match_text(", ".join(artists))
    matched_title = normalise_match_text(candidate_title)
    matched_artist = normalise_match_text(candidate_artist)
    reasons: list[str] = []

    for term in VERSION_ATTENTION_TERMS:
        normalised_term = normalise_match_text(term)
        if normalised_term in matched_title and normalised_term not in source_title:
            reasons.append(f"versão diferente: {term}")
            break
    if source_title and matched_title:
        source_title_tokens = {
            token for token in source_title.split() if len(token) > 2
        }
        matched_title_tokens = set(matched_title.split())
        title_coverage = (
            len(source_title_tokens & matched_title_tokens)
            / len(source_title_tokens)
            if source_title_tokens
            else 1.0
        )
        if (
            title_coverage < 0.75
            and SequenceMatcher(None, source_title, matched_title).ratio() < 0.62
        ):
            reasons.append("título com divergência relevante")
    if (
        source_artist
        and matched_artist
        and SequenceMatcher(None, source_artist, matched_artist).ratio() < 0.55
    ):
        reasons.append("artista com divergência relevante")
    if duration_ms is not None and candidate_duration is not None:
        difference_seconds = abs(duration_ms - candidate_duration) / 1000
        if difference_seconds > 8:
            reasons.append(f"duração diverge {difference_seconds:.0f}s")

    if reasons:
        return "review_recommended", "; ".join(reasons)
    return "resolved", None


def _spotify_track_payload(item: object) -> dict | None:
    if not isinstance(item, dict):
        return None
    track = item.get("track")
    return track if isinstance(track, dict) else item


class SpotipyFreeMetadataResolver:
    """Lê metadados públicos do Spotify sem iniciar o CLI/downloader spotDL."""

    def __init__(self, *, max_tracks: int, timeout_seconds: int):
        self.max_tracks = max_tracks
        self.timeout_seconds = timeout_seconds

    @staticmethod
    def _client() -> FreeSpotify:
        return FreeSpotify()

    @staticmethod
    def _source_items(
        client: FreeSpotify,
        url: str,
        resource_type: str,
    ) -> list[dict]:
        if resource_type == "playlist":
            payload = client.playlist_items(url)
            raw_items = payload.get("items") if isinstance(payload, dict) else None
        elif resource_type == "album":
            payload = client.album_tracks(url)
            raw_items = payload.get("items") if isinstance(payload, dict) else None
        elif resource_type == "track":
            raw_items = [client.track(url)]
        else:
            raise ValueError("INVALID_URL")
        if not isinstance(raw_items, list):
            raise RuntimeError(
                "SPOTIFY_METADATA_ERROR: resposta de metadados inválida."
            )
        return [
            track
            for item in raw_items[:MAX_RESOLVER_TRACKS]
            if (track := _spotify_track_payload(item)) is not None
        ]

    def resolve(self, url: str) -> ResolvedMusicCollection:
        parsed_source = parse_supported_music_url(url)
        if parsed_source.source != "spotify":
            raise ValueError("INVALID_URL")
        normalized_url = parsed_source.normalized_url
        executor = ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix="spotify-metadata",
        )
        try:
            future = executor.submit(
                self._source_items,
                self._client(),
                normalized_url,
                parsed_source.resource_type,
            )
            songs = future.result(timeout=self.timeout_seconds)
        except (FutureTimeoutError, TimeoutError, ConnectionError) as exc:
            raise TimeoutError(
                f"SPOTIFY_RESOLVE_TIMEOUT: metadados excederam "
                f"{self.timeout_seconds}s."
            ) from exc
        except (RuntimeError, ValueError):
            raise
        except Exception as exc:  # noqa: BLE001
            lowered = str(exc).lower()
            if any(
                term in lowered
                for term in ("not found", "invalid", "unavailable", "does not exist")
            ):
                raise RuntimeError("SPOTIFY_LINK_UNAVAILABLE") from exc
            raise RuntimeError(
                "SPOTIFY_METADATA_ERROR: falha no cliente público "
                f"({type(exc).__name__})."
            ) from exc
        finally:
            executor.shutdown(wait=False, cancel_futures=True)

        tracks: list[ResolvedSpotifyTrack] = []
        for position, song in enumerate(songs, start=1):
            spotify_id = song.get("id") or song.get("track_id")
            spotify_url = _spotify_url(song) or normalized_url
            title = sanitize_text(
                song.get("name")
                or song.get("title")
                or spotify_id
                or "Faixa do Spotify"
            )
            artists = _artists(song)
            album = song.get("album")
            album_name = (
                sanitize_text(album.get("name"), 300)
                if isinstance(album, dict)
                else sanitize_text(album, 300)
            )
            tracks.append(
                ResolvedSpotifyTrack(
                    position=position,
                    spotifyTrackId=str(spotify_id) if spotify_id else None,
                    spotifyUrl=spotify_url,
                    title=title,
                    artists=artists,
                    album=album_name or None,
                    durationMs=_safe_duration_ms(song.get("duration_ms")),
                    youtubeUrl=None,
                    youtubeVideoId=None,
                    matchConfidence=None,
                    matchStatus="resolving",
                    errorMessage=None,
                )
            )
        return ResolvedMusicCollection(
            source="spotify",
            sourceUrl=normalized_url,
            tracks=tracks,
        )


class HttpMusicSourceResolver:
    """Cliente para um resolver interno separado; token nunca sai do worker."""

    def __init__(
        self,
        *,
        base_url: str,
        token: str,
        timeout_seconds: int,
        max_tracks: int,
        allow_private: bool = False,
    ):
        self.base_url = validate_server_endpoint(base_url, allow_private=allow_private)
        self.token = token
        self.timeout_seconds = timeout_seconds
        self.max_tracks = max_tracks

    def resolve(self, url: str) -> ResolvedMusicCollection:
        if not self.token:
            raise RuntimeError(
                "SPOTIFY_METADATA_ERROR: SPOTIFY_RESOLVER_TOKEN não configurado."
            )
        parsed_source = parse_supported_music_url(url)
        if parsed_source.source != "spotify":
            raise ValueError("INVALID_URL")
        request = Request(
            f"{self.base_url}/resolve",
            data=json.dumps({"url": parsed_source.normalized_url}).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with build_opener(_NoRedirectHandler()).open(
                request,
                timeout=self.timeout_seconds,
            ) as response:
                raw = response.read(MAX_RESOLVER_RESPONSE_BYTES + 1)
                if len(raw) > MAX_RESOLVER_RESPONSE_BYTES:
                    raise ValueError("resolver response too large")
                payload = sanitize_json(
                    json.loads(raw.decode("utf-8")),
                    max_bytes=MAX_RESOLVER_RESPONSE_BYTES,
                )
        except (HTTPError, URLError, TimeoutError, ValueError) as exc:
            raise RuntimeError("SPOTIFY_RESOLVER_UNAVAILABLE") from exc

        raw_tracks = payload.get("tracks") if isinstance(payload, dict) else None
        if not isinstance(raw_tracks, list):
            raise RuntimeError(
                "SPOTIFY_METADATA_ERROR: resposta inválida do serviço de resolução."
            )
        try:
            tracks = [
                _sanitized_remote_track(item, position)
                for position, item in enumerate(
                    raw_tracks[:MAX_RESOLVER_TRACKS],
                    start=1,
                )
                if isinstance(item, dict)
            ]
        except TypeError as exc:
            raise RuntimeError(
                "SPOTIFY_METADATA_ERROR: faixa inválida no serviço de resolução."
            ) from exc
        return ResolvedMusicCollection(
            source="spotify",
            sourceUrl=parsed_source.normalized_url,
            tracks=tracks,
        )


def resolver_from_environment(
    *,
    max_tracks: int,
    timeout_seconds: int,
    cookie_file: str = "",
) -> MusicSourceResolver:
    del cookie_file  # compatibilidade; cookies nunca são enviados ao Spotify.
    resolver_url = os.environ.get("SPOTIFY_RESOLVER_URL", "").strip()
    if resolver_url:
        return HttpMusicSourceResolver(
            base_url=resolver_url,
            token=os.environ.get("SPOTIFY_RESOLVER_TOKEN", ""),
            timeout_seconds=timeout_seconds,
            max_tracks=max_tracks,
            allow_private=os.environ.get(
                "SPOTIFY_RESOLVER_ALLOW_PRIVATE",
                "",
            ).lower()
            in {"1", "true", "yes", "on"},
        )
    return SpotipyFreeMetadataResolver(
        max_tracks=max_tracks,
        timeout_seconds=timeout_seconds,
    )


def _sanitized_remote_track(
    item: dict,
    fallback_position: int,
) -> ResolvedSpotifyTrack:
    position = item.get("position")
    if not isinstance(position, int) or position < 1:
        position = fallback_position
    spotify_id = sanitize_text(item.get("spotifyTrackId"), 22) or None
    if spotify_id and not re.fullmatch(r"[A-Za-z0-9]{22}", spotify_id):
        spotify_id = None
    spotify_url = (
        _spotify_url(
            {
                "spotify_url": item.get("spotifyUrl"),
                "track_id": spotify_id,
            }
        )
        or ""
    )
    video_id = (
        youtube_video_id(item.get("youtubeUrl"))
        or sanitize_text(item.get("youtubeVideoId"), 11)
        or None
    )
    if video_id and not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
        video_id = None
    status = sanitize_text(item.get("matchStatus"), 30)
    if status not in ALLOWED_MATCH_STATUSES:
        status = "failed"
    confidence = item.get("matchConfidence")
    match_confidence = (
        float(confidence)
        if isinstance(confidence, (int, float)) and 0 <= confidence <= 100
        else None
    )
    return ResolvedSpotifyTrack(
        position=position,
        spotifyTrackId=spotify_id,
        spotifyUrl=spotify_url,
        title=sanitize_text(item.get("title") or "Faixa do Spotify"),
        artists=sanitize_string_list(item.get("artists")),
        album=sanitize_text(item.get("album"), 300) or None,
        durationMs=_safe_duration_ms(item.get("durationMs")),
        youtubeUrl=(
            f"https://www.youtube.com/watch?v={video_id}" if video_id else None
        ),
        youtubeVideoId=video_id,
        matchConfidence=match_confidence,
        matchStatus=status,
        errorMessage=sanitize_text(item.get("errorMessage"), 1000) or None,
    )


def collection_as_dict(collection: ResolvedMusicCollection) -> dict:
    """Representação segura para testes e serviços internos."""
    return {
        "source": collection.source,
        "sourceUrl": collection.sourceUrl,
        "tracks": [asdict(track) for track in collection.tracks],
    }
