"""Resolução de fontes musicais sem baixar áudio.

Esta camada é independente da fila, do R2 e do processo de download. O worker
recebe uma coleção normalizada e continua usando o fluxo de yt-dlp já existente.
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import unicodedata
from dataclasses import asdict, dataclass
from difflib import SequenceMatcher
from typing import Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

from music_security import (
    parse_supported_music_url,
    redact_sensitive,
    sanitize_json,
    sanitize_string_list,
    sanitize_text,
    validate_server_endpoint,
)

MAX_RESOLVER_RESPONSE_BYTES = 5 * 1024 * 1024
MAX_RESOLVER_TRACKS = 1000
ALLOWED_MATCH_STATUSES = {"resolved", "review_recommended", "not_found", "failed"}


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
    value = song.get("url") or song.get("spotify_url")
    if isinstance(value, str) and value.strip():
        try:
            parsed = parse_supported_music_url(value)
            return parsed.normalized_url if parsed.source == "spotify" and parsed.resource_type == "track" else None
        except ValueError:
            return None
    track_id = song.get("song_id") or song.get("track_id")
    if isinstance(track_id, str) and re.fullmatch(r"[A-Za-z0-9]{22}", track_id):
        return f"https://open.spotify.com/track/{track_id}"
    return None


def _artists(song: dict) -> list[str]:
    value = song.get("artists")
    if isinstance(value, list):
        names = [str(item).strip() for item in value if str(item).strip()]
        if names:
            return names
    artist = sanitize_text(song.get("artist"), 120)
    return [artist] if artist else []


def _duration_ms(value: object) -> int | None:
    try:
        duration = float(value)  # spotDL salva duração em segundos.
    except (TypeError, ValueError):
        return None
    return int(duration * 1000) if duration >= 0 else None


VERSION_ATTENTION_TERMS = (
    "live", "ao vivo", "remix", "cover", "karaoke", "instrumental",
    "sped up", "slowed", "nightcore", "acoustic", "acustico", "reverb", "remastered",
)


def _normalise_text(value: object) -> str:
    text = unicodedata.normalize("NFKD", str(value or "")).encode("ascii", "ignore").decode("ascii")
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def _first_text(song: dict, keys: tuple[str, ...]) -> str | None:
    for key in keys:
        value = song.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _first_duration(song: dict, keys: tuple[str, ...]) -> int | None:
    for key in keys:
        duration = _duration_ms(song.get(key))
        if duration is not None:
            return duration
    return None


def classify_spotify_match(song: dict, *, title: str, artists: list[str], duration_ms: int | None, video_id: str | None) -> tuple[str, str | None]:
    """Classifica por sinais; confiança isolada jamais rejeita ou recomenda revisão."""
    if not video_id:
        return "not_found", "Não foi possível localizar esta música no YouTube."

    candidate_title = _first_text(song, ("youtube_title", "download_title", "matched_title")) or title
    candidate_artist = _first_text(song, ("youtube_artist", "download_artist", "matched_artist")) or ", ".join(artists)
    candidate_duration = _first_duration(song, ("youtube_duration", "download_duration", "matched_duration"))
    source_title = _normalise_text(title)
    source_artist = _normalise_text(", ".join(artists))
    matched_title = _normalise_text(candidate_title)
    matched_artist = _normalise_text(candidate_artist)
    reasons: list[str] = []

    # Palavras de versão só pesam se aparecem no candidato, mas não no Spotify.
    for term in VERSION_ATTENTION_TERMS:
        normalised_term = _normalise_text(term)
        if normalised_term in matched_title and normalised_term not in source_title:
            reasons.append(f"versão diferente: {term}")
            break
    if source_title and matched_title and SequenceMatcher(None, source_title, matched_title).ratio() < 0.62:
        reasons.append("título com divergência relevante")
    if source_artist and matched_artist and SequenceMatcher(None, source_artist, matched_artist).ratio() < 0.55:
        reasons.append("artista com divergência relevante")
    if duration_ms is not None and candidate_duration is not None:
        difference_seconds = abs(duration_ms - candidate_duration) / 1000
        # Pequenas diferenças de edição/intro são aceitas; acima disso pede revisão.
        if difference_seconds > 8:
            reasons.append(f"duração diverge {difference_seconds:.0f}s")

    if reasons:
        return "review_recommended", "; ".join(reasons)
    return "resolved", None


def _load_spotdl_songs(path: str) -> list[dict]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"SPOTIFY_METADATA_ERROR: arquivo .spotdl inválido: {exc}") from exc
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        for key in ("songs", "tracks", "items"):
            value = payload.get(key)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]
    raise RuntimeError("SPOTIFY_METADATA_ERROR: formato .spotdl não reconhecido.")


class SpotDlSpotifyResolver:
    """Implementa Spotify -> metadados/URL do YouTube via spotDL, sem download."""

    def __init__(self, *, max_tracks: int, timeout_seconds: int, cookie_file: str = ""):
        self.max_tracks = max_tracks
        self.timeout_seconds = timeout_seconds
        self.cookie_file = cookie_file

    def _run(self, command: list[str]) -> str:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        try:
            output, _ = process.communicate(timeout=self.timeout_seconds)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                output, _ = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                output, _ = process.communicate()
            raise TimeoutError(f"SPOTIFY_RESOLVE_TIMEOUT: spotDL excedeu {self.timeout_seconds}s.")
        if process.returncode != 0:
            lowered_output = output.lower()
            if any(term in lowered_output for term in (
                "not found",
                "couldn't find",
                "could not find",
                "invalid spotify",
                "playlist is unavailable",
            )):
                raise RuntimeError("SPOTIFY_LINK_UNAVAILABLE")
            raise RuntimeError(
                f"SPOTIFY_METADATA_ERROR: spotDL terminou com código {process.returncode}: "
                f"{redact_sensitive(output[-500:])}"
            )
        return output

    def resolve(self, url: str) -> ResolvedMusicCollection:
        parsed_source = parse_supported_music_url(url)
        if parsed_source.source != "spotify":
            raise ValueError("INVALID_URL")
        url = parsed_source.normalized_url
        with tempfile.TemporaryDirectory() as metadata_dir:
            save_path = os.path.join(metadata_dir, "spotify-metadata.spotdl")
            command = [
                sys.executable, "-m", "spotdl", "save", url,
                "--save-file", save_path,
                "--preload",
                "--audio", "youtube-music", "youtube",
                "--max-retries", "3",
                "--log-level", "ERROR",
            ]
            if self.cookie_file:
                command.extend(["--cookie-file", self.cookie_file])
            self._run(command)
            # Resolver apenas descreve a coleção. O worker aplica o limite de
            # processamento e registra os itens excedentes como tal.
            songs = _load_spotdl_songs(save_path)[:MAX_RESOLVER_TRACKS]

        tracks: list[ResolvedSpotifyTrack] = []
        for position, song in enumerate(songs, start=1):
            spotify_id = song.get("song_id") or song.get("track_id")
            spotify_url = _spotify_url(song) or url
            title = sanitize_text(song.get("name") or song.get("title") or spotify_id or "Faixa do Spotify")
            artists = sanitize_string_list(_artists(song))
            duration_ms = _duration_ms(song.get("duration"))
            matched_url = song.get("download_url") if isinstance(song.get("download_url"), str) else None
            video_id = youtube_video_id(matched_url)
            match_status, review_reason = classify_spotify_match(
                song,
                title=title,
                artists=artists,
                duration_ms=duration_ms,
                video_id=video_id,
            )
            tracks.append(
                ResolvedSpotifyTrack(
                    position=position,
                    spotifyTrackId=str(spotify_id) if spotify_id else None,
                    spotifyUrl=spotify_url,
                    title=title,
                    artists=artists,
                    album=sanitize_text(song.get("album_name"), 300) or None,
                    durationMs=duration_ms,
                    youtubeUrl=f"https://www.youtube.com/watch?v={video_id}" if video_id else None,
                    youtubeVideoId=video_id,
                    # A pontuação é informativa; não decide rejeição sozinha.
                    matchConfidence=float(song["match_confidence"])
                    if isinstance(song.get("match_confidence"), (int, float)) else None,
                    matchStatus=match_status,
                    errorMessage=review_reason,
                )
            )
        return ResolvedMusicCollection(source="spotify", sourceUrl=url, tracks=tracks)


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
            raise RuntimeError("SPOTIFY_METADATA_ERROR: SPOTIFY_RESOLVER_TOKEN não configurado.")
        parsed_source = parse_supported_music_url(url)
        if parsed_source.source != "spotify":
            raise ValueError("INVALID_URL")
        request = Request(
            f"{self.base_url}/resolve",
            data=json.dumps({"url": parsed_source.normalized_url}).encode("utf-8"),
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with build_opener(_NoRedirectHandler()).open(request, timeout=self.timeout_seconds) as response:
                raw = response.read(MAX_RESOLVER_RESPONSE_BYTES + 1)
                if len(raw) > MAX_RESOLVER_RESPONSE_BYTES:
                    raise ValueError("resolver response too large")
                payload = sanitize_json(json.loads(raw.decode("utf-8")), max_bytes=MAX_RESOLVER_RESPONSE_BYTES)
        except (HTTPError, URLError, TimeoutError, ValueError) as exc:
            raise RuntimeError("SPOTIFY_RESOLVER_UNAVAILABLE") from exc

        raw_tracks = payload.get("tracks") if isinstance(payload, dict) else None
        if not isinstance(raw_tracks, list):
            raise RuntimeError("SPOTIFY_METADATA_ERROR: resposta inválida do serviço de resolução.")
        try:
            tracks = [
                _sanitized_remote_track(item, position)
                for position, item in enumerate(raw_tracks[:MAX_RESOLVER_TRACKS], start=1)
                if isinstance(item, dict)
            ]
        except TypeError as exc:
            raise RuntimeError("SPOTIFY_METADATA_ERROR: faixa inválida no serviço de resolução.") from exc
        return ResolvedMusicCollection(source="spotify", sourceUrl=url, tracks=tracks)


def resolver_from_environment(*, max_tracks: int, timeout_seconds: int, cookie_file: str = "") -> MusicSourceResolver:
    resolver_url = os.environ.get("SPOTIFY_RESOLVER_URL", "").strip()
    if resolver_url:
        return HttpMusicSourceResolver(
            base_url=resolver_url,
            token=os.environ.get("SPOTIFY_RESOLVER_TOKEN", ""),
            timeout_seconds=timeout_seconds,
            max_tracks=max_tracks,
            allow_private=os.environ.get("SPOTIFY_RESOLVER_ALLOW_PRIVATE", "").lower() in {"1", "true", "yes", "on"},
        )
    return SpotDlSpotifyResolver(
        max_tracks=max_tracks,
        timeout_seconds=timeout_seconds,
        cookie_file=cookie_file,
    )


def _sanitized_remote_track(item: dict, fallback_position: int) -> ResolvedSpotifyTrack:
    position = item.get("position")
    if not isinstance(position, int) or position < 1:
        position = fallback_position
    spotify_id = sanitize_text(item.get("spotifyTrackId"), 22) or None
    if spotify_id and not re.fullmatch(r"[A-Za-z0-9]{22}", spotify_id):
        spotify_id = None
    spotify_url = _spotify_url({"spotify_url": item.get("spotifyUrl"), "track_id": spotify_id}) or ""
    video_id = youtube_video_id(item.get("youtubeUrl")) or sanitize_text(item.get("youtubeVideoId"), 11) or None
    if video_id and not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
        video_id = None
    status = sanitize_text(item.get("matchStatus"), 30)
    if status not in ALLOWED_MATCH_STATUSES:
        status = "failed"
    duration = item.get("durationMs")
    duration_ms = duration if isinstance(duration, int) and 0 <= duration <= 24 * 60 * 60 * 1000 else None
    confidence = item.get("matchConfidence")
    match_confidence = float(confidence) if isinstance(confidence, (int, float)) and 0 <= confidence <= 100 else None
    return ResolvedSpotifyTrack(
        position=position,
        spotifyTrackId=spotify_id,
        spotifyUrl=spotify_url,
        title=sanitize_text(item.get("title") or "Faixa do Spotify"),
        artists=sanitize_string_list(item.get("artists")),
        album=sanitize_text(item.get("album"), 300) or None,
        durationMs=duration_ms,
        youtubeUrl=f"https://www.youtube.com/watch?v={video_id}" if video_id else None,
        youtubeVideoId=video_id,
        matchConfidence=match_confidence,
        matchStatus=status,
        errorMessage=sanitize_text(item.get("errorMessage"), 1000) or None,
    )


def collection_as_dict(collection: ResolvedMusicCollection) -> dict:
    """Representação segura para testes/serviços internos; não inclui comando ou token."""
    return {"source": collection.source, "sourceUrl": collection.sourceUrl, "tracks": [asdict(track) for track in collection.tracks]}
