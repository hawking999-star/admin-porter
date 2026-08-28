"""
Porter Music — Worker de download (Railway)

O que faz, em uma frase: fica de olho na fila `download_jobs` no Supabase; quando
aparece um link aprovado do YouTube ou Spotify, resolve as faixas no YouTube,
baixa o áudio (máx. 170 faixas, cada uma <= 15 MB), sobe cada arquivo para o
Cloudflare R2 e grava em `tracks` + `playlist_tracks`.

Não precisa mexer no código para operar. Tudo é controlado por variáveis de ambiente
(veja .env.example). É só rodar: `python main.py`.
"""

import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from difflib import SequenceMatcher

import boto3
from botocore.config import Config as BotoConfig
from botocore.exceptions import ClientError
from supabase import create_client
from yt_dlp import YoutubeDL

from music_source_resolver import (
    VERSION_ATTENTION_TERMS,
    classify_spotify_match,
    normalise_match_text,
    resolver_from_environment,
)
from music_security import (
    parse_supported_music_url,
    redact_sensitive,
    require_youtube_video_url,
    sanitize_json,
    sanitize_string_list,
    sanitize_text,
)

# --------------------------------------------------------------------------- #
# Configuração (tudo via variáveis de ambiente)
# --------------------------------------------------------------------------- #

def env(name: str, default: str | None = None, required: bool = False) -> str:
    val = os.environ.get(name, default)
    if required and not val:
        print(f"[FATAL] Falta a variável de ambiente: {name}", flush=True)
        sys.exit(1)
    return val or ""

SUPABASE_URL = env("SUPABASE_URL", required=True)
SUPABASE_SERVICE_ROLE_KEY = env("SUPABASE_SERVICE_ROLE_KEY", required=True)

R2_ACCOUNT_ID = env("R2_ACCOUNT_ID", required=True)
R2_ACCESS_KEY_ID = env("R2_ACCESS_KEY_ID", required=True)
R2_SECRET_ACCESS_KEY = env("R2_SECRET_ACCESS_KEY", required=True)
R2_BUCKET = env("R2_BUCKET", required=True)
# Opcional: URL pública/base do bucket (ex.: https://pub-xxxx.r2.dev). Se setado,
# guardamos a URL completa em tracks.metadata.public_url.
R2_PUBLIC_BASE_URL = env("R2_PUBLIC_BASE_URL", "").rstrip("/")

MAX_TRACKS = int(env("MAX_TRACKS", "170"))
PRINCIPAL_TRACK_LIMIT = int(env("PRINCIPAL_TRACK_LIMIT", "170"))
MAX_TRACK_DURATION_SECONDS = int(env("MAX_TRACK_DURATION_SECONDS", "960"))
MAX_FILE_MB = float(env("MAX_FILE_MB", "15"))
MAX_FILE_BYTES = int(MAX_FILE_MB * 1024 * 1024)
AUDIO_BITRATE = int(env("AUDIO_BITRATE", "128"))  # kbps do mp3
POLL_SECONDS = int(env("POLL_SECONDS", "10"))
MAX_ATTEMPTS = min(max(int(env("MAX_ATTEMPTS", "3")), 1), 10)
MAX_CONCURRENT_JOBS = min(max(int(env("MAX_CONCURRENT_JOBS", "10")), 1), 10)
LOCAL_CONCURRENT_JOBS = min(max(int(env("LOCAL_CONCURRENT_JOBS", "5")), 1), 10)
TRACK_CONCURRENCY = min(max(int(env("TRACK_CONCURRENCY", "1")), 1), 1)
TRACK_MAX_ATTEMPTS = min(max(int(env("TRACK_MAX_ATTEMPTS", "2")), 1), 2)
STALE_JOB_SECONDS = int(env("STALE_JOB_SECONDS", "1800"))
STALE_JOB_CHECK_SECONDS = int(env("STALE_JOB_CHECK_SECONDS", "60"))
GLOBAL_FAILURE_ABORT_THRESHOLD = min(
    max(int(env("GLOBAL_FAILURE_ABORT_THRESHOLD", "3")), 2),
    10,
)
YOUTUBE_CIRCUIT_OPEN_SECONDS = min(
    max(int(env("YOUTUBE_CIRCUIT_OPEN_SECONDS", "900")), 60),
    3600,
)
STORAGE_AUDIT_INTERVAL_SECONDS = max(int(env("STORAGE_AUDIT_INTERVAL_SECONDS", "86400")), 3600)
STORAGE_AUDIT_START_DELAY_SECONDS = max(int(env("STORAGE_AUDIT_START_DELAY_SECONDS", "60")), 10)
STORAGE_DELETION_POLL_SECONDS = max(int(env("STORAGE_DELETION_POLL_SECONDS", "30")), 5)
WORKER_HEARTBEAT_SECONDS = min(max(int(env("WORKER_HEARTBEAT_SECONDS", "30")), 10), 60)
R2_HEALTHCHECK_SECONDS = min(max(int(env("R2_HEALTHCHECK_SECONDS", "300")), 60), 1800)
WORKER_VERSION = env("RAILWAY_GIT_COMMIT_SHA", env("WORKER_VERSION", "local"))[:64]
WORKER_INSTANCE_ID = env(
    "RAILWAY_REPLICA_ID",
    env("HOSTNAME", f"worker-{WORKER_VERSION[:12]}"),
)[:200]
DOWNLOAD_ATTEMPT_TIMEOUT_SECONDS = min(max(int(env("DOWNLOAD_ATTEMPT_TIMEOUT_SECONDS", "120")), 10), 600)
YTDLP_NETWORK_TIMEOUT_SECONDS = min(max(int(env("YTDLP_NETWORK_TIMEOUT_SECONDS", "30")), 5), 120)
SPOTIFY_METADATA_TIMEOUT_SECONDS = min(
    max(
        int(
            env(
                "SPOTIFY_METADATA_TIMEOUT_SECONDS",
                env("SPOTDL_RESOLVE_TIMEOUT_SECONDS", "600"),
            )
        ),
        30,
    ),
    1800,
)
SPOTIFY_SEARCH_LIMIT = min(max(int(env("SPOTIFY_SEARCH_LIMIT", "5")), 1), 10)
REQUEST_TIMEOUT_SECONDS = min(max(int(env("REQUEST_TIMEOUT_SECONDS", "3600")), 60), 7200)
YOUTUBE_COOKIES = env("YOUTUBE_COOKIES", "")
YOUTUBE_COOKIES_FILE = env("YOUTUBE_COOKIES_FILE", "")
YOUTUBE_CANARY_URL = env("YOUTUBE_CANARY_URL", "")
# URL interna do provedor de PO Token (bgutil). Quando configurado, links
# públicos usam o token automático primeiro; cookies ficam apenas como fallback.
POT_PROVIDER_BASE_URL = env("POT_PROVIDER_BASE_URL", "").rstrip("/")
# Ordem dos "player clients" do YouTube que o yt-dlp tenta ao baixar. Alguns
# clients ficam bloqueados de tempos em tempos; tentar vários em cascata aumenta
# muito a chance de sucesso. Dá para mudar via env sem alterar o código.
_CONFIGURED_YT_PLAYER_CLIENTS = [
    c.strip()
    for c in env(
        "YT_PLAYER_CLIENTS",
        "mweb,default,android_vr,web_safari"
        if POT_PROVIDER_BASE_URL
        else "default,android_vr,mweb,web_safari,tv,ios,android,web",
    ).split(",")
    if c.strip()
]


def _ordered_unique(values: list[str]) -> list[str]:
    return list(dict.fromkeys(value for value in values if value))


# Mesmo que o Railway ainda tenha a ordem antiga gravada como variável, os dois
# fallbacks independentes permanecem garantidos e antes do web_safari.
YT_PLAYER_CLIENTS = _ordered_unique(
    (
        ["mweb", "default", "android_vr", "web_safari"]
        if POT_PROVIDER_BASE_URL
        else ["default", "android_vr", "mweb", "web_safari"]
    )
    + _CONFIGURED_YT_PLAYER_CLIENTS
)
# Substituição automática: quando uma faixa é INDISPONÍVEL de forma permanente
# (geo-bloqueio, sem formato, removida), procurar outra versão da mesma música.
ENABLE_AUTO_SUBSTITUTE = env("ENABLE_AUTO_SUBSTITUTE", "true").lower() in ("1", "true", "yes", "on")
SUBSTITUTE_SEARCH_LIMIT = int(env("SUBSTITUTE_SEARCH_LIMIT", "4"))

# Motivos PERMANENTES (não é erro de sistema; é o vídeo/faixa que não dá).
# Se só houver desses e algo tiver sido importado, o job é SUCESSO com relatório.
PERMANENT_SKIP_CODES = {
    "YOUTUBE_GEO_BLOCKED",
    "YOUTUBE_FORMAT_UNAVAILABLE",
    "PLAYLIST_PRIVATE_OR_UNAVAILABLE",
    "TRACK_SIZE_LIMIT_EXCEEDED",
    "TRACK_DURATION_LIMIT_EXCEEDED",
    "TRACK_DURATION_UNKNOWN",
    "SPOTIFY_MATCH_NOT_FOUND",
    "PLAYLIST_LIMIT_EXCEEDED",
}
# Estes erros afetam o importador inteiro, não apenas uma faixa. Continuar
# percorrendo a playlist só repete a mesma falha e deixa o job parecendo travado.
JOB_ABORT_CODES = {
    "YOUTUBE_COOKIES_MISSING",
    "YOUTUBE_COOKIES_INVALID",
    "YOUTUBE_TOKEN_PROVIDER_UNAVAILABLE",
    "YOUTUBE_EXTRACTION_DEGRADED",
    "WORKER_ENV_MISSING",
    "SUPABASE_PERMISSION_DENIED",
    "SUPABASE_ERROR",
    "R2_ACCESS_DENIED",
    "R2_ERROR",
    "SPOTIFY_METADATA_ERROR",
    "SPOTIFY_RESOLVE_TIMEOUT",
    "SPOTIFY_RESOLVER_UNAVAILABLE",
    "SPOTIFY_LINK_UNAVAILABLE",
    "IMPORTER_TRANSIENT",
}
# Erros de configuração não melhoram com retry automático. O Admin pode
# reenfileirar depois que a variável/permissão for corrigida.
NON_RETRYABLE_JOB_CODES = {
    "WORKER_ENV_MISSING",
    "SUPABASE_PERMISSION_DENIED",
    "R2_ACCESS_DENIED",
    "SPOTIFY_LINK_UNAVAILABLE",
}
SPOTIFY_TRANSIENT_JOB_CODES = {
    "SPOTIFY_METADATA_ERROR",
    "SPOTIFY_RESOLVE_TIMEOUT",
    "SPOTIFY_RESOLVER_UNAVAILABLE",
}
DELAYED_TRANSIENT_JOB_CODES = SPOTIFY_TRANSIENT_JOB_CODES | {
    "IMPORTER_TRANSIENT",
    "IMPORT_TIMEOUT",
}
YOUTUBE_CIRCUIT_CODES = {
    "YOUTUBE_COOKIES_MISSING",
    "YOUTUBE_COOKIES_INVALID",
    "YOUTUBE_TOKEN_PROVIDER_UNAVAILABLE",
    "YOUTUBE_EXTRACTION_DEGRADED",
}
TRACK_DEFER_CODES = YOUTUBE_CIRCUIT_CODES | {
    "IMPORTER_TRANSIENT",
    "IMPORT_TIMEOUT",
}
# Dos permanentes, quais vale tentar substituir por outra versão (mesma música).
SUBSTITUTABLE_CODES = {
    "YOUTUBE_GEO_BLOCKED",
    "YOUTUBE_FORMAT_UNAVAILABLE",
    "PLAYLIST_PRIVATE_OR_UNAVAILABLE",
}


def ensure_youtube_cookiefile() -> str | None:
    if YOUTUBE_COOKIES_FILE and os.path.exists(YOUTUBE_COOKIES_FILE):
        return YOUTUBE_COOKIES_FILE
    if not YOUTUBE_COOKIES.strip():
        return None
    path = os.path.join(tempfile.gettempdir(), "youtube_cookies.txt")
    if not os.path.exists(path):
        with open(path, "w", encoding="utf-8") as f:
            f.write(YOUTUBE_COOKIES)
            if not YOUTUBE_COOKIES.endswith("\n"):
                f.write("\n")
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
    return path


YOUTUBE_COOKIEFILE = ensure_youtube_cookiefile()
spotify_resolver = resolver_from_environment(
    max_tracks=MAX_TRACKS,
    timeout_seconds=min(SPOTIFY_METADATA_TIMEOUT_SECONDS, REQUEST_TIMEOUT_SECONDS),
    cookie_file=YOUTUBE_COOKIEFILE or "",
)

supabase = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

SECRET_VALUES = (
    SUPABASE_SERVICE_ROLE_KEY,
    R2_ACCESS_KEY_ID,
    R2_SECRET_ACCESS_KEY,
    env("SPOTIFY_RESOLVER_TOKEN", ""),
    YOUTUBE_COOKIES,
    POT_PROVIDER_BASE_URL,
)

s3 = boto3.client(
    "s3",
    endpoint_url=f"https://{R2_ACCOUNT_ID}.r2.cloudflarestorage.com",
    aws_access_key_id=R2_ACCESS_KEY_ID,
    aws_secret_access_key=R2_SECRET_ACCESS_KEY,
    region_name="auto",
    config=BotoConfig(
        retries={"max_attempts": 3, "mode": "standard"},
        connect_timeout=10,
        read_timeout=60,
    ),
)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def log(*args):
    safe = [redact_sensitive(arg, SECRET_VALUES) for arg in args]
    print(f"[{now_iso()}]", *safe, flush=True)


_WORKER_STATE_LOCK = threading.Lock()
_WORKER_STATE: dict = {
    "status": "starting",
    "current_job_id": None,
    "activity": "Inicializando o Worker",
    "activity_at": now_iso(),
}


def set_worker_state(status: str, activity: str, job_id: str | None = None) -> None:
    """Atualiza o estado lido pela thread de heartbeat sem bloquear o Worker."""
    with _WORKER_STATE_LOCK:
        _WORKER_STATE.update(
            status=status,
            current_job_id=job_id,
            activity=activity,
            activity_at=now_iso(),
        )


def worker_state_snapshot() -> dict:
    with _WORKER_STATE_LOCK:
        return dict(_WORKER_STATE)


def heartbeat_loop() -> None:
    """Publica vida do Worker e saude do R2 mesmo durante downloads longos."""
    heartbeat_client = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    next_r2_check_at = 0.0
    r2_status = "unknown"
    r2_checked_at: str | None = None
    r2_message: str | None = None

    while True:
        if time.monotonic() >= next_r2_check_at:
            try:
                s3.list_objects_v2(Bucket=R2_BUCKET, MaxKeys=1)
                r2_status = "healthy"
                r2_message = "Bucket acessivel pelo Worker"
            except Exception as exc:  # noqa: BLE001
                r2_status = "degraded"
                r2_message = redact_sensitive(exc, SECRET_VALUES)[:240]
            r2_checked_at = now_iso()
            next_r2_check_at = time.monotonic() + R2_HEALTHCHECK_SECONDS

        state = worker_state_snapshot()
        details = {
            "version": WORKER_VERSION,
            "instance_id": WORKER_INSTANCE_ID,
            "current_job_id": state.get("current_job_id"),
            "activity": state.get("activity"),
            "activity_at": state.get("activity_at"),
            "r2_status": r2_status,
            "r2_checked_at": r2_checked_at,
            "r2_message": r2_message,
            "poll_seconds": POLL_SECONDS,
        }
        try:
            heartbeat_client.rpc(
                "worker_record_service_heartbeat",
                {
                    "p_service_name": "railway-worker",
                    "p_status": state.get("status", "degraded"),
                    "p_details": details,
                },
            ).execute()
        except Exception as exc:  # noqa: BLE001
            log(f"Heartbeat nao publicado: {exc}")
        time.sleep(WORKER_HEARTBEAT_SECONDS)


_YOUTUBE_CIRCUIT_LOCK = threading.Lock()
_YOUTUBE_CIRCUIT_OPEN_UNTIL = 0.0
_YOUTUBE_CIRCUIT_REASON: str | None = None
_YOUTUBE_FORMAT_FAILURE_LOCK = threading.Lock()
_YOUTUBE_FORMAT_FAILURE_IDS: set[str] = set()


def record_youtube_format_failure(video_id: str) -> bool:
    """Retorna True quando vídeos distintos comprovam degradação do ambiente."""
    if not video_id:
        return False
    with _YOUTUBE_FORMAT_FAILURE_LOCK:
        _YOUTUBE_FORMAT_FAILURE_IDS.add(video_id)
        failure_count = len(_YOUTUBE_FORMAT_FAILURE_IDS)
    if failure_count >= GLOBAL_FAILURE_ABORT_THRESHOLD:
        log(
            "Falha global de formatos detectada: "
            f"{failure_count} vídeo(s) distinto(s) sem um download bem-sucedido."
        )
        return True
    return False


def reset_youtube_format_failures() -> None:
    with _YOUTUBE_FORMAT_FAILURE_LOCK:
        _YOUTUBE_FORMAT_FAILURE_IDS.clear()


def open_youtube_circuit(reason: str, seconds: int | None = None) -> None:
    """Pausa novos downloads quando o bloqueio afeta todo o IP/worker."""
    global _YOUTUBE_CIRCUIT_OPEN_UNTIL, _YOUTUBE_CIRCUIT_REASON
    open_seconds = min(max(int(seconds or YOUTUBE_CIRCUIT_OPEN_SECONDS), 60), 3600)
    with _YOUTUBE_CIRCUIT_LOCK:
        _YOUTUBE_CIRCUIT_OPEN_UNTIL = max(
            _YOUTUBE_CIRCUIT_OPEN_UNTIL,
            time.monotonic() + open_seconds,
        )
        _YOUTUBE_CIRCUIT_REASON = reason
    log(
        f"Circuit breaker do YouTube aberto por {open_seconds}s "
        f"[{reason}]."
    )


def youtube_circuit_remaining() -> tuple[int, str | None]:
    with _YOUTUBE_CIRCUIT_LOCK:
        remaining = max(0, int(_YOUTUBE_CIRCUIT_OPEN_UNTIL - time.monotonic()))
        return remaining, _YOUTUBE_CIRCUIT_REASON if remaining else None


def close_youtube_circuit() -> None:
    global _YOUTUBE_CIRCUIT_OPEN_UNTIL, _YOUTUBE_CIRCUIT_REASON
    with _YOUTUBE_CIRCUIT_LOCK:
        _YOUTUBE_CIRCUIT_OPEN_UNTIL = 0.0
        _YOUTUBE_CIRCUIT_REASON = None
    reset_youtube_format_failures()


def is_transient_transport_error(exc_or_message) -> bool:
    """Recognize network failures without conflating functional errors or 403s."""
    raw = str(exc_or_message or "").strip().lower()
    exception_names = (
        {cls.__name__.lower() for cls in type(exc_or_message).mro()}
        if isinstance(exc_or_message, Exception)
        else set()
    )
    if exception_names & {
        "connecterror",
        "networkerror",
        "readerror",
        "writeerror",
        "remoteprotocolerror",
        "transporterror",
        "connectionerror",
        "connectionreseterror",
        "connectionabortederror",
        "brokenpipeerror",
    }:
        return True
    return any(
        marker in raw
        for marker in (
            "temporary transport failure",
            "connection reset",
            "connection aborted",
            "connection closed",
            "connection refused",
            "server disconnected",
            "remote protocol error",
            "network is unreachable",
            "network error",
            "name or service not known",
            "temporary failure in name resolution",
            "service unavailable",
            "bad gateway",
            "gateway timeout",
            "http 520",
            "http 503",
            "http 502",
            "http 504",
        )
    )


def classify_error(exc_or_message, context: str | None = None) -> tuple[str, str]:
    """Converte erros técnicos em código estável + mensagem operacional."""
    raw = str(exc_or_message or "").strip()
    msg = raw.lower()

    if context == "env":
        return "WORKER_ENV_MISSING", "O serviço de importação está temporariamente indisponível."

    # Sentinelas internas do importador: comparar no texto ORIGINAL (case-sensitive).
    # Ficam no topo para não serem "engolidas" pelas regras genéricas abaixo.
    if "YOUTUBE_COOKIES_MISSING" in raw:
        return "YOUTUBE_COOKIES_MISSING", "O importador do YouTube está se recuperando automaticamente."
    if "YOUTUBE_COOKIES_INVALID" in raw:
        return "YOUTUBE_COOKIES_INVALID", "O importador do YouTube está se recuperando automaticamente."
    if "YOUTUBE_TOKEN_PROVIDER_UNAVAILABLE" in raw:
        return (
            "YOUTUBE_TOKEN_PROVIDER_UNAVAILABLE",
            "O importador do YouTube está se recuperando automaticamente.",
        )
    if "YOUTUBE_EXTRACTION_DEGRADED" in raw:
        return (
            "YOUTUBE_EXTRACTION_DEGRADED",
            "O importador do YouTube detectou uma falha global e vai retomar automaticamente.",
        )
    if "YOUTUBE_FORMAT_UNAVAILABLE" in raw:
        return (
            "YOUTUBE_FORMAT_UNAVAILABLE",
            "Falha no YouTube: nenhum formato de áudio disponível para download no ambiente do importador.",
        )
    if "IMPORTER_TRANSIENT" in raw:
        return (
            "IMPORTER_TRANSIENT",
            "O serviço de importação teve uma instabilidade de conexão e tentará novamente.",
        )
    if "TRACK_DURATION_LIMIT_EXCEEDED" in raw:
        return "TRACK_DURATION_LIMIT_EXCEEDED", "A música ultrapassa a duração máxima de 16 minutos."
    if "TRACK_SIZE_LIMIT_EXCEEDED" in raw:
        return (
            "TRACK_SIZE_LIMIT_EXCEEDED",
            f"Faixa ignorada: arquivo de áudio acima do limite de {MAX_FILE_MB:.0f} MB.",
        )
    if "TRACK_DURATION_UNKNOWN" in raw:
        return "TRACK_DURATION_UNKNOWN", "Faixa ignorada: não foi possível confirmar a duração da faixa."
    if "TRACK_NOT_AVAILABLE" in raw:
        return (
            "TRACK_NOT_AVAILABLE",
            "A versão anterior desta faixa foi removida. Tente novamente para baixar a substituta.",
        )
    if "PRINCIPAL_TRACK_LIMIT_REACHED" in raw:
        return (
            "PLAYLIST_LIMIT_EXCEEDED",
            f"Limite de {PRINCIPAL_TRACK_LIMIT} músicas da playlist principal do operador atingido.",
        )

    if "SPOTIFY_MATCH_NOT_FOUND" in raw:
        return "SPOTIFY_MATCH_NOT_FOUND", "Não foi possível localizar esta música no YouTube."
    if "SPOTIFY_LINK_UNAVAILABLE" in raw:
        return "SPOTIFY_LINK_UNAVAILABLE", "O link do Spotify não está mais disponível."
    if "SPOTIFY_RESOLVER_UNAVAILABLE" in raw:
        return "SPOTIFY_RESOLVER_UNAVAILABLE", "O serviço de importação está temporariamente indisponível."
    if "SPOTIFY_RESOLVE_TIMEOUT" in raw:
        return (
            "SPOTIFY_RESOLVE_TIMEOUT",
            "Falha ao localizar as músicas do Spotify no YouTube: tempo limite excedido.",
        )
    if "SPOTIFY_METADATA_ERROR" in raw:
        return "SPOTIFY_METADATA_ERROR", "Não foi possível ler as músicas deste link do Spotify."

    if "youtubepot-bgutilhttp" in msg and any(
        marker in msg
        for marker in (
            "connection refused",
            "failed to establish",
            "error reaching",
            "timed out",
            "timeout",
        )
    ):
        return (
            "YOUTUBE_TOKEN_PROVIDER_UNAVAILABLE",
            "O importador do YouTube está se recuperando automaticamente.",
        )

    if is_transient_transport_error(exc_or_message):
        return (
            "IMPORTER_TRANSIENT",
            "O serviço de importação teve uma instabilidade de conexão e tentará novamente.",
        )

    if "timed out" in msg or "timeout" in msg:
        return "IMPORT_TIMEOUT", "O serviço de importação está temporariamente indisponível."
    if "requested format is not available" in msg or "no video formats found" in msg:
        return (
            "YOUTUBE_FORMAT_UNAVAILABLE",
            "Falha no YouTube: nenhum formato de áudio disponível para download no ambiente do importador.",
        )
    if "your country" in msg or "not available in your country" in msg or "geo" in msg and "block" in msg:
        return (
            "YOUTUBE_GEO_BLOCKED",
            "Faixa indisponível: o vídeo tem restrição de país e não é permitido no servidor de download. "
            "Troque por outra versão da música.",
        )
    if any(p in msg for p in ("not a bot", "sign in to confirm", "confirm you’re", "confirm your age")):
        if not YOUTUBE_COOKIEFILE:
            return (
                "YOUTUBE_COOKIES_MISSING",
                "O serviço de importação está temporariamente indisponível.",
            )
        return (
            "YOUTUBE_COOKIES_INVALID",
            "O serviço de importação está temporariamente indisponível.",
        )
    if "private" in msg or "unavailable" in msg or "not available" in msg or "sign in" in msg:
        # Sem cookies num IP de datacenter (Railway), o YouTube costuma recusar o
        # download mesmo de vídeos públicos. Se não houver cookie, aponte a causa provável.
        if not YOUTUBE_COOKIEFILE:
            return (
                "YOUTUBE_COOKIES_MISSING",
                "O serviço de importação está temporariamente indisponível.",
            )
        return "PLAYLIST_PRIVATE_OR_UNAVAILABLE", "Falha ao importar: playlist privada ou indisponível."
    if "unsupported url" in msg or "invalid url" in msg or "no suitable extractor" in msg:
        return "INVALID_URL", "Link inválido ou plataforma não suportada."
    if "permission denied" in msg or "row-level security" in msg or "rls" in msg:
        return "SUPABASE_PERMISSION_DENIED", "O serviço de importação está temporariamente indisponível."
    if isinstance(exc_or_message, ClientError):
        code = exc_or_message.response.get("Error", {}).get("Code", "")
        if code in {"AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch"}:
            return "R2_ACCESS_DENIED", "O serviço de importação está temporariamente indisponível."
        return "R2_ERROR", "O serviço de importação está temporariamente indisponível."
    if "youtube" in msg or "yt_dlp" in msg or "yt-dlp" in msg:
        return "YOUTUBE_ERROR", "Falha no YouTube ao ler ou baixar a playlist."
    if "spotify" in msg or "spotdl" in msg:
        return "SPOTIFY_METADATA_ERROR", "Falha ao ler os metadados do Spotify."
    if "supabase" in msg or "postgrest" in msg or "duplicate key" in msg:
        return "SUPABASE_ERROR", "O serviço de importação está temporariamente indisponível."
    return "IMPORTER_ERROR", "O serviço de importação está temporariamente indisponível."


def error_details(exc_or_message, **context) -> dict:
    raw = redact_sensitive(exc_or_message, SECRET_VALUES)
    details = {
        "technical_summary": sanitize_text(raw, 1000),
        "context": sanitize_json({
            k: sanitize_text(v, 500)
            for k, v in context.items()
            if v is not None
        }),
    }
    if isinstance(exc_or_message, Exception):
        details["exception_type"] = exc_or_message.__class__.__name__
    return details


def remaining_request_seconds(deadline: float | None) -> int:
    if deadline is None:
        return DOWNLOAD_ATTEMPT_TIMEOUT_SECONDS
    remaining = int(deadline - time.monotonic())
    if remaining <= 0:
        raise TimeoutError(f"REQUEST_TIMEOUT: solicitação excedeu {REQUEST_TIMEOUT_SECONDS}s.")
    return min(DOWNLOAD_ATTEMPT_TIMEOUT_SECONDS, remaining)


def run_ytdlp_command(command: list[str], *, deadline: float | None = None) -> str:
    """Executa yt-dlp isoladamente para um job nunca ficar travado."""
    if not isinstance(command, list) or not command or any(not isinstance(arg, str) for arg in command):
        raise ValueError("INVALID_COMMAND_ARGUMENTS")
    timeout_seconds = remaining_request_seconds(deadline)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            output, _ = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate()
        raise TimeoutError(f"IMPORT_TIMEOUT: yt-dlp excedeu {timeout_seconds}s.")
    if process.returncode != 0:
        raise RuntimeError(
            f"yt-dlp terminou com código {process.returncode}: "
            f"{redact_sensitive(output[-500:], SECRET_VALUES)}"
        )
    return output


# --------------------------------------------------------------------------- #
# Fila de jobs
# --------------------------------------------------------------------------- #

def claim_next_job() -> dict | None:
    """Claim atômico no banco, com SKIP LOCKED e limite global entre réplicas."""
    result = supabase.rpc(
        "worker_claim_download_job",
        {"p_max_concurrent": MAX_CONCURRENT_JOBS},
    ).execute()
    if not result.data:
        return None
    return result.data[0] if isinstance(result.data, list) else result.data


def update_job(job_id: str, **fields):
    status = fields.get("status")
    if status and "operational_status" not in fields:
        fields["operational_status"] = {
            "queued": "queued",
            "running": "processing",
            "done": "completed",
            "partial": "completed_with_issues",
            "error": "failed",
        }.get(status, "queued")
    fields["updated_at"] = now_iso()
    supabase.table("download_jobs").update(fields).eq("id", job_id).execute()


def defer_youtube_job(job: dict, code: str, friendly: str, exc: Exception) -> dict:
    """Adia no banco sem gastar tentativas e compartilha o circuito entre réplicas."""
    result = supabase.rpc(
        "worker_defer_youtube_job",
        {
            "p_job_id": job["id"],
            "p_error_code": code,
            "p_error_message": friendly,
            "p_error_details": error_details(
                exc,
                job_id=job.get("id"),
                playlist_id=job.get("playlist_id"),
            ),
        },
    ).execute()
    data = result.data or {}
    if isinstance(data, list):
        data = data[0] if data else {}
    return data if isinstance(data, dict) else {}


def acquire_music_operation_slot(
    operation_kind: str,
    playlist_id: str,
    *,
    deadline: float,
    lease_seconds: int = 180,
) -> str:
    """Semáforo global no Postgres; funciona com duas ou mais réplicas."""
    owner_id = str(uuid.uuid4())
    while True:
        remaining_request_seconds(deadline)
        result = supabase.rpc(
            "worker_acquire_music_import_slot",
            {
                "p_operation_kind": operation_kind,
                "p_owner_id": owner_id,
                "p_playlist_id": playlist_id,
                "p_worker_id": WORKER_INSTANCE_ID,
                "p_lease_seconds": lease_seconds,
            },
        ).execute()
        data = result.data or {}
        if isinstance(data, list):
            data = data[0] if data else {}
        if isinstance(data, dict) and data.get("acquired"):
            return owner_id
        retry_after = max(1, min(int((data or {}).get("retry_after_seconds") or 5), 15))
        time.sleep(min(retry_after, remaining_request_seconds(deadline)))


def release_music_operation_slot(owner_id: str | None) -> None:
    if not owner_id:
        return
    try:
        supabase.rpc(
            "worker_release_music_import_slot",
            {"p_owner_id": owner_id},
        ).execute()
    except Exception as exc:  # noqa: BLE001
        log(f"Lease global {owner_id[:8]} será liberado por expiração: {exc}")


def claim_music_upload_task() -> dict | None:
    result = supabase.rpc(
        "worker_claim_music_upload_task",
        {"p_worker_id": WORKER_INSTANCE_ID, "p_lease_seconds": 900},
    ).execute()
    data = result.data
    if isinstance(data, list):
        data = data[0] if data else None
    return data if isinstance(data, dict) else None


def finish_music_upload_task(
    task_id: str,
    success: bool,
    *,
    track_id: str | None = None,
    content_sha256: str | None = None,
    error_code: str | None = None,
    error_message: str | None = None,
) -> dict:
    result = supabase.rpc(
        "worker_finish_music_upload_task",
        {
            "p_task_id": task_id,
            "p_success": success,
            "p_track_id": track_id,
            "p_content_sha256": content_sha256,
            "p_error_code": error_code,
            "p_error_message": error_message,
        },
    ).execute()
    data = result.data or {}
    if isinstance(data, list):
        data = data[0] if data else {}
    return data if isinstance(data, dict) else {}


def attach_music_upload_track(task_id: str, track_id: str) -> dict:
    result = supabase.rpc(
        "worker_attach_music_upload_track",
        {"p_task_id": task_id, "p_track_id": track_id},
    ).execute()
    data = result.data or {}
    if isinstance(data, list):
        data = data[0] if data else {}
    return data if isinstance(data, dict) else {}


def recover_stale_running_jobs():
    """Recupera jobs abandonados por restart/crash sem disputar jobs ativos."""
    cutoff = (datetime.now(timezone.utc) - timedelta(seconds=STALE_JOB_SECONDS)).isoformat()
    stale = (
        supabase.table("download_jobs")
        .select("id, attempts")
        .eq("status", "running")
        .lt("updated_at", cutoff)
        .execute()
    )
    for job in stale.data or []:
        attempts = job.get("attempts") or 0
        if attempts >= MAX_ATTEMPTS:
            update_job(
                job["id"],
                status="error",
                error="worker interrompido durante a importação",
                error_code="WORKER_STALE_TIMEOUT",
                error_message="Falha ao importar: o Worker foi interrompido durante o processamento.",
                error_details={"stale_after_seconds": STALE_JOB_SECONDS},
                last_error_at=now_iso(),
                finished_at=now_iso(),
            )
            log(f"Job {job['id']} abandonado finalizado após {attempts} tentativa(s).")
        else:
            update_job(
                job["id"],
                status="queued",
                next_attempt_at=now_iso(),
                error=None,
                error_code=None,
                error_message=None,
                error_details=None,
                last_error_at=None,
                started_at=None,
                finished_at=None,
            )
            log(f"Job {job['id']} abandonado voltou para a fila.")


def claim_storage_deletion_job() -> dict | None:
    """Obtém uma exclusão R2 já autorizada e serializada pelo banco."""
    res = supabase.rpc("claim_storage_deletion_job").execute()
    return res.data[0] if res.data else None


def complete_storage_deletion_job(job_id: str, success: bool, error: str | None = None):
    return supabase.rpc(
        "complete_storage_deletion_job",
        {"p_job_id": job_id, "p_success": success, "p_error": error},
    ).execute()


def claim_expired_music_upload_session() -> dict | None:
    result = supabase.rpc("worker_claim_expired_music_upload_session").execute()
    if not result.data:
        return None
    return result.data[0] if isinstance(result.data, list) else result.data


def complete_expired_music_upload_cleanup(
    session_id: str,
    success: bool,
    error: str | None = None,
):
    return supabase.rpc(
        "worker_complete_expired_music_upload_cleanup",
        {
            "p_session_id": session_id,
            "p_success": success,
            "p_error": sanitize_text(error, 1000) if error else None,
        },
    ).execute()


# --------------------------------------------------------------------------- #
# YouTube / download
# --------------------------------------------------------------------------- #

def list_playlist_entries(url: str) -> tuple[list[dict], list[dict]]:
    """Retorna até MAX_TRACKS entradas (id, title, duration) da playlist/vídeo."""
    parsed_source = parse_supported_music_url(url)
    if parsed_source.source != "youtube":
        raise ValueError("INVALID_URL")
    url = parsed_source.normalized_url
    opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
        "skip_download": True,
        "socket_timeout": YTDLP_NETWORK_TIMEOUT_SECONDS,
    }
    if POT_PROVIDER_BASE_URL:
        opts["extractor_args"] = {
            "youtube": {"player_client": [YT_PLAYER_CLIENTS[0]]},
            "youtubepot-bgutilhttp": {"base_url": [POT_PROVIDER_BASE_URL]},
        }
    elif YOUTUBE_COOKIEFILE:
        opts["cookiefile"] = YOUTUBE_COOKIEFILE
    try:
        with YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
    except Exception:
        if not (POT_PROVIDER_BASE_URL and YOUTUBE_COOKIEFILE):
            raise
        # Metadados privados/por idade ainda podem exigir sessão. O fallback
        # nunca recebe URL arbitrária: `url` já foi normalizada pela allowlist.
        fallback_opts = dict(opts)
        fallback_opts.pop("extractor_args", None)
        fallback_opts["cookiefile"] = YOUTUBE_COOKIEFILE
        with YoutubeDL(fallback_opts) as ydl:
            info = ydl.extract_info(url, download=False)
    entries = info.get("entries")
    if entries is None:  # link de vídeo único
        entries = [info]
    out = []
    skipped: list[dict] = []
    for source_position, e in enumerate(entries, start=1):
        if not e:
            continue
        vid = e.get("id")
        if not vid:
            continue
        item = {
            "id": vid,
            "title": sanitize_text(e.get("title") or vid),
            "artist": sanitize_text(e.get("uploader") or e.get("channel"), 200) or None,
            "duration": e.get("duration"),  # segundos, pode ser None
            "request_position": source_position,
        }
        if len(out) >= MAX_TRACKS:
            skipped.append(
                {
                    **item,
                    "youtube_id": vid,
                    "code": "PLAYLIST_LIMIT_EXCEEDED",
                    "reason": "A playlist ultrapassa o limite de 170 músicas.",
                }
            )
            continue
        out.append(
            {
                **item,
            }
        )
    return out, skipped


def music_source_from_url(url: str) -> str | None:
    try:
        return parse_supported_music_url(url).source
    except ValueError:
        return None


def list_spotify_entries(url: str) -> tuple[list[dict], list[dict]]:
    """Adapta o contrato normalizado do resolver ao importador legado."""
    parsed_source = parse_supported_music_url(url)
    if parsed_source.source != "spotify":
        raise ValueError("INVALID_URL")
    collection = spotify_resolver.resolve(parsed_source.normalized_url)
    entries: list[dict] = []
    skipped: list[dict] = []
    for track in collection.tracks:
        duration = track.durationMs / 1000 if track.durationMs is not None else None
        base_item = {
            "request_position": track.position,
            "spotify_id": track.spotifyTrackId,
            "spotify_url": track.spotifyUrl,
            "title": track.title,
            "artists": track.artists,
            "artist": ", ".join(track.artists) or None,
            "duration": duration,
            "spotify_album": track.album,
            "matched_youtube_url": track.youtubeUrl,
            "spotify_match_confidence": track.matchConfidence,
            "spotify_match_status": track.matchStatus,
            "spotify_review_reason": track.errorMessage,
        }
        if track.position > MAX_TRACKS:
            skipped.append(
                {
                    **base_item,
                    "youtube_id": track.youtubeVideoId,
                    "code": "PLAYLIST_LIMIT_EXCEEDED",
                    "reason": "A playlist ultrapassa o limite de 170 músicas.",
                }
            )
            continue
        if track.matchStatus == "resolving":
            entries.append(
                {
                    **base_item,
                    "id": None,
                    "source": "spotify",
                    "youtube_url": None,
                    "match_method": "yt_dlp_search",
                }
            )
            continue
        if track.matchStatus not in {"resolved", "review_recommended"} or not track.youtubeVideoId:
            skipped.append(
                {
                    **base_item,
                    "title": track.title[:200],
                    "duration_seconds": duration,
                    "code": "SPOTIFY_MATCH_NOT_FOUND",
                    "reason": track.errorMessage or "Não foi possível localizar esta música no YouTube.",
                }
            )
            continue
        entries.append(
            {
                **base_item,
                "id": track.youtubeVideoId,
                "source": "spotify",
                # O downloader existente recebe a URL canônica do vídeo resolvido.
                # Links do YouTube enviados diretamente seguem usando o fallback abaixo.
                "youtube_url": f"https://www.youtube.com/watch?v={track.youtubeVideoId}",
                "spotify_match_confidence": track.matchConfidence,
                "spotify_match_status": track.matchStatus,
                "match_method": "music_source_resolver",
            }
        )
    return entries, skipped


def list_source_entries(url: str) -> tuple[list[dict], list[dict]]:
    parsed = parse_supported_music_url(url)
    if parsed.source == "spotify":
        return list_spotify_entries(parsed.normalized_url)
    if parsed.source == "youtube":
        return list_playlist_entries(parsed.normalized_url)
    raise ValueError("INVALID_URL")


def spotify_snapshot_digest(entries: list[dict]) -> str | None:
    positioned_ids: list[str] = []
    for entry in sorted(
        entries,
        key=lambda item: int(item.get("request_position") or item.get("position") or 0),
    ):
        position = int(entry.get("request_position") or entry.get("position") or 0)
        spotify_id = str(
            entry.get("spotify_id") or entry.get("source_track_id") or ""
        )
        if position < 1 or not spotify_id:
            return None
        positioned_ids.append(f"{position}:{spotify_id}")
    if not positioned_ids:
        return None
    return hashlib.sha256("\n".join(positioned_ids).encode("utf-8")).hexdigest()


def persist_spotify_snapshot(
    playlist_request_id: str | None,
    entries: list[dict],
) -> None:
    if not playlist_request_id:
        return
    digest = spotify_snapshot_digest(entries)
    if not digest:
        raise RuntimeError("SPOTIFY_METADATA_ERROR: snapshot sem IDs estáveis.")
    current = (
        supabase.table("playlist_requests")
        .select("source_metadata")
        .eq("id", playlist_request_id)
        .limit(1)
        .execute()
    )
    metadata = (
        dict(current.data[0].get("source_metadata") or {})
        if current.data
        else {}
    )
    metadata["spotify_snapshot"] = {
        "resolved_at": now_iso(),
        "track_count": len(entries),
        "ordered_track_ids_sha256": digest,
        "resolver": "spotipy_free_metadata",
    }
    supabase.table("playlist_requests").update(
        {"source_metadata": sanitize_json(metadata)}
    ).eq("id", playlist_request_id).execute()


def list_request_snapshot_entries(
    playlist_request_id: str | None,
    current_job_id: str,
) -> list[dict]:
    """Retoma somente snapshot validado pertencente à mesma solicitação."""
    if not playlist_request_id:
        return []
    request_result = (
        supabase.table("playlist_requests")
        .select("source_metadata")
        .eq("id", playlist_request_id)
        .limit(1)
        .execute()
    )
    request_metadata = (
        request_result.data[0].get("source_metadata")
        if request_result.data
        else None
    )
    snapshot_metadata = (
        request_metadata.get("spotify_snapshot")
        if isinstance(request_metadata, dict)
        else None
    )
    expected_count = (
        snapshot_metadata.get("track_count")
        if isinstance(snapshot_metadata, dict)
        else None
    )
    expected_digest = (
        snapshot_metadata.get("ordered_track_ids_sha256")
        if isinstance(snapshot_metadata, dict)
        else None
    )
    if (
        not isinstance(expected_count, int)
        or expected_count < 1
        or not isinstance(expected_digest, str)
        or not re.fullmatch(r"[a-f0-9]{64}", expected_digest)
    ):
        return []
    fields = (
        "download_job_id,position,item_status,source_track_id,source_url,"
        "youtube_url,youtube_video_id,title,artists,album,duration_ms,"
        "match_confidence,error_message,updated_at"
    )
    result = (
        supabase.table("playlist_request_tracks")
        .select(fields)
        .eq("playlist_request_id", playlist_request_id)
        .execute()
    )
    rows = list(result.data or [])

    def collect_snapshots(snapshot_rows: list[dict]) -> dict[str, list[dict]]:
        collected: dict[str, list[dict]] = {}
        for row in snapshot_rows:
            snapshot_job_id = str(row.get("download_job_id") or "")
            if (
                not snapshot_job_id
                or row.get("position") is None
            ):
                continue
            collected.setdefault(snapshot_job_id, []).append(row)
        return collected

    snapshots = collect_snapshots(rows)
    if not snapshots:
        return []
    valid_snapshots = [
        items
        for items in snapshots.values()
        if len(items) == expected_count
        and spotify_snapshot_digest(items) == expected_digest
    ]
    if not valid_snapshots:
        return []
    rows = max(
        valid_snapshots,
        key=lambda items: max(str(item.get("updated_at") or "") for item in items),
    )
    entries: list[dict] = []
    for row in sorted(rows, key=lambda item: int(item["position"])):
        artists = row.get("artists") if isinstance(row.get("artists"), list) else []
        video_id = str(row.get("youtube_video_id") or "") or None
        duration_ms = row.get("duration_ms")
        entries.append(
            {
                "id": video_id,
                "youtube_url": (
                    row.get("youtube_url")
                    or (
                        f"https://www.youtube.com/watch?v={video_id}"
                        if video_id
                        else None
                    )
                ),
                "request_position": int(row["position"]),
                "spotify_id": row.get("source_track_id"),
                "spotify_url": row.get("source_url"),
                "title": sanitize_text(
                    row.get("title") or video_id or "Faixa do Spotify"
                ),
                "artists": artists,
                "artist": ", ".join(str(artist) for artist in artists if artist) or None,
                "duration": (
                    float(duration_ms) / 1000
                    if isinstance(duration_ms, (int, float))
                    else None
                ),
                "spotify_album": row.get("album"),
                "spotify_match_confidence": row.get("match_confidence"),
                "spotify_match_status": (
                    "review_recommended"
                    if row.get("item_status") == "review_recommended"
                    else ("resolved" if video_id else "resolving")
                ),
                "spotify_review_reason": row.get("error_message"),
                "match_method": "playlist_request_snapshot",
                "source": "spotify",
            }
        )
    return entries


def list_source_entries_resumable(
    url: str,
    playlist_request_id: str | None,
    job_id: str,
) -> tuple[list[dict], list[dict]]:
    try:
        return list_source_entries(url)
    except Exception as exc:  # noqa: BLE001
        source = parse_supported_music_url(url).source
        code, _ = classify_error(exc)
        if source == "spotify" and code in {
            "SPOTIFY_METADATA_ERROR",
            "SPOTIFY_RESOLVE_TIMEOUT",
            "SPOTIFY_RESOLVER_UNAVAILABLE",
        }:
            snapshot = list_request_snapshot_entries(
                playlist_request_id,
                job_id,
            )
            if snapshot:
                log(
                    f"  Spotify indisponível [{code}]; retomando snapshot "
                    f"validado com {len(snapshot)} faixa(s)."
                )
                return snapshot, []
        raise


def request_item_status_from_code(code: str | None) -> str:
    return {
        "SPOTIFY_MATCH_NOT_FOUND": "not_found",
        "PLAYLIST_LIMIT_EXCEEDED": "playlist_limit_exceeded",
        "TRACK_DURATION_LIMIT_EXCEEDED": "duration_exceeded",
        "TRACK_DURATION_UNKNOWN": "skipped",
    }.get(code or "", "failed")


RETRY_PRESERVED_ITEM_STATUSES = {
    "completed",
    "duplicate",
    "skipped",
    "not_found",
    "duration_exceeded",
    "playlist_limit_exceeded",
    "review_recommended",
}


def previous_request_items_for_retry(
    request_id: str,
    current_job_id: str,
) -> list[dict]:
    """Carrega a tentativa anterior do mesmo envio para uma retentativa aditiva."""
    jobs_result = (
        supabase.table("download_jobs")
        .select("id,mode,created_at")
        .eq("playlist_request_id", request_id)
        .neq("id", current_job_id)
        .order("created_at", desc=True)
        .limit(20)
        .execute()
    )
    jobs = jobs_result.data if isinstance(jobs_result.data, list) else []
    previous_job = next(
        (
            job
            for job in jobs
            if job.get("id")
            and (job.get("mode") or "playlist") == "playlist"
        ),
        None,
    )
    if not previous_job:
        return []

    items_result = (
        supabase.table("playlist_request_tracks")
        .select(
            "position,item_status,error_message,last_error_code,track_id,"
            "youtube_url,youtube_video_id,match_confidence,metadata"
        )
        .eq("playlist_request_id", request_id)
        .eq("download_job_id", previous_job["id"])
        .order("position")
        .execute()
    )
    return items_result.data if isinstance(items_result.data, list) else []


def sync_request_items(
    request_id: str | None,
    job_id: str,
    entries: list[dict],
    skipped: list[dict],
) -> None:
    """Sincroniza itens sem apagar progresso de uma tentativa interrompida."""
    if not request_id:
        return
    existing_result = (
        supabase.table("playlist_request_tracks")
        .select(
            "position,item_status,error_message,last_error_code,track_id,"
            "youtube_url,youtube_video_id,match_confidence,metadata"
        )
        .eq("download_job_id", job_id)
        .execute()
    )
    existing_rows = (
        existing_result.data
        if isinstance(existing_result.data, list)
        else []
    )
    if not existing_rows:
        existing_rows = previous_request_items_for_retry(request_id, job_id)
        if existing_rows:
            log(
                f"  retentativa preserva {len(existing_rows)} estado(s) "
                "da tentativa anterior"
            )
    existing = {
        int(item["position"]): item
        for item in existing_rows
        if item.get("position") is not None
    }
    rows: list[dict] = []
    for entry in entries:
        position = int(entry.get("request_position", len(rows) + 1))
        previous = existing.get(position)
        preserve_previous = bool(
            previous
            and previous.get("item_status") in RETRY_PRESERVED_ITEM_STATUSES
        )
        match_confidence = (
            previous.get("match_confidence")
            if preserve_previous
            else entry.get("spotify_match_confidence")
        )
        if match_confidence is None and previous:
            match_confidence = previous.get("match_confidence")
        match_metadata = (
            sanitize_json(previous.get("metadata") or {})
            if preserve_previous
            else sanitize_json(entry.get("_match_metadata") or {})
        )
        if not match_metadata and previous and isinstance(previous.get("metadata"), dict):
            match_metadata = previous["metadata"]
        rows.append(
            {
                "playlist_request_id": request_id,
                "download_job_id": job_id,
                "position": position,
                "item_status": previous["item_status"] if previous else (
                    "review_recommended"
                    if entry.get("spotify_match_status") == "review_recommended"
                    else (
                        "resolving"
                        if entry.get("spotify_match_status") == "resolving"
                        else "resolved"
                    )
                ),
                "source_track_id": entry.get("spotify_id"),
                "source_url": entry.get("spotify_url"),
                "youtube_url": (
                    (previous or {}).get("youtube_url")
                    if preserve_previous
                    else (
                        entry.get("youtube_url")
                        or entry.get("matched_youtube_url")
                        or ((previous or {}).get("youtube_url"))
                    )
                ),
                "youtube_video_id": (
                    (previous or {}).get("youtube_video_id")
                    if preserve_previous
                    else entry.get("id") or ((previous or {}).get("youtube_video_id"))
                ),
                "title": sanitize_text(entry.get("title")),
                "artists": sanitize_string_list(
                    entry.get("artists")
                    or ([entry["artist"]] if entry.get("artist") else [])
                ),
                "album": sanitize_text(entry.get("spotify_album"), 300) or None,
                "duration_ms": int(float(entry["duration"]) * 1000) if entry.get("duration") is not None else None,
                "match_confidence": match_confidence,
                "track_id": (previous or {}).get("track_id"),
                "last_error_code": (previous or {}).get("last_error_code"),
                "metadata": match_metadata,
                "error_message": (
                    previous.get("error_message")
                    if previous
                    else sanitize_text(entry.get("spotify_review_reason"), 1000) or None
                ),
                "updated_at": now_iso(),
            }
        )
    for entry in skipped:
        code = entry.get("code")
        position = int(entry.get("request_position", len(rows) + 1))
        previous = existing.get(position)
        preserve_previous = bool(
            previous
            and previous.get("item_status") in RETRY_PRESERVED_ITEM_STATUSES
        )
        match_confidence = (
            previous.get("match_confidence")
            if preserve_previous
            else entry.get("spotify_match_confidence")
        )
        if match_confidence is None and previous:
            match_confidence = previous.get("match_confidence")
        match_metadata = (
            sanitize_json(previous.get("metadata") or {})
            if preserve_previous
            else sanitize_json(entry.get("_match_metadata") or {})
        )
        if not match_metadata and previous and isinstance(previous.get("metadata"), dict):
            match_metadata = previous["metadata"]
        rows.append(
            {
                "playlist_request_id": request_id,
                "download_job_id": job_id,
                "position": position,
                "item_status": previous["item_status"] if previous else request_item_status_from_code(code),
                "source_track_id": entry.get("spotify_id"),
                "source_url": entry.get("spotify_url"),
                "youtube_url": (
                    (previous or {}).get("youtube_url")
                    if preserve_previous
                    else (
                        entry.get("youtube_url")
                        or entry.get("matched_youtube_url")
                        or ((previous or {}).get("youtube_url"))
                    )
                ),
                "youtube_video_id": (
                    (previous or {}).get("youtube_video_id")
                    if preserve_previous
                    else (
                        entry.get("youtube_id")
                        or entry.get("id")
                        or ((previous or {}).get("youtube_video_id"))
                    )
                ),
                "title": sanitize_text(entry.get("title")),
                "artists": sanitize_string_list(
                    entry.get("artists")
                    or ([entry["artist"]] if entry.get("artist") else [])
                ),
                "album": sanitize_text(entry.get("spotify_album"), 300) or None,
                "duration_ms": int(float(entry["duration"]) * 1000) if entry.get("duration") is not None else None,
                "match_confidence": match_confidence,
                "track_id": (previous or {}).get("track_id"),
                "last_error_code": (previous or {}).get("last_error_code"),
                "metadata": match_metadata,
                "error_message": (
                    previous.get("error_message")
                    if previous
                    else sanitize_text(entry.get("reason") or code, 1000)
                ),
                "updated_at": now_iso(),
            }
        )
    if rows:
        supabase.table("playlist_request_tracks").delete().eq(
            "playlist_request_id", request_id
        ).is_("track_id", "null").is_("download_job_id", "null").execute()
        supabase.table("playlist_request_tracks").upsert(
            rows,
            on_conflict="download_job_id,position",
        ).execute()


def claim_request_item(job_id: str, entry: dict) -> dict | None:
    result = supabase.rpc(
        "worker_claim_playlist_request_item",
        {
            "p_job_id": job_id,
            "p_position": int(entry.get("request_position") or 0),
            "p_max_attempts": TRACK_MAX_ATTEMPTS,
            "p_stale_after_seconds": STALE_JOB_SECONDS,
        },
    ).execute()
    if not result.data:
        return None
    return result.data[0] if isinstance(result.data, list) else result.data


def set_request_item_status(request_id: str | None, entry: dict, status: str, **fields) -> None:
    if not request_id:
        return
    # O snapshot de um envio guarda uma única referência para cada track. Quando
    # duas posições do Spotify resolvem para o mesmo vídeo, a segunda permanece
    # visível como duplicada, mas sem repetir o mesmo track_id no histórico.
    if status == "duplicate":
        fields.pop("track_id", None)
    payload = {"item_status": status, "locked_at": None, "updated_at": now_iso(), **fields}
    query = supabase.table("playlist_request_tracks").update(payload)
    if entry.get("_request_item_id"):
        query.eq("id", entry["_request_item_id"]).execute()
    else:
        query.eq("playlist_request_id", request_id).eq(
            "position", entry.get("request_position")
        ).execute()


def persist_request_item_match(request_id: str | None, entry: dict) -> None:
    if not request_id or not entry.get("id"):
        return
    payload = {
        "youtube_url": entry.get("youtube_url"),
        "youtube_video_id": entry.get("id"),
        "match_confidence": entry.get("spotify_match_confidence"),
        "metadata": sanitize_json(entry.get("_match_metadata") or {}),
        "error_message": sanitize_text(
            entry.get("spotify_review_reason"),
            1000,
        )
        or None,
        "updated_at": now_iso(),
    }
    query = supabase.table("playlist_request_tracks").update(payload)
    if entry.get("_request_item_id"):
        query.eq("id", entry["_request_item_id"]).execute()
    else:
        query.eq("playlist_request_id", request_id).eq(
            "position",
            entry.get("request_position"),
        ).execute()


def set_request_item_status_by_youtube_id(request_id: str | None, youtube_id: str | None, status: str, **fields) -> None:
    """Atualiza uma troca manual, que não possui a posição da lista original."""
    if not request_id or not youtube_id:
        return
    matches = (
        supabase.table("playlist_request_tracks")
        .select("id,item_status,track_id,updated_at")
        .eq("playlist_request_id", request_id)
        .eq("youtube_video_id", youtube_id)
        .order("updated_at", desc=True)
        .execute()
    )
    rows = matches.data or []
    target = next(
        (row for row in rows if row.get("item_status") == "processing"),
        rows[0] if rows else None,
    )
    if not target:
        return

    payload = {"item_status": status, "updated_at": now_iso(), **fields}
    track_id = payload.get("track_id")
    represented_elsewhere = bool(
        track_id
        and any(
            row.get("id") != target.get("id") and row.get("track_id") == track_id
            for row in rows
        )
    )
    if represented_elsewhere:
        payload.pop("track_id", None)
        if status == "completed":
            payload["item_status"] = "duplicate"
            payload["error_message"] = "Faixa já vinculada a esta playlist."

    supabase.table("playlist_request_tracks").update(payload).eq(
        "id", target["id"]
    ).execute()


def set_request_item_status_by_id(item_id: str | None, status: str, **fields) -> None:
    """Atualiza exatamente o item escolhido pelo Admin em uma troca manual."""
    if not item_id:
        return
    payload = {
        "item_status": status,
        "locked_at": None,
        "updated_at": now_iso(),
        **fields,
    }
    supabase.table("playlist_request_tracks").update(payload).eq(
        "id", item_id
    ).execute()


def reconcile_playlist_job_after_manual_item(request_id: str | None) -> None:
    """Conclui o job principal quando a remediação resolveu todos os seus itens."""
    if not request_id:
        return
    jobs = (
        supabase.table("download_jobs")
        .select("id,mode,status,created_at")
        .eq("playlist_request_id", request_id)
        .order("created_at", desc=True)
        .execute()
    )
    playlist_job = next(
        (
            job
            for job in (jobs.data or [])
            if (job.get("mode") or "playlist") == "playlist"
        ),
        None,
    )
    if not playlist_job:
        return

    items = (
        supabase.table("playlist_request_tracks")
        .select("item_status")
        .eq("playlist_request_id", request_id)
        .eq("download_job_id", playlist_job["id"])
        .execute()
    )
    statuses = [row.get("item_status") for row in (items.data or [])]
    if not statuses or any(
        item_status not in ("completed", "duplicate")
        for item_status in statuses
    ):
        return

    update_job(
        playlist_job["id"],
        status="done",
        total=len(statuses),
        completed=len(statuses),
        failed=0,
        finished_at=now_iso(),
        error=None,
        error_code=None,
        error_message=None,
        error_details=None,
        last_error_at=None,
    )


@dataclass(frozen=True)
class YoutubeDownloadStrategy:
    client: str
    use_pot_provider: bool = False
    use_cookie: bool = False

    @property
    def label(self) -> str:
        return (
            f"client={self.client} "
            f"pot={'on' if self.use_pot_provider else 'off'} "
            f"cookie={'on' if self.use_cookie else 'off'}"
        )


_POT_COMPATIBLE_CLIENTS = {"mweb", "web_safari"}
_COOKIE_INCOMPATIBLE_CLIENTS = {
    "android",
    "android_vr",
    "ios",
    "visionos",
    "tv",
    "tv_simply",
}


def youtube_download_strategies() -> list[YoutubeDownloadStrategy]:
    """Monta fallbacks públicos primeiro e cookies apenas no fim."""
    strategies = [
        YoutubeDownloadStrategy(
            client=client,
            use_pot_provider=bool(
                POT_PROVIDER_BASE_URL and client in _POT_COMPATIBLE_CLIENTS
            ),
        )
        for client in YT_PLAYER_CLIENTS
    ]
    if YOUTUBE_COOKIEFILE:
        strategies.extend(
            YoutubeDownloadStrategy(
                client=client,
                use_pot_provider=bool(
                    POT_PROVIDER_BASE_URL and client in _POT_COMPATIBLE_CLIENTS
                ),
                use_cookie=True,
            )
            for client in YT_PLAYER_CLIENTS
            if client not in _COOKIE_INCOMPATIBLE_CLIENTS
        )
    return strategies


def download_one(entry: dict, workdir: str, *, deadline: float | None = None) -> str:
    """Baixa uma faixa com fallbacks independentes de client, PO Token e cookie."""
    vid = entry["id"]
    kbps = AUDIO_BITRATE
    out_tmpl = os.path.join(workdir, f"{vid}.%(ext)s")
    safe_video = require_youtube_video_url(
        entry.get("youtube_url") or f"https://www.youtube.com/watch?v={vid}"
    )
    errors: list[tuple[YoutubeDownloadStrategy, Exception]] = []

    for strategy in youtube_download_strategies():
        # Limpa restos de tentativas anteriores para não confundir a checagem do mp3.
        for leftover in (f"{vid}.mp3", f"{vid}.webm", f"{vid}.m4a", f"{vid}.part"):
            p = os.path.join(workdir, leftover)
            if os.path.exists(p):
                try:
                    os.remove(p)
                except OSError:
                    pass
        try:
            command = [
                sys.executable, "-m", "yt_dlp", "--no-warnings", "--no-playlist",
                "--format", "bestaudio[acodec!=none]/bestaudio/best[acodec!=none]/best",
                "--output", out_tmpl, "--max-filesize", str(MAX_FILE_BYTES * 4),
                "--extract-audio", "--audio-format", "mp3", "--audio-quality", str(kbps),
                "--socket-timeout", str(YTDLP_NETWORK_TIMEOUT_SECONDS),
                "--retries", "2", "--fragment-retries", "2",
            ]
            if strategy.client.lower() != "default":
                command.extend(
                    ["--extractor-args", f"youtube:player_client={strategy.client}"]
                )
            if strategy.use_pot_provider:
                command.extend(["--extractor-args", f"youtubepot-bgutilhttp:base_url={POT_PROVIDER_BASE_URL}"])
            if strategy.use_cookie:
                command.extend(["--cookies", YOUTUBE_COOKIEFILE])
            command.append(safe_video.normalized_url)
            log(f"  > {vid} tentando {strategy.label}")
            run_ytdlp_command(command, deadline=deadline)
            mp3 = os.path.join(workdir, f"{vid}.mp3")
            if not os.path.exists(mp3):
                missing_mp3 = FileNotFoundError(
                    f"yt-dlp não gerou o mp3 para {vid} ({strategy.label})"
                )
                errors.append((strategy, missing_mp3))
                log(f"  ! {vid} {strategy.label}: {missing_mp3}")
                continue
            size = os.path.getsize(mp3)
            if size > MAX_FILE_BYTES:
                log(f"  ! {vid} passou de {MAX_FILE_MB} MB ({size/1048576:.1f} MB) — descartado")
                os.remove(mp3)
                # Limite nosso: trocar de client não muda nada, aborta já.
                raise ValueError(
                    f"TRACK_SIZE_LIMIT_EXCEEDED: {size/1048576:.1f} MB (limite {MAX_FILE_MB:.0f} MB)"
                )
            close_youtube_circuit()
            return mp3
        except ValueError:
            raise  # limites internos (tamanho) — propaga sem tentar outro client
        except Exception as exc:  # noqa: BLE001
            errors.append((strategy, exc))
            safe_error = redact_sensitive(
                exc,
                SECRET_VALUES + (POT_PROVIDER_BASE_URL,),
            )
            log(f"  ! {vid} {strategy.label}: {safe_error}")
            continue

    last_exc = errors[-1][1] if errors else RuntimeError("nenhuma estratégia disponível")
    independent_errors = [
        exc
        for strategy, exc in errors
        if strategy.client in {"default", "android_vr"}
        and not strategy.use_pot_provider
        and not strategy.use_cookie
    ]
    format_exc = (
        independent_errors[-1]
        if independent_errors
        and all(
            classify_error(exc)[0] == "YOUTUBE_FORMAT_UNAVAILABLE"
            for exc in independent_errors
        )
        else None
    )
    if format_exc is not None:
        if record_youtube_format_failure(vid):
            raise RuntimeError(
                "YOUTUBE_EXTRACTION_DEGRADED: "
                f"{GLOBAL_FAILURE_ABORT_THRESHOLD} vídeos distintos falharam sem um download bem-sucedido."
            ) from format_exc
        raise RuntimeError(
            f"YOUTUBE_FORMAT_UNAVAILABLE: nenhum formato utilizável para {vid}."
        ) from format_exc

    raise RuntimeError(
        "yt-dlp falhou ao baixar "
        f"{vid} em todas as estratégias: "
        f"{redact_sensitive(last_exc, SECRET_VALUES + (POT_PROVIDER_BASE_URL,))}"
    ) from last_exc


def _spotify_candidate_score(entry: dict, candidate: dict) -> float:
    source_title = normalise_match_text(entry.get("title"))
    candidate_title = normalise_match_text(candidate.get("title"))
    title_ratio = SequenceMatcher(None, source_title, candidate_title).ratio()
    source_title_tokens = {token for token in source_title.split() if len(token) > 2}
    candidate_tokens = {token for token in candidate_title.split() if len(token) > 2}
    token_overlap = (
        len(source_title_tokens & candidate_tokens) / len(source_title_tokens)
        if source_title_tokens
        else 0.0
    )
    title_score = max(title_ratio, token_overlap)

    source_artist = normalise_match_text(entry.get("artist"))
    candidate_blob = normalise_match_text(
        f"{candidate.get('title') or ''} "
        f"{candidate.get('uploader') or candidate.get('channel') or ''}"
    )
    artist_tokens = {token for token in source_artist.split() if len(token) > 2}
    artist_overlap = (
        len(artist_tokens & set(candidate_blob.split())) / len(artist_tokens)
        if artist_tokens
        else 0.5
    )

    source_duration = entry.get("duration")
    candidate_duration = candidate.get("duration")
    duration_score = 0.5
    if source_duration is not None and candidate_duration is not None:
        difference = abs(float(source_duration) - float(candidate_duration))
        duration_score = max(0.0, 1.0 - difference / 30.0)

    version_penalty = 0.0
    for term in VERSION_ATTENTION_TERMS:
        normalised_term = normalise_match_text(term)
        if (
            normalised_term in candidate_title
            and normalised_term not in source_title
        ):
            version_penalty = 0.25
            break

    return max(
        0.0,
        min(
            1.0,
            0.55 * title_score
            + 0.30 * artist_overlap
            + 0.15 * duration_score
            - version_penalty,
        ),
    )


def _spotify_candidate_comparison_title(entry: dict, candidate_title: str) -> str:
    comparison = normalise_match_text(candidate_title)
    artists = entry.get("artists")
    if not isinstance(artists, list):
        artists = [
            part.strip()
            for part in str(entry.get("artist") or "").split(",")
            if part.strip()
        ]
    for artist in sorted(
        (normalise_match_text(value) for value in artists),
        key=len,
        reverse=True,
    ):
        if artist:
            comparison = comparison.replace(artist, " ")
    comparison = re.sub(
        r"\b(official|oficial|audio|clipe|video|lyrics?|letra|visualizer)\b",
        " ",
        comparison,
    )
    comparison = re.sub(r"\s+", " ", comparison).strip()
    return comparison or candidate_title


def resolve_spotify_youtube_entry(
    entry: dict,
    *,
    deadline: float | None = None,
) -> dict:
    title = sanitize_text(entry.get("title"))
    if not title:
        raise RuntimeError("SPOTIFY_MATCH_NOT_FOUND")
    artists = entry.get("artists")
    artist_names = (
        sanitize_string_list(artists)
        if isinstance(artists, list)
        else sanitize_string_list(
            [
                part.strip()
                for part in str(entry.get("artist") or "").split(",")
                if part.strip()
            ]
        )
    )
    artist_query = artist_names[0] if artist_names else ""
    search_query = sanitize_text(
        f"{title} {artist_query}" if artist_query else title,
        500,
    )
    remaining_request_seconds(deadline)
    opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
        "skip_download": True,
        "socket_timeout": min(
            YTDLP_NETWORK_TIMEOUT_SECONDS,
            remaining_request_seconds(deadline),
        ),
    }
    if POT_PROVIDER_BASE_URL:
        opts["extractor_args"] = {
            "youtube": {"player_client": [YT_PLAYER_CLIENTS[0]]},
            "youtubepot-bgutilhttp": {"base_url": [POT_PROVIDER_BASE_URL]},
        }
    try:
        with YoutubeDL(opts) as ydl:
            info = ydl.extract_info(
                f"ytsearch{SPOTIFY_SEARCH_LIMIT}:{search_query}",
                download=False,
            )
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(
            f"YOUTUBE_SEARCH_ERROR: {type(exc).__name__}"
        ) from exc

    candidates = [
        candidate
        for candidate in (info.get("entries") or [])
        if isinstance(candidate, dict)
        and re.fullmatch(r"[A-Za-z0-9_-]{11}", str(candidate.get("id") or ""))
    ]
    if not candidates:
        raise RuntimeError("SPOTIFY_MATCH_NOT_FOUND")
    candidate = max(
        candidates,
        key=lambda item: _spotify_candidate_score(entry, item),
    )
    video_id = str(candidate["id"])
    confidence = round(_spotify_candidate_score(entry, candidate) * 100, 2)
    candidate_title = sanitize_text(candidate.get("title") or video_id)
    uploader = sanitize_text(
        candidate.get("uploader") or candidate.get("channel"),
        200,
    )
    candidate_blob = normalise_match_text(f"{candidate_title} {uploader}")
    source_artist_tokens = {
        token
        for token in normalise_match_text(", ".join(artist_names)).split()
        if len(token) > 2
    }
    has_artist_evidence = bool(
        source_artist_tokens & set(candidate_blob.split())
    )
    candidate_duration = candidate.get("duration")
    match_payload = {
        "youtube_title": _spotify_candidate_comparison_title(
            entry,
            candidate_title,
        ),
        "youtube_artist": (
            ", ".join(artist_names)
            if has_artist_evidence
            else uploader
        ),
        "youtube_duration": candidate_duration,
    }
    match_status, review_reason = classify_spotify_match(
        match_payload,
        title=title,
        artists=artist_names,
        duration_ms=(
            int(float(entry["duration"]) * 1000)
            if entry.get("duration") is not None
            else None
        ),
        video_id=video_id,
    )
    resolved = dict(entry)
    resolved.update(
        {
            "id": video_id,
            "youtube_url": f"https://www.youtube.com/watch?v={video_id}",
            "matched_youtube_url": f"https://www.youtube.com/watch?v={video_id}",
            "spotify_match_confidence": confidence,
            "spotify_match_status": match_status,
            "spotify_review_reason": review_reason,
            "match_method": "yt_dlp_search",
            "_match_metadata": {
                "youtube_title": candidate_title,
                "youtube_artist": uploader,
                "youtube_channel": uploader,
                "youtube_duration_ms": (
                    int(float(candidate_duration) * 1000)
                    if candidate_duration is not None
                    else None
                ),
                "duration_difference_ms": (
                    abs(
                        int(float(entry["duration"]) * 1000)
                        - int(float(candidate_duration) * 1000)
                    )
                    if entry.get("duration") is not None
                    and candidate_duration is not None
                    else None
                ),
                "match_score": confidence,
                "match_method": "yt_dlp_search",
            },
        }
    )
    return resolved


def find_alternatives(
    entry: dict,
    limit: int = SUBSTITUTE_SEARCH_LIMIT,
    *,
    deadline: float | None = None,
) -> list[dict]:
    """Busca outras versões da mesma música no YouTube (por título), casando a
    duração (±20s) para evitar pegar cover/ao vivo/errada."""
    title = (entry.get("title") or "").strip()
    if not title:
        return []
    remaining_request_seconds(deadline)
    opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
        "skip_download": True,
        "socket_timeout": min(YTDLP_NETWORK_TIMEOUT_SECONDS, remaining_request_seconds(deadline)),
    }
    if POT_PROVIDER_BASE_URL:
        opts["extractor_args"] = {
            "youtube": {"player_client": [YT_PLAYER_CLIENTS[0]]},
            "youtubepot-bgutilhttp": {"base_url": [POT_PROVIDER_BASE_URL]},
        }
    elif YOUTUBE_COOKIEFILE:
        opts["cookiefile"] = YOUTUBE_COOKIEFILE
    try:
        with YoutubeDL(opts) as ydl:
            info = ydl.extract_info(f"ytsearch{limit}:{title}", download=False)
    except Exception as exc:  # noqa: BLE001
        log(f"    busca de alternativa falhou: {exc}")
        return []
    orig = entry.get("duration")
    out: list[dict] = []
    for e in (info.get("entries") or []):
        if not e:
            continue
        vid = e.get("id")
        if not vid or vid == entry.get("id"):
            continue
        dur = e.get("duration")
        if orig and dur and abs(float(dur) - float(orig)) > 20:
            continue
        out.append({"id": vid, "title": e.get("title") or vid, "duration": dur})
    return out


def download_with_fallback(
    entry: dict,
    workdir: str,
    *,
    deadline: float | None = None,
) -> tuple[str, str, bool]:
    """Baixa a faixa; se falhar por motivo PERMANENTE (geo/formato/removida),
    tenta versões alternativas da MESMA música. Retorna (mp3, video_id_usado,
    substituida)."""
    try:
        return download_one(entry, workdir, deadline=deadline), entry["id"], False
    except ValueError:
        raise  # limite de tamanho nosso — não substitui
    except Exception as exc:  # noqa: BLE001
        code, _ = classify_error(exc)
        if not ENABLE_AUTO_SUBSTITUTE or code not in SUBSTITUTABLE_CODES:
            raise
        log(f"  ~ {entry.get('id')} indisponível ({code}); procurando outra versão...")
        for alt in find_alternatives(entry, deadline=deadline):
            alt_entry = {
                "id": alt["id"],
                "title": entry.get("title"),
                "artist": entry.get("artist"),
                "duration": alt.get("duration") or entry.get("duration"),
            }
            try:
                mp3 = download_one(alt_entry, workdir, deadline=deadline)
                log(f"    ✓ substituída por {alt['id']} ({(alt.get('title') or '')[:50]})")
                return mp3, alt["id"], True
            except Exception as exc2:  # noqa: BLE001
                alt_code, _ = classify_error(exc2)
                if alt_code in YOUTUBE_CIRCUIT_CODES:
                    raise
                log(f"    alt {alt['id']} falhou: {exc2}")
                continue
        raise exc  # nenhuma alternativa serviu — propaga o erro original (indisponível)


def download_with_global_slot(
    entry: dict,
    workdir: str,
    *,
    playlist_id: str,
    deadline: float,
) -> tuple[str, str, bool]:
    """Limita o YouTube globalmente e espaça inícios entre todas as réplicas."""
    owner_id = acquire_music_operation_slot(
        "youtube",
        playlist_id,
        deadline=deadline,
        lease_seconds=min(DOWNLOAD_ATTEMPT_TIMEOUT_SECONDS + 60, 900),
    )
    try:
        return download_with_fallback(entry, workdir, deadline=deadline)
    finally:
        release_music_operation_slot(owner_id)


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def upload_to_r2(path: str, key: str):
    s3.upload_file(path, R2_BUCKET, key, ExtraArgs={"ContentType": "audio/mpeg"})


def process_storage_deletion(job: dict):
    """Apaga o objeto; a RPC só remove o registro global após nova checagem."""
    try:
        s3.delete_object(Bucket=R2_BUCKET, Key=job["storage_object_key"])
        complete_storage_deletion_job(job["job_id"], True)
        log(f"Objeto órfão removido com segurança (job {job['job_id']}).")
    except Exception as exc:  # noqa: BLE001
        try:
            complete_storage_deletion_job(job["job_id"], False, str(exc))
        except Exception:  # noqa: BLE001
            # Se a confirmação falhar, o lock expira e o delete idempotente é repetido.
            pass
        raise


def process_expired_music_upload_cleanup(session: dict) -> None:
    """Remove staging expirado com confirmação e retry idempotente no banco."""
    try:
        s3.delete_object(
            Bucket=R2_BUCKET,
            Key=session["staging_object_key"],
        )
        complete_expired_music_upload_cleanup(session["session_id"], True)
        log(f"Staging expirado {session['session_id']} removido com segurança.")
    except Exception as exc:  # noqa: BLE001
        try:
            complete_expired_music_upload_cleanup(
                session["session_id"],
                False,
                str(exc),
            )
        except Exception:  # noqa: BLE001
            pass
        raise


def refresh_storage_sizes(audit_client=None):
    """Registra o tamanho real dos objetos R2 para o painel administrativo."""
    audit_client = audit_client or supabase
    offset = 0
    page_size = 500
    checked = 0
    while True:
        result = (
            audit_client.table("tracks")
            .select("id,storage_object_key,metadata")
            .eq("status", "available")
            .range(offset, offset + page_size - 1)
            .execute()
        )
        rows = result.data or []
        if not rows:
            break
        for track in rows:
            try:
                head = s3.head_object(Bucket=R2_BUCKET, Key=track["storage_object_key"])
                metadata = dict(track.get("metadata") or {})
                metadata["size_bytes"] = int(head["ContentLength"])
                metadata["storage_checked_at"] = now_iso()
                audit_client.table("tracks").update({"metadata": metadata}).eq("id", track["id"]).execute()
                checked += 1
            except Exception as exc:  # noqa: BLE001
                log(f"Não foi possível medir {track['storage_object_key']}: {exc}")
        if len(rows) < page_size:
            break
        offset += page_size
    log(f"Auditoria de armazenamento concluída: {checked} objeto(s) medido(s).")


def storage_audit_loop() -> None:
    """Executa a auditoria pesada em background e, por padrao, uma vez ao dia."""
    audit_client = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    time.sleep(STORAGE_AUDIT_START_DELAY_SECONDS)
    while True:
        try:
            refresh_storage_sizes(audit_client)
        except Exception as exc:  # noqa: BLE001
            log(f"Falha na auditoria de armazenamento: {exc}")
        time.sleep(STORAGE_AUDIT_INTERVAL_SECONDS)


# --------------------------------------------------------------------------- #
# Processamento de um job
# --------------------------------------------------------------------------- #

def _extract_single_video(url: str, *, deadline: float | None = None) -> dict:
    """Metadados de UM vídeo (sem expandir a playlist)."""
    safe_url = require_youtube_video_url(url)
    opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
        "socket_timeout": min(YTDLP_NETWORK_TIMEOUT_SECONDS, remaining_request_seconds(deadline)),
    }
    if YOUTUBE_COOKIEFILE:
        opts["cookiefile"] = YOUTUBE_COOKIEFILE
    with YoutubeDL(opts) as ydl:
        info = ydl.extract_info(safe_url.normalized_url, download=False)
    if info.get("entries"):
        info = info["entries"][0]
    return {
        "id": info.get("id"),
        "title": sanitize_text(info.get("title") or info.get("id")),
        "artist": sanitize_text(info.get("uploader") or info.get("channel"), 200) or None,
        "duration": info.get("duration"),
    }


def _remove_skipped_from_playlist(playlist_id: str, youtube_id: str | None):
    """Tira a faixa recém-resolvida do relatório de indisponíveis da playlist."""
    if not youtube_id:
        return
    try:
        res = supabase.table("playlists").select("error_details").eq("id", playlist_id).limit(1).execute()
        if not res.data:
            return
        details = res.data[0].get("error_details")
        if not isinstance(details, dict):
            return
        skipped = details.get("skipped")
        if not isinstance(skipped, list):
            return
        new_skipped = [s for s in skipped if s.get("youtube_id") != youtube_id]
        if len(new_skipped) == len(skipped):
            return
        if new_skipped:
            details["skipped"] = new_skipped
            if isinstance(details.get("summary"), dict):
                details["summary"]["failed"] = len(new_skipped)
            supabase.table("playlists").update({"error_details": details}).eq("id", playlist_id).execute()
        else:
            supabase.table("playlists").update({"error_details": None}).eq("id", playlist_id).execute()
    except Exception as exc:  # noqa: BLE001
        log(f"  ! não consegui atualizar o relatório da playlist: {exc}")


def process_single_track_job(job: dict, url: str):
    """Reimporta UMA faixa (troca manual) e liga na playlist, sem tocar nas demais."""
    job_id = job["id"]
    playlist_id = job["playlist_id"]
    playlist_request_id = job.get("playlist_request_id")
    playlist_request_item_id = job.get("playlist_request_item_id")
    replace_vid = job.get("replace_youtube_id")
    deadline = time.monotonic() + REQUEST_TIMEOUT_SECONDS
    safe_url = require_youtube_video_url(url).normalized_url
    log(f"Job {job_id} — troca de faixa na playlist {playlist_id}")

    try:
        with tempfile.TemporaryDirectory() as workdir:
            entry = _extract_single_video(safe_url, deadline=deadline)
            if not entry.get("id"):
                raise RuntimeError("não foi possível ler o vídeo da URL informada")

            duration_seconds = entry.get("duration")
            if duration_seconds is None:
                raise ValueError("TRACK_DURATION_UNKNOWN")
            if float(duration_seconds) > MAX_TRACK_DURATION_SECONDS:
                raise ValueError("TRACK_DURATION_LIMIT_EXCEEDED")

            vid = entry["id"]
            used_vid = vid
            key = f"tracks/{vid}.mp3"
            found = existing_available_track_by_storage_key(key)
            if found:
                track_id = found["id"]
            else:
                mp3, used_vid, substituted = download_with_global_slot(
                    entry,
                    workdir,
                    playlist_id=playlist_id,
                    deadline=deadline,
                )
                dl_key = f"tracks/{used_vid}.mp3"
                try:
                    alt_found = (
                        existing_available_track_by_storage_key(dl_key)
                        if used_vid != vid
                        else None
                    )
                    if alt_found:
                        track_id = alt_found["id"]
                    else:
                        digest = sha256_of(mp3)
                        upload_to_r2(mp3, dl_key)
                        meta = {
                            "youtube_id": used_vid,
                            "source": "youtube",
                            "source_url": f"https://www.youtube.com/watch?v={used_vid}",
                            "manual_replacement": True,
                            "size_bytes": os.path.getsize(mp3),
                            "storage_checked_at": now_iso(),
                        }
                        if substituted:
                            meta["substituted_from"] = vid
                        if R2_PUBLIC_BASE_URL:
                            meta["public_url"] = f"{R2_PUBLIC_BASE_URL}/{dl_key}"
                        dur_ms = int(float(duration_seconds) * 1000)
                        track = supabase.table("tracks").upsert(
                            {
                                "title": entry["title"][:300],
                                "artist": entry.get("artist") or None,
                                "duration_ms": dur_ms,
                                "storage_object_key": dl_key,
                                "content_hash": digest,
                                "mime_type": "audio/mpeg",
                                "status": "available",
                                "metadata": sanitize_json(meta),
                            },
                            on_conflict="storage_object_key",
                        ).execute()
                        track_id = track.data[0]["id"]
                finally:
                    if os.path.exists(mp3):
                        os.remove(mp3)

            if playlist_request_item_id:
                replace_playlist_request_track(job_id, track_id, used_vid)
            else:
                # Backward compatibility for jobs created before request items
                # were bound explicitly. New jobs use the atomic RPC above.
                pos_res = (
                    supabase.table("playlist_tracks")
                    .select("position")
                    .eq("playlist_id", playlist_id)
                    .order("position", desc=True)
                    .limit(1)
                    .execute()
                )
                next_pos = ((pos_res.data[0]["position"] if pos_res.data else 0) or 0) + 1
                supabase.table("playlist_tracks").upsert(
                    {
                        "playlist_id": playlist_id,
                        "track_id": track_id,
                        "position": next_pos,
                        "added_by_type": "system",
                    },
                    on_conflict="playlist_id,track_id",
                ).execute()

            _remove_skipped_from_playlist(playlist_id, replace_vid)

            update_job(
                job_id,
                status="done",
                total=1,
                completed=1,
                failed=0,
                finished_at=now_iso(),
                error=None,
                error_code=None,
                error_message=None,
                error_details=None,
                last_error_at=None,
            )
            if not playlist_request_item_id:
                set_request_item_status_by_youtube_id(
                    playlist_request_id,
                    used_vid,
                    "completed",
                    track_id=track_id,
                    error_message=None,
                )
            reconcile_playlist_job_after_manual_item(playlist_request_id)
            log(f"Job {job_id} — faixa trocada com sucesso ({entry['title'][:60]})")
    except Exception as exc:  # noqa: BLE001
        code, friendly = classify_error(exc)
        if code in YOUTUBE_CIRCUIT_CODES:
            if playlist_request_item_id:
                set_request_item_status_by_id(
                    playlist_request_item_id,
                    "resolved",
                    error_message=friendly[:1000],
                    last_error_code=code,
                )
            else:
                set_request_item_status_by_youtube_id(
                    playlist_request_id,
                    require_youtube_video_url(safe_url).resource_id,
                    "resolved",
                    error_message=friendly[:1000],
                    last_error_code=code,
                )
            raise
        update_job(
            job_id,
            status="error",
            total=1,
            completed=0,
            failed=1,
            finished_at=now_iso(),
            error=redact_sensitive(exc, SECRET_VALUES),
            error_code=code,
            error_message=friendly,
            error_details=error_details(exc, playlist_id=playlist_id, job_id=job_id, url=url),
            last_error_at=now_iso(),
        )
        if playlist_request_item_id:
            set_request_item_status_by_id(
                playlist_request_item_id,
                request_item_status_from_code(code),
                error_message=friendly[:1000],
                last_error_code=code,
            )
        else:
            set_request_item_status_by_youtube_id(
                playlist_request_id,
                require_youtube_video_url(safe_url).resource_id,
                request_item_status_from_code(code),
                error_message=friendly[:1000],
                last_error_code=code,
            )
        log(f"Job {job_id} — troca de faixa falhou [{code}]: {exc}")


def current_request_item(job_id: str, entry: dict) -> dict | None:
    result = (
        supabase.table("playlist_request_tracks")
        .select(
            "id,item_status,attempts,last_error_code,error_message,track_id,"
            "youtube_url,youtube_video_id,match_confidence,metadata"
        )
        .eq("download_job_id", job_id)
        .eq("position", int(entry.get("request_position") or 0))
        .limit(1)
        .execute()
    )
    return result.data[0] if result.data else None


def existing_track_for_spotify_id(spotify_id: str | None) -> dict | None:
    if not spotify_id:
        return None
    result = (
        supabase.table("tracks")
        .select("id,storage_object_key,metadata")
        .eq("metadata->>spotify_id", spotify_id)
        .eq("status", "available")
        .limit(1)
        .execute()
    )
    return result.data[0] if result.data else None


def existing_available_track_by_storage_key(storage_object_key: str) -> dict | None:
    if not storage_object_key:
        return None
    result = (
        supabase.table("tracks")
        .select("id")
        .eq("storage_object_key", storage_object_key)
        .eq("status", "available")
        .limit(1)
        .execute()
    )
    return result.data[0] if result.data else None


def replace_playlist_request_track(
    job_id: str,
    track_id: str,
    youtube_video_id: str,
) -> dict | None:
    result = supabase.rpc(
        "worker_replace_playlist_request_track",
        {
            "p_job_id": job_id,
            "p_track_id": track_id,
            "p_youtube_video_id": youtube_video_id,
        },
    ).execute()
    return result.data if isinstance(result.data, dict) else None


def principal_playlist_remaining_slots(playlist_id: str) -> int | None:
    """Retorna as vagas da playlist principal; secundarias nao usam esse teto."""
    playlist_result = (
        supabase.table("playlists")
        .select("type")
        .eq("id", playlist_id)
        .limit(1)
        .execute()
    )
    if not playlist_result.data:
        raise RuntimeError("PLAYLIST_NOT_FOUND")
    if playlist_result.data[0].get("type") != "principal":
        return None

    count_result = (
        supabase.table("playlist_tracks")
        .select("track_id", count="exact", head=True)
        .eq("playlist_id", playlist_id)
        .execute()
    )
    current_count = int(count_result.count or 0)
    return max(PRINCIPAL_TRACK_LIMIT - current_count, 0)


def playlist_limit_skip(entry: dict) -> dict:
    return {
        "youtube_id": entry.get("id"),
        "spotify_id": entry.get("spotify_id"),
        "spotify_url": entry.get("spotify_url"),
        "title": (entry.get("title") or entry.get("id") or "")[:200],
        "duration_seconds": entry.get("duration"),
        "code": "PLAYLIST_LIMIT_EXCEEDED",
        "reason": (
            f"Limite de {PRINCIPAL_TRACK_LIMIT} músicas da playlist "
            "principal do operador atingido."
        ),
    }


def mark_entries_outside_principal_limit(
    job_id: str,
    entries: list[dict],
) -> list[dict]:
    """Fecha em lote os itens que nao devem mais chegar ao downloader."""
    if not entries:
        return []

    positions = [
        int(entry.get("request_position") or 0)
        for entry in entries
        if int(entry.get("request_position") or 0) > 0
    ]
    payload = {
        "item_status": "playlist_limit_exceeded",
        "locked_at": None,
        "last_error_code": "PLAYLIST_LIMIT_EXCEEDED",
        "error_message": (
            f"Limite de {PRINCIPAL_TRACK_LIMIT} músicas da playlist "
            "principal do operador atingido."
        ),
        "updated_at": now_iso(),
    }
    for offset in range(0, len(positions), 100):
        (
            supabase.table("playlist_request_tracks")
            .update(payload)
            .eq("download_job_id", job_id)
            .in_("position", positions[offset : offset + 100])
            .execute()
        )
    return [playlist_limit_skip(entry) for entry in entries]


def current_job_request_item_statuses(job_id: str) -> dict[int, str]:
    result = (
        supabase.table("playlist_request_tracks")
        .select("position,item_status")
        .eq("download_job_id", job_id)
        .execute()
    )
    if not isinstance(result.data, list):
        return {}
    return {
        int(row["position"]): str(row.get("item_status") or "")
        for row in result.data
        if row.get("position") is not None
    }


def process_playlist_entry(
    *,
    job_id: str,
    playlist_id: str,
    playlist_request_id: str | None,
    entry: dict,
    source_url: str,
    deadline: float,
) -> dict:
    """Processa uma faixa com claim idempotente e no máximo duas tentativas."""
    while True:
        remaining_request_seconds(deadline)
        claimed = claim_request_item(job_id, entry) if playlist_request_id else {
            "id": None,
            "attempts": int(entry.get("_local_attempts") or 0) + 1,
        }
        if not claimed:
            current = current_request_item(job_id, entry)
            status = (current or {}).get("item_status", "skipped")
            code = (current or {}).get("last_error_code")
            reason = (current or {}).get("error_message")
            result = {
                "status": status,
                "attempts": int((current or {}).get("attempts") or 0),
                "reused": False,
                "abort": False,
            }
            current_metadata = (current or {}).get("metadata")
            if isinstance(current_metadata, dict) and isinstance(
                current_metadata.get("last_error_details"),
                dict,
            ):
                result["technical"] = current_metadata["last_error_details"]
            if status not in ("completed", "duplicate", "review_recommended"):
                result.update(
                    {
                        "code": code,
                        "reason": reason,
                        "skipped": {
                            "youtube_id": entry.get("id") or (current or {}).get("youtube_video_id"),
                            "spotify_id": entry.get("spotify_id"),
                            "spotify_url": entry.get("spotify_url"),
                            "title": (entry.get("title") or entry.get("id") or "")[:200],
                            "duration_seconds": entry.get("duration"),
                            "code": code,
                            "reason": reason,
                        },
                    }
                )
            return result

        work_entry = dict(entry)
        work_entry["_request_item_id"] = claimed.get("id")
        work_entry["_local_attempts"] = claimed.get("attempts")
        vid = str(
            work_entry.get("id")
            or work_entry.get("spotify_id")
            or f"position-{work_entry.get('request_position') or 0}"
        )
        used_vid = vid
        duration_seconds = work_entry.get("duration")
        try:
            if work_entry.get("source") == "spotify" and not work_entry.get("id"):
                existing_spotify_track = existing_track_for_spotify_id(
                    work_entry.get("spotify_id")
                )
                if existing_spotify_track:
                    track_id = existing_spotify_track["id"]
                    already_linked = (
                        supabase.table("playlist_tracks")
                        .select("track_id")
                        .eq("playlist_id", playlist_id)
                        .eq("track_id", track_id)
                        .limit(1)
                        .execute()
                    )
                    status = "duplicate" if already_linked.data else "completed"
                    if not already_linked.data:
                        supabase.table("playlist_tracks").upsert(
                            {
                                "playlist_id": playlist_id,
                                "track_id": track_id,
                                "position": int(
                                    work_entry.get("request_position") or 0
                                ),
                                "added_by_type": "system",
                            },
                            on_conflict="playlist_id,track_id",
                        ).execute()
                    storage_key = str(
                        existing_spotify_track.get("storage_object_key") or ""
                    )
                    video_match = re.fullmatch(
                        r"tracks/([A-Za-z0-9_-]{11})\.mp3",
                        storage_key,
                    )
                    youtube_id = video_match.group(1) if video_match else None
                    set_request_item_status(
                        playlist_request_id,
                        work_entry,
                        status,
                        track_id=track_id,
                        youtube_video_id=youtube_id,
                        youtube_url=(
                            f"https://www.youtube.com/watch?v={youtube_id}"
                            if youtube_id
                            else None
                        ),
                        metadata={
                            "match_method": "existing_spotify_id",
                            "storage_object_key": storage_key,
                        },
                        error_message=(
                            "Faixa já vinculada a esta playlist."
                            if status == "duplicate"
                            else None
                        ),
                    )
                    return {
                        "status": status,
                        "reused": True,
                        "abort": False,
                    }
                work_entry = resolve_spotify_youtube_entry(
                    work_entry,
                    deadline=deadline,
                )
                persist_request_item_match(playlist_request_id, work_entry)
                if work_entry.get("spotify_match_status") == "review_recommended":
                    set_request_item_status(
                        playlist_request_id,
                        work_entry,
                        "review_recommended",
                        youtube_url=work_entry.get("youtube_url"),
                        youtube_video_id=work_entry.get("id"),
                        match_confidence=work_entry.get(
                            "spotify_match_confidence"
                        ),
                        metadata=sanitize_json(
                            work_entry.get("_match_metadata") or {}
                        ),
                        error_message=work_entry.get(
                            "spotify_review_reason"
                        ),
                    )
                    return {
                        "status": "review_recommended",
                        "reused": False,
                        "abort": False,
                    }

            vid = work_entry["id"]
            used_vid = vid
            duration_seconds = work_entry.get("duration")
            key = f"tracks/{vid}.mp3"
            if duration_seconds is None:
                raise ValueError("TRACK_DURATION_UNKNOWN")
            if float(duration_seconds) > MAX_TRACK_DURATION_SECONDS:
                raise ValueError("TRACK_DURATION_LIMIT_EXCEEDED")

            found = None
            if work_entry.get("spotify_id"):
                found = (
                    supabase.table("tracks")
                    .select("id")
                    .eq("metadata->>spotify_id", work_entry["spotify_id"])
                    .eq("status", "available")
                    .limit(1)
                    .execute()
                )
            if not found or not found.data:
                found_by_key = existing_available_track_by_storage_key(key)
            else:
                found_by_key = found.data[0]
            reused = bool(found_by_key)
            if found_by_key:
                track_id = found_by_key["id"]
            else:
                with tempfile.TemporaryDirectory(prefix=f"ptm-{vid}-") as workdir:
                    mp3, used_vid, substituted = download_with_global_slot(
                        work_entry,
                        workdir,
                        playlist_id=playlist_id,
                        deadline=deadline,
                    )
                    dl_key = f"tracks/{used_vid}.mp3"
                    try:
                        alt_found = (
                            existing_available_track_by_storage_key(dl_key)
                            if used_vid != vid
                            else None
                        )
                        if alt_found:
                            track_id = alt_found["id"]
                            reused = True
                        else:
                            digest = sha256_of(mp3)
                            upload_to_r2(mp3, dl_key)
                            meta = {
                                "youtube_id": used_vid,
                                "source": "youtube",
                                "source_url": f"https://www.youtube.com/watch?v={used_vid}",
                                "size_bytes": os.path.getsize(mp3),
                                "storage_checked_at": now_iso(),
                            }
                            if work_entry.get("source") == "spotify":
                                meta.update(
                                    {
                                        "requested_source": "spotify",
                                        "spotify_id": work_entry.get("spotify_id"),
                                        "spotify_url": work_entry.get("spotify_url"),
                                        "spotify_album": work_entry.get("spotify_album"),
                                        "spotify_match_method": work_entry.get("match_method") or "yt_dlp_search",
                                        "spotify_matched_youtube_url": work_entry.get("matched_youtube_url"),
                                        "spotify_match_confidence": work_entry.get("spotify_match_confidence"),
                                        "spotify_match_status": work_entry.get("spotify_match_status"),
                                        "spotify_review_reason": work_entry.get("spotify_review_reason"),
                                    }
                                )
                            if substituted:
                                meta["substituted_from"] = vid
                            if R2_PUBLIC_BASE_URL:
                                meta["public_url"] = f"{R2_PUBLIC_BASE_URL}/{dl_key}"
                            track = (
                                supabase.table("tracks")
                                .upsert(
                                    {
                                        "title": work_entry["title"][:300],
                                        "artist": work_entry.get("artist") or None,
                                        "duration_ms": int(float(duration_seconds) * 1000),
                                        "storage_object_key": dl_key,
                                        "content_hash": digest,
                                        "mime_type": "audio/mpeg",
                                        "status": "available",
                                        "metadata": sanitize_json(meta),
                                    },
                                    on_conflict="storage_object_key",
                                )
                                .execute()
                            )
                            track_id = track.data[0]["id"]
                    finally:
                        if os.path.exists(mp3):
                            os.remove(mp3)

            already_linked = (
                supabase.table("playlist_tracks")
                .select("track_id")
                .eq("playlist_id", playlist_id)
                .eq("track_id", track_id)
                .limit(1)
                .execute()
            )
            if already_linked.data:
                set_request_item_status(
                    playlist_request_id,
                    work_entry,
                    "duplicate",
                    track_id=track_id,
                    error_message="Faixa já vinculada a esta playlist.",
                )
                return {"status": "duplicate", "reused": True, "abort": False}

            supabase.table("playlist_tracks").upsert(
                {
                    "playlist_id": playlist_id,
                    "track_id": track_id,
                    "position": int(work_entry.get("request_position") or 0),
                    "added_by_type": "system",
                },
                on_conflict="playlist_id,track_id",
            ).execute()
            set_request_item_status(
                playlist_request_id,
                work_entry,
                "completed",
                track_id=track_id,
                error_message=None,
                last_error_code=None,
            )
            return {"status": "completed", "reused": reused, "abort": False}
        except Exception as exc:  # noqa: BLE001
            code, friendly = classify_error(exc)
            attempts = int(claimed.get("attempts") or 1)
            technical = error_details(
                exc,
                playlist_id=playlist_id,
                job_id=job_id,
                track_id=work_entry.get("id"),
                url=source_url,
            )
            item_metadata = dict(claimed.get("metadata") or {})
            item_metadata.update(
                sanitize_json(work_entry.get("_match_metadata") or {})
            )
            item_metadata["last_error_details"] = technical
            status_fields = {
                "error_message": friendly[:1000],
                "last_error_code": code,
                "metadata": sanitize_json(item_metadata),
            }
            if work_entry.get("id"):
                status_fields["youtube_video_id"] = work_entry.get("id")
                if work_entry.get("youtube_url"):
                    status_fields["youtube_url"] = work_entry.get("youtube_url")
                if work_entry.get("spotify_match_confidence") is not None:
                    status_fields["match_confidence"] = work_entry.get(
                        "spotify_match_confidence"
                    )

            # Falhas globais/transitórias não são falha da música. Devolve o
            # item ao estado retomável, sem consumir tentativa, e adia o job.
            if code in TRACK_DEFER_CODES:
                set_request_item_status(
                    playlist_request_id,
                    work_entry,
                    "resolved" if work_entry.get("id") else "resolving",
                    attempts=max(attempts - 1, 0),
                    **status_fields,
                )
                if code in YOUTUBE_CIRCUIT_CODES:
                    open_youtube_circuit(code)
                return {
                    "status": "deferred",
                    "code": code,
                    "reason": friendly,
                    "abort": True,
                    "reused": False,
                    "technical": technical,
                }

            item_status = request_item_status_from_code(code)
            set_request_item_status(
                playlist_request_id,
                work_entry,
                item_status,
                **status_fields,
            )
            abort = code in JOB_ABORT_CODES
            permanent = code in PERMANENT_SKIP_CODES
            if abort or permanent or attempts >= TRACK_MAX_ATTEMPTS:
                log(
                    f"  faixa {vid} encerrada [{code}] na tentativa {attempts}: "
                    f"{type(exc).__name__}: {exc}"
                )
                return {
                    "status": item_status,
                    "code": code,
                    "reason": friendly,
                    "abort": abort,
                    "reused": False,
                    "skipped": {
                        "youtube_id": work_entry.get("id"),
                        "spotify_id": work_entry.get("spotify_id"),
                        "spotify_url": work_entry.get("spotify_url"),
                        "title": (work_entry.get("title") or work_entry.get("id") or "")[:200],
                        "duration_seconds": duration_seconds,
                        "code": code,
                        "reason": friendly,
                    },
                    "technical": technical,
                }
            log(
                f"  retry {vid} falhou [{code}] na tentativa {attempts}; "
                f"nova tentativa será feita: {type(exc).__name__}: {exc}"
            )
            entry["_local_attempts"] = attempts


def process_job(job: dict):
    job_id = job["id"]
    playlist_id = job["playlist_id"]
    url = job.get("source_url")
    deadline = time.monotonic() + REQUEST_TIMEOUT_SECONDS
    log(f"Job {job_id} — playlist {playlist_id}")

    if not url:
        update_job(
            job_id,
            status="error",
            error="sem source_url",
            error_code="INVALID_URL",
            error_message="Link inválido ou plataforma não suportada.",
            error_details=error_details("sem source_url", playlist_id=playlist_id, job_id=job_id),
            last_error_at=now_iso(),
            finished_at=now_iso(),
        )
        return

    if job.get("mode") == "single_track":
        return process_single_track_job(job, url)

    safe_source = parse_supported_music_url(url)
    url = safe_source.normalized_url
    playlist_request_id = job.get("playlist_request_id")

    # Retomadas são estritamente aditivas: vínculos existentes nunca são apagados.
    # O upsert por playlist/faixa reaproveita o que já estiver no banco/R2.
    entries, skipped = list_source_entries_resumable(
        url,
        playlist_request_id,
        job_id,
    )
    remaining_request_seconds(deadline)
    sync_request_items(playlist_request_id, job_id, entries, skipped)
    if safe_source.source == "spotify":
        persist_spotify_snapshot(playlist_request_id, entries + skipped)
    total = len(entries) + len(skipped)
    item_statuses = (
        current_job_request_item_statuses(job_id)
        if playlist_request_id
        else {}
    )
    review_positions = {
        position
        for position, status in item_statuses.items()
        if status == "review_recommended"
    }
    review_pending = len(review_positions) + sum(
        1
        for entry in entries
        if entry.get("spotify_match_status") == "review_recommended"
        and int(entry.get("request_position") or 0) not in item_statuses
    )
    completed_positions = {
        position
        for position, status in item_statuses.items()
        if status in ("completed", "duplicate")
    }
    update_job(
        job_id,
        total=total,
        completed=len(completed_positions),
        failed=len(skipped),
    )
    log(
        f"  {total} faixas na fila (limite {MAX_TRACKS}); "
        f"{review_pending} aguardando revisão"
    )

    if total == 0:
        source = parse_supported_music_url(url).source
        empty_code = "SPOTIFY_PLAYLIST_EMPTY" if source == "spotify" else "PLAYLIST_EMPTY"
        empty_message = (
            "A playlist do Spotify não possui músicas disponíveis."
            if source == "spotify"
            else "A playlist não possui músicas disponíveis."
        )
        update_job(
            job_id,
            status="error",
            error="playlist vazia",
            error_code=empty_code,
            error_message=empty_message,
            error_details=error_details("playlist vazia", playlist_id=playlist_id, job_id=job_id, url=url),
            last_error_at=now_iso(),
            finished_at=now_iso(),
        )
        return

    completed = len(completed_positions)
    failed = len(skipped)
    first_error_code = skipped[0].get("code") if skipped else None
    first_error_message = skipped[0].get("reason") if skipped else None
    first_error_details = {"source_url": url, "track": skipped[0]} if skipped else None
    reused = 0
    item_statuses = (
        current_job_request_item_statuses(job_id)
        if playlist_request_id
        else {}
    )
    completed_positions = {
        position
        for position, status in item_statuses.items()
        if status in ("completed", "duplicate")
    }
    completed = len(completed_positions)
    already_limited_entries = [
        entry
        for entry in entries
        if item_statuses.get(int(entry.get("request_position") or 0))
        == "playlist_limit_exceeded"
    ]
    if already_limited_entries:
        resumed_limit_skips = [
            playlist_limit_skip(entry)
            for entry in already_limited_entries
        ]
        skipped.extend(resumed_limit_skips)
        failed += len(resumed_limit_skips)
    non_processable_statuses = {
        "completed",
        "duplicate",
        "not_found",
        "duration_exceeded",
        "playlist_limit_exceeded",
        "skipped",
        "review_recommended",
    }
    eligible_entries = [
        entry for entry in entries
        if entry.get("spotify_match_status") != "review_recommended"
        and item_statuses.get(
            int(entry.get("request_position") or 0)
        ) not in non_processable_statuses
    ]
    remaining_slots = principal_playlist_remaining_slots(playlist_id)
    if remaining_slots is not None:
        log(
            f"  playlist principal com {remaining_slots} vaga(s) restante(s) "
            f"de {PRINCIPAL_TRACK_LIMIT}"
        )
    abort_result = None
    next_entry_index = 0
    with ThreadPoolExecutor(
        max_workers=TRACK_CONCURRENCY,
        thread_name_prefix="ptm-track",
    ) as executor:
        futures: dict = {}

        def schedule_available_entries() -> None:
            nonlocal next_entry_index
            available_workers = TRACK_CONCURRENCY - len(futures)
            if remaining_slots is not None:
                # Cada tarefa em andamento pode ocupar uma vaga. Reservar esse
                # espaço impede baixar além do teto mesmo com concorrência > 1.
                available_workers = min(
                    available_workers,
                    max(remaining_slots - len(futures), 0),
                )
            while (
                available_workers > 0
                and next_entry_index < len(eligible_entries)
                and abort_result is None
            ):
                entry = eligible_entries[next_entry_index]
                next_entry_index += 1
                future = executor.submit(
                    process_playlist_entry,
                    job_id=job_id,
                    playlist_id=playlist_id,
                    playlist_request_id=playlist_request_id,
                    entry=entry,
                    source_url=url,
                    deadline=deadline,
                )
                futures[future] = entry
                available_workers -= 1

        schedule_available_entries()
        while futures:
            done, _ = wait(tuple(futures), return_when=FIRST_COMPLETED)
            for future in done:
                futures.pop(future, None)
                if future.cancelled():
                    continue
                result = future.result()
                status = result.get("status")
                if status in ("completed", "duplicate"):
                    completed += 1
                    reused += int(bool(result.get("reused")))
                elif status == "review_recommended":
                    review_pending += 1
                elif status not in ("review_recommended", "deferred"):
                    failed += 1
                if remaining_slots is not None:
                    if status == "completed":
                        # Recontar evita consumir vaga duas vezes ao retomar um
                        # item que já estava concluído antes do restart.
                        remaining_slots = principal_playlist_remaining_slots(
                            playlist_id
                        )
                    elif result.get("code") == "PLAYLIST_LIMIT_EXCEEDED":
                        remaining_slots = 0
                if result.get("skipped"):
                    skipped.append(result["skipped"])
                if first_error_code is None and result.get("code"):
                    first_error_code = result["code"]
                    first_error_message = result.get("reason")
                    first_error_details = result.get("technical")
                update_job(job_id, completed=completed, failed=failed, locked_at=now_iso())
                log(
                    f"  progresso {completed + failed}/{total}: "
                    f"{completed} concluída(s), {failed} não concluída(s)"
                )
                if result.get("abort") and abort_result is None:
                    abort_result = result
                    for pending in futures:
                        pending.cancel()
            schedule_available_entries()

    if abort_result:
        raise RuntimeError(
            f"{abort_result.get('code')}: {abort_result.get('reason')}"
        )

    if remaining_slots == 0 and next_entry_index < len(eligible_entries):
        outside_limit = eligible_entries[next_entry_index:]
        limit_skips = mark_entries_outside_principal_limit(job_id, outside_limit)
        skipped.extend(limit_skips)
        failed += len(limit_skips)
        update_job(job_id, completed=completed, failed=failed, locked_at=now_iso())
        log(
            f"  limite de {PRINCIPAL_TRACK_LIMIT} atingido; "
            f"{len(limit_skips)} faixa(s) encerrada(s) sem download"
        )

    # Falha permanente ("indisponível") NÃO é erro de sistema. Se o que dava pra
    # importar foi importado e só sobraram indisponíveis, o job é SUCESSO com um
    # relatório — não uma "falha" vermelha no admin.
    skipped_codes = [s.get("code") for s in skipped]
    excluded_by_limit = sum(1 for code in skipped_codes if code == "PLAYLIST_LIMIT_EXCEEDED")
    has_real_error = any(c not in PERMANENT_SKIP_CODES for c in skipped_codes)
    only_unavailable = failed > 0 and not has_real_error

    if review_pending > 0:
        final_status = "partial"
    elif failed == 0:
        final_status = "done"
    elif only_unavailable:
        final_status = "done"      # importou tudo que era possível; resto é indisponível
    elif completed > 0:
        final_status = "partial"   # erro real de sistema + algo importado
    else:
        final_status = "error"     # nada importado

    final_error_code = None
    final_error_message = None
    if review_pending > 0:
        final_error_code = "REVIEW_RECOMMENDED"
        final_error_message = (
            f"{review_pending} música(s) aguardando revisão do resultado do YouTube."
        )
    elif failed > 0 and final_status != "done":
        final_error_code = "PARTIAL_IMPORT_FAILED" if completed > 0 else (first_error_code or "NO_TRACKS_DOWNLOADED")
        final_error_message = (
            f"A solicitação foi concluída parcialmente: {completed} músicas concluídas e {failed} não concluídas."
            if completed > 0
            else (first_error_message or "Nenhuma música foi baixada da playlist.")
        )
    elif (
        final_status == "done"
        and excluded_by_limit > 0
        and excluded_by_limit == failed
    ):
        final_error_code = "PLAYLIST_LIMIT_REACHED"
        final_error_message = (
            f"Limite de {PRINCIPAL_TRACK_LIMIT} músicas da playlist principal "
            "do operador atingido; nenhuma faixa adicional será baixada."
        )
    elif final_status == "done" and failed > 0:
        # Sucesso COM indisponíveis: informativo, não é falha.
        final_error_code = "IMPORTED_WITH_UNAVAILABLE"
        final_error_message = f"{completed} músicas importadas; {failed} indisponível(is) ou não localizada(s)."

    # Guarda o relatório sempre que algo tiver sido pulado, mesmo em sucesso,
    # para o admin exibir os indisponíveis de forma neutra.
    report_details = None
    if failed > 0 or review_pending > 0:
        report_details = {
            "summary": {
                "playlist_id": playlist_id,
                "job_id": job_id,
                "source_url": url,
                "total": total,
                "completed": completed,
                "failed": failed,
                "review_pending": review_pending,
                "excluded_by_limit": excluded_by_limit,
                "unavailable_only": only_unavailable,
            },
            # Relatório por-música consumido pelo Admin (sem stack sensível).
            "skipped": skipped,
            "first_error": first_error_details,
        }

    update_job(
        job_id,
        status=final_status,
        completed=completed,
        failed=failed,
        finished_at=now_iso(),
        error=(
            None
            if completed > 0 or final_status == "done" or review_pending > 0
            else "nenhuma faixa baixada"
        ),
        error_code=final_error_code,
        error_message=final_error_message,
        error_details=report_details,
        last_error_at=(
            None
            if (failed == 0 and review_pending == 0) or final_status == "done"
            else now_iso()
        ),
    )
    log(f"Job {job_id} finalizado: {final_status} ({completed} ok, {reused} reaproveitadas, {failed} falhas)")


def fail_job(job: dict, exc: Exception):
    attempts = job.get("attempts") or 1
    code, friendly = classify_error(exc)
    if code in YOUTUBE_CIRCUIT_CODES:
        deferred = defer_youtube_job(job, code, friendly, exc)
        delay_seconds = int(
            deferred.get("delay_seconds") or YOUTUBE_CIRCUIT_OPEN_SECONDS
        )
        open_youtube_circuit(code, delay_seconds)
        if deferred.get("blocked"):
            log(
                f"Job {job['id']} saiu da fila quente após "
                f"{deferred.get('defer_count', 3)} bloqueios do YouTube [{code}]."
            )
        else:
            log(
                f"Job {job['id']} aguarda canário do YouTube em "
                f"{delay_seconds}s [{code}]."
            )
        return
    if code in DELAYED_TRANSIENT_JOB_CODES and attempts < 3:
        retry_delay_seconds = 60 if attempts == 1 else 300
        next_attempt_at = (
            datetime.now(timezone.utc)
            + timedelta(seconds=retry_delay_seconds)
        ).isoformat()
        update_job(
            job["id"],
            status="queued",
            next_attempt_at=next_attempt_at,
            started_at=None,
            finished_at=None,
            locked_at=None,
            error=f"retry: {redact_sensitive(exc, SECRET_VALUES)}",
            error_code=code,
            error_message=friendly,
            error_details=error_details(
                exc,
                job_id=job.get("id"),
                playlist_id=job.get("playlist_id"),
                retry_delay_seconds=retry_delay_seconds,
            ),
            last_error_at=now_iso(),
        )
        log(
            f"Job {job['id']} aguardará {retry_delay_seconds}s após falha "
            f"transitória do importador (tentativa {attempts}/3)."
        )
        return
    # Volta para a fila se ainda tem tentativas; senao marca erro definitivo.
    if (
        code not in NON_RETRYABLE_JOB_CODES
        and code not in DELAYED_TRANSIENT_JOB_CODES
        and attempts < MAX_ATTEMPTS
    ):
        update_job(
            job["id"],
            status="queued",
            next_attempt_at=now_iso(),
            error=f"retry: {redact_sensitive(exc, SECRET_VALUES)}",
            error_code=code,
            error_message=friendly,
            error_details=error_details(exc, job_id=job.get("id"), playlist_id=job.get("playlist_id")),
            last_error_at=now_iso(),
        )
        log(f"Job {job['id']} falhou (tentativa {attempts}); reenfileirado.")
    else:
        update_job(
            job["id"],
            status="error",
            error=redact_sensitive(exc, SECRET_VALUES),
            error_code=code,
            error_message=friendly,
            error_details=error_details(exc, job_id=job.get("id"), playlist_id=job.get("playlist_id")),
            last_error_at=now_iso(),
            finished_at=now_iso(),
        )
        log(f"Job {job['id']} falhou definitivamente: {exc}")


def detect_uploaded_audio_container(path: str) -> str:
    """Valida magic bytes; extensão e MIME declarados nunca são suficientes."""
    with open(path, "rb") as source:
        header = source.read(16)
    if header.startswith(b"ID3") or (len(header) >= 2 and header[0] == 0xFF and header[1] & 0xE0 == 0xE0):
        return "mp3"
    if len(header) >= 12 and header[4:8] == b"ftyp":
        return "m4a"
    if header.startswith(b"OggS"):
        return "ogg"
    if header.startswith(b"RIFF") and header[8:12] == b"WAVE":
        return "wav"
    raise ValueError("MUSIC_UPLOAD_MAGIC_BYTES_INVALID")


def uploaded_audio_duration_seconds(path: str) -> float:
    result = subprocess.run(
        [
            "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "json", path,
        ],
        capture_output=True,
        text=True,
        timeout=60,
        check=True,
    )
    payload = json.loads(result.stdout or "{}")
    duration = float((payload.get("format") or {}).get("duration") or 0)
    if duration <= 0:
        raise ValueError("TRACK_DURATION_UNKNOWN")
    if duration > MAX_TRACK_DURATION_SECONDS:
        raise ValueError("TRACK_DURATION_LIMIT_EXCEEDED")
    return duration


def transcode_uploaded_audio(source_path: str, output_path: str) -> None:
    subprocess.run(
        [
            "ffmpeg", "-y", "-v", "error", "-i", source_path,
            "-vn", "-codec:a", "libmp3lame", "-b:a", f"{AUDIO_BITRATE}k",
            "-map_metadata", "-1", output_path,
        ],
        capture_output=True,
        text=True,
        timeout=300,
        check=True,
    )
    if not os.path.exists(output_path):
        raise RuntimeError("MUSIC_UPLOAD_TRANSCODE_OUTPUT_MISSING")
    if os.path.getsize(output_path) > MAX_FILE_BYTES:
        raise ValueError("TRACK_SIZE_LIMIT_EXCEEDED")


def process_music_upload_task(task: dict) -> None:
    task_id = task["task_id"]
    playlist_id = task["playlist_id"]
    staging_key = task["staging_object_key"]
    deadline = time.monotonic() + REQUEST_TIMEOUT_SECONDS
    lease_id: str | None = None
    cleanup_staging = False
    try:
        lease_id = acquire_music_operation_slot(
            "upload", playlist_id, deadline=deadline, lease_seconds=900
        )
        with tempfile.TemporaryDirectory(prefix="ptm-upload-") as workdir:
            source_path = os.path.join(workdir, "source")
            output_path = os.path.join(workdir, "output.mp3")
            s3.download_file(R2_BUCKET, staging_key, source_path)
            actual_size = os.path.getsize(source_path)
            if actual_size != int(task["declared_size_bytes"]):
                raise ValueError("MUSIC_UPLOAD_SIZE_MISMATCH")
            detect_uploaded_audio_container(source_path)
            duration_seconds = uploaded_audio_duration_seconds(source_path)
            transcode_uploaded_audio(source_path, output_path)
            digest = sha256_of(output_path)

            found = (
                supabase.table("tracks")
                .select("id,storage_object_key")
                .eq("content_hash", digest)
                .eq("status", "available")
                .limit(1)
                .execute()
            )
            if found.data:
                track_id = found.data[0]["id"]
            else:
                final_key = f"tracks/upload-{digest[:32]}.mp3"
                existing_key = (
                    supabase.table("tracks")
                    .select("id")
                    .eq("storage_object_key", final_key)
                    .limit(1)
                    .execute()
                )
                if existing_key.data:
                    track_id = existing_key.data[0]["id"]
                else:
                    upload_to_r2(output_path, final_key)
                    artists = task.get("artists") or []
                    artist = ", ".join(artists) if isinstance(artists, list) else str(artists)
                    metadata = {
                        "source": "admin_upload",
                        "size_bytes": os.path.getsize(output_path),
                        "storage_checked_at": now_iso(),
                        "content_sha256": digest,
                        "rights_attested": True,
                        "upload_session_id": task.get("session_id"),
                    }
                    if R2_PUBLIC_BASE_URL:
                        metadata["public_url"] = f"{R2_PUBLIC_BASE_URL}/{final_key}"
                    inserted = (
                        supabase.table("tracks")
                        .upsert(
                            {
                                "title": sanitize_text(task.get("title") or task.get("original_filename"), 300),
                                "artist": sanitize_text(artist, 300) or None,
                                "duration_ms": int(duration_seconds * 1000),
                                "storage_object_key": final_key,
                                "content_hash": digest,
                                "mime_type": "audio/mpeg",
                                "status": "available",
                                "metadata": sanitize_json(metadata),
                            },
                            on_conflict="storage_object_key",
                        )
                        .execute()
                    )
                    track_id = inserted.data[0]["id"]

            attach_music_upload_track(task_id, track_id)
            finish_music_upload_task(
                task_id,
                True,
                track_id=track_id,
                content_sha256=digest,
            )
            cleanup_staging = True
            log(f"Upload administrativo {task_id} concluído e vinculado idempotentemente.")
    except Exception as exc:  # noqa: BLE001
        code, friendly = classify_error(exc)
        if code == "IMPORTER_ERROR" and "MUSIC_UPLOAD" in str(exc):
            code = str(exc).split(":", 1)[0][:120]
            friendly = "O arquivo enviado não passou pela validação de áudio."
        outcome = finish_music_upload_task(
            task_id,
            False,
            error_code=code,
            error_message=friendly,
        )
        cleanup_staging = bool(outcome.get("terminal"))
        log(f"Upload administrativo {task_id} falhou [{code}]; retry finito registrado.")
    finally:
        release_music_operation_slot(lease_id)
        if cleanup_staging:
            try:
                s3.delete_object(Bucket=R2_BUCKET, Key=staging_key)
            except Exception as exc:  # noqa: BLE001
                log(f"Staging {staging_key} aguardará limpeza posterior: {exc}")


def maybe_probe_youtube_provider() -> bool:
    """Executa o canário autorizado com lease compartilhado antes de retomar jobs."""
    if not YOUTUBE_CANARY_URL:
        return False
    result = supabase.rpc(
        "worker_claim_youtube_probe",
        {"p_lease_seconds": min(DOWNLOAD_ATTEMPT_TIMEOUT_SECONDS + 60, 600)},
    ).execute()
    data = result.data or {}
    if isinstance(data, list):
        data = data[0] if data else {}
    if not isinstance(data, dict) or not data.get("claimed"):
        return False

    operation_lease_id: str | None = None
    try:
        deadline = time.monotonic() + DOWNLOAD_ATTEMPT_TIMEOUT_SECONDS
        probe_playlist_id = data.get("probe_playlist_id")
        if probe_playlist_id:
            operation_lease_id = acquire_music_operation_slot(
                "youtube",
                probe_playlist_id,
                deadline=deadline,
                lease_seconds=min(DOWNLOAD_ATTEMPT_TIMEOUT_SECONDS + 60, 900),
            )
        entry = _extract_single_video(YOUTUBE_CANARY_URL, deadline=deadline)
        if not entry.get("id"):
            raise RuntimeError("YOUTUBE_CANARY_INVALID")
        with tempfile.TemporaryDirectory(prefix="ptm-canary-") as workdir:
            probe_file = download_one(entry, workdir, deadline=deadline)
            if not os.path.exists(probe_file):
                raise RuntimeError("YOUTUBE_CANARY_DOWNLOAD_MISSING")
        supabase.rpc(
            "worker_record_youtube_probe_result",
            {"p_success": True, "p_error_code": None, "p_error_message": None},
        ).execute()
        close_youtube_circuit()
        log("Canário autorizado validou o YouTube; jobs aguardando voltaram à fila.")
        return True
    except Exception as exc:  # noqa: BLE001
        code, friendly = classify_error(exc)
        supabase.rpc(
            "worker_record_youtube_probe_result",
            {"p_success": False, "p_error_code": code, "p_error_message": friendly},
        ).execute()
        open_youtube_circuit(code, 3600)
        log(f"Canário do YouTube falhou [{code}]; nova verificação em 60 minutos.")
        return False
    finally:
        release_music_operation_slot(operation_lease_id)


# --------------------------------------------------------------------------- #
# Loop principal
# --------------------------------------------------------------------------- #

def check_ffmpeg():
    try:
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
    except Exception:  # noqa: BLE001
        log("[FATAL] ffmpeg não encontrado no ambiente.")
        sys.exit(1)


def run_download_job(job: dict) -> None:
    try:
        process_job(job)
    except Exception as exc:  # noqa: BLE001
        log(f"Job {job.get('id')} falhou: {exc.__class__.__name__}")
        fail_job(job, exc)


def main():
    check_ffmpeg()
    set_worker_state("starting", "Validacoes de inicializacao concluidas")
    threading.Thread(target=heartbeat_loop, name="worker-heartbeat", daemon=True).start()
    threading.Thread(target=storage_audit_loop, name="storage-audit", daemon=True).start()
    log("Worker iniciado. Aguardando jobs...")
    log(
        f"  limites: {MAX_TRACKS} faixas/playlist, {MAX_FILE_MB} MB/faixa, "
        f"{MAX_CONCURRENT_JOBS} jobs globais, {LOCAL_CONCURRENT_JOBS} por réplica, "
        f"{TRACK_CONCURRENCY} faixa(s)/playlist, "
        f"{TRACK_MAX_ATTEMPTS} tentativa(s)/faixa, {REQUEST_TIMEOUT_SECONDS}s/solicitação"
    )
    log(
        "  PO Token automático: "
        + ("ativo (cookies como fallback)" if POT_PROVIDER_BASE_URL else "desativado")
    )
    log(
        "  canário autorizado do YouTube: "
        + (
            "configurado"
            if YOUTUBE_CANARY_URL
            else "não configurado; retomada automática bloqueada"
        )
    )
    log(
        "  estratégias YouTube: "
        + ", ".join(strategy.label for strategy in youtube_download_strategies())
    )
    next_stale_job_check_at = 0.0
    next_storage_deletion_check_at = 0.0
    next_circuit_log_at = 0.0
    job_executor = ThreadPoolExecutor(
        max_workers=LOCAL_CONCURRENT_JOBS,
        thread_name_prefix="playlist-job",
    )
    active_jobs: dict = {}
    set_worker_state("idle", "Aguardando jobs")
    while True:
        try:
            for future in list(active_jobs):
                if not future.done():
                    continue
                job_id = active_jobs.pop(future)
                try:
                    future.result()
                except Exception as exc:  # noqa: BLE001
                    log(f"Job concorrente {job_id} encerrou com falha inesperada: {exc}")
            if active_jobs:
                current_id = next(iter(active_jobs.values())) if len(active_jobs) == 1 else None
                set_worker_state(
                    "working",
                    f"Processando {len(active_jobs)} playlist(s)",
                    current_id,
                )
            if time.monotonic() >= next_stale_job_check_at:
                try:
                    recover_stale_running_jobs()
                except Exception as exc:  # noqa: BLE001
                    log(f"Falha ao recuperar jobs abandonados: {exc}")
                next_stale_job_check_at = time.monotonic() + STALE_JOB_CHECK_SECONDS
            if time.monotonic() >= next_storage_deletion_check_at:
                next_storage_deletion_check_at = time.monotonic() + STORAGE_DELETION_POLL_SECONDS
                expired_upload = claim_expired_music_upload_session()
                if expired_upload:
                    set_worker_state("working", "Removendo upload expirado do R2")
                    try:
                        process_expired_music_upload_cleanup(expired_upload)
                    except Exception as exc:  # noqa: BLE001
                        log(f"Falha ao limpar upload expirado; retry agendado: {exc}")
                    finally:
                        set_worker_state("idle", "Aguardando jobs")
                    next_storage_deletion_check_at = 0.0
                    continue
                deletion_job = claim_storage_deletion_job()
                if deletion_job:
                    set_worker_state("working", "Removendo objeto orfao do R2")
                    try:
                        process_storage_deletion(deletion_job)
                    except Exception as exc:  # noqa: BLE001
                        log(f"Falha ao excluir objeto orfao; retry agendado: {exc}")
                    finally:
                        set_worker_state("idle", "Aguardando jobs")
                    next_storage_deletion_check_at = 0.0
                    continue
            upload_task = claim_music_upload_task()
            if upload_task:
                set_worker_state(
                    "working",
                    "Validando upload administrativo",
                    upload_task.get("task_id"),
                )
                process_music_upload_task(upload_task)
                set_worker_state("idle", "Aguardando jobs")
                continue
            circuit_remaining, circuit_reason = youtube_circuit_remaining()
            probe_succeeded = maybe_probe_youtube_provider()
            if probe_succeeded:
                circuit_remaining = 0
                circuit_reason = None
                next_circuit_log_at = 0.0
            if circuit_remaining > 0:
                set_worker_state("degraded", f"YouTube pausado: {circuit_reason or 'circuit breaker'}")
                if time.monotonic() >= next_circuit_log_at:
                    log(
                        f"YouTube pausado por mais {circuit_remaining}s "
                        f"[{circuit_reason}]; jobs permanecem na fila."
                    )
                    next_circuit_log_at = time.monotonic() + 60
                time.sleep(min(POLL_SECONDS, max(circuit_remaining, 1)))
                continue
            if len(active_jobs) >= LOCAL_CONCURRENT_JOBS:
                time.sleep(1)
                continue
            job = claim_next_job()
            if not job:
                if not active_jobs:
                    set_worker_state("idle", "Aguardando jobs")
                time.sleep(1 if active_jobs else POLL_SECONDS)
                continue
            future = job_executor.submit(run_download_job, job)
            active_jobs[future] = job.get("id")
            set_worker_state(
                "working",
                f"Processando {len(active_jobs)} playlist(s)",
                job.get("id") if len(active_jobs) == 1 else None,
            )
        except Exception as exc:  # noqa: BLE001
            set_worker_state("degraded", "Falha inesperada no loop principal")
            log(f"[loop] erro inesperado: {exc}")
            time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
