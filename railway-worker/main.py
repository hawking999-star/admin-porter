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
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone

import boto3
from botocore.config import Config as BotoConfig
from botocore.exceptions import ClientError
from supabase import create_client
from yt_dlp import YoutubeDL

from music_source_resolver import resolver_from_environment
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
MAX_TRACK_DURATION_SECONDS = int(env("MAX_TRACK_DURATION_SECONDS", "960"))
MAX_FILE_MB = float(env("MAX_FILE_MB", "15"))
MAX_FILE_BYTES = int(MAX_FILE_MB * 1024 * 1024)
AUDIO_BITRATE = int(env("AUDIO_BITRATE", "128"))  # kbps do mp3
POLL_SECONDS = int(env("POLL_SECONDS", "10"))
MAX_ATTEMPTS = min(max(int(env("MAX_ATTEMPTS", "3")), 1), 10)
MAX_CONCURRENT_JOBS = min(max(int(env("MAX_CONCURRENT_JOBS", "1")), 1), 10)
TRACK_CONCURRENCY = min(max(int(env("TRACK_CONCURRENCY", "2")), 1), 5)
TRACK_MAX_ATTEMPTS = min(max(int(env("TRACK_MAX_ATTEMPTS", "2")), 1), 2)
STALE_JOB_SECONDS = int(env("STALE_JOB_SECONDS", "1800"))
STALE_JOB_CHECK_SECONDS = int(env("STALE_JOB_CHECK_SECONDS", "60"))
GLOBAL_FAILURE_ABORT_THRESHOLD = int(env("GLOBAL_FAILURE_ABORT_THRESHOLD", "3"))
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
DOWNLOAD_ATTEMPT_TIMEOUT_SECONDS = min(max(int(env("DOWNLOAD_ATTEMPT_TIMEOUT_SECONDS", "120")), 10), 600)
YTDLP_NETWORK_TIMEOUT_SECONDS = min(max(int(env("YTDLP_NETWORK_TIMEOUT_SECONDS", "30")), 5), 120)
SPOTDL_RESOLVE_TIMEOUT_SECONDS = min(max(int(env("SPOTDL_RESOLVE_TIMEOUT_SECONDS", "600")), 30), 1800)
REQUEST_TIMEOUT_SECONDS = min(max(int(env("REQUEST_TIMEOUT_SECONDS", "3600")), 60), 7200)
YOUTUBE_COOKIES = env("YOUTUBE_COOKIES", "")
YOUTUBE_COOKIES_FILE = env("YOUTUBE_COOKIES_FILE", "")
# URL interna do provedor de PO Token (bgutil). Quando configurado, links
# públicos usam o token automático primeiro; cookies ficam apenas como fallback.
POT_PROVIDER_BASE_URL = env("POT_PROVIDER_BASE_URL", "").rstrip("/")
# Ordem dos "player clients" do YouTube que o yt-dlp tenta ao baixar. Alguns
# clients ficam bloqueados de tempos em tempos; tentar vários em cascata aumenta
# muito a chance de sucesso. Dá para mudar via env sem alterar o código.
YT_PLAYER_CLIENTS = [
    c.strip()
    for c in env(
        "YT_PLAYER_CLIENTS",
        "mweb,web_safari,default" if POT_PROVIDER_BASE_URL else "default,web_safari,tv,ios,mweb,android,web",
    ).split(",")
    if c.strip()
]
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
}
# Estes erros afetam o importador inteiro, não apenas uma faixa. Continuar
# percorrendo a playlist só repete a mesma falha e deixa o job parecendo travado.
JOB_ABORT_CODES = {
    "YOUTUBE_COOKIES_MISSING",
    "YOUTUBE_COOKIES_INVALID",
    "YOUTUBE_TOKEN_PROVIDER_UNAVAILABLE",
    "WORKER_ENV_MISSING",
    "SUPABASE_PERMISSION_DENIED",
    "SUPABASE_ERROR",
    "R2_ACCESS_DENIED",
    "R2_ERROR",
    "SPOTIFY_METADATA_ERROR",
    "SPOTIFY_RESOLVE_TIMEOUT",
    "SPOTIFY_RESOLVER_UNAVAILABLE",
    "SPOTIFY_LINK_UNAVAILABLE",
}
# Erros de configuração não melhoram com retry automático. O Admin pode
# reenfileirar depois que a variável/permissão for corrigida.
NON_RETRYABLE_JOB_CODES = {
    "WORKER_ENV_MISSING",
    "SUPABASE_PERMISSION_DENIED",
    "R2_ACCESS_DENIED",
    "SPOTIFY_LINK_UNAVAILABLE",
}
YOUTUBE_CIRCUIT_CODES = {
    "YOUTUBE_COOKIES_MISSING",
    "YOUTUBE_COOKIES_INVALID",
    "YOUTUBE_TOKEN_PROVIDER_UNAVAILABLE",
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
    timeout_seconds=min(SPOTDL_RESOLVE_TIMEOUT_SECONDS, REQUEST_TIMEOUT_SECONDS),
    cookie_file=YOUTUBE_COOKIEFILE or "",
)

supabase = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

SECRET_VALUES = (
    SUPABASE_SERVICE_ROLE_KEY,
    R2_ACCESS_KEY_ID,
    R2_SECRET_ACCESS_KEY,
    env("SPOTIFY_RESOLVER_TOKEN", ""),
    YOUTUBE_COOKIES,
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


def open_youtube_circuit(reason: str) -> None:
    """Pausa novos downloads quando o bloqueio afeta todo o IP/worker."""
    global _YOUTUBE_CIRCUIT_OPEN_UNTIL, _YOUTUBE_CIRCUIT_REASON
    with _YOUTUBE_CIRCUIT_LOCK:
        _YOUTUBE_CIRCUIT_OPEN_UNTIL = max(
            _YOUTUBE_CIRCUIT_OPEN_UNTIL,
            time.monotonic() + YOUTUBE_CIRCUIT_OPEN_SECONDS,
        )
        _YOUTUBE_CIRCUIT_REASON = reason
    log(
        f"Circuit breaker do YouTube aberto por {YOUTUBE_CIRCUIT_OPEN_SECONDS}s "
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
    if "TRACK_DURATION_LIMIT_EXCEEDED" in raw:
        return "TRACK_DURATION_LIMIT_EXCEEDED", "A música ultrapassa a duração máxima de 16 minutos."
    if "TRACK_SIZE_LIMIT_EXCEEDED" in raw:
        return (
            "TRACK_SIZE_LIMIT_EXCEEDED",
            f"Faixa ignorada: arquivo de áudio acima do limite de {MAX_FILE_MB:.0f} MB.",
        )
    if "TRACK_DURATION_UNKNOWN" in raw:
        return "TRACK_DURATION_UNKNOWN", "Faixa ignorada: não foi possível confirmar a duração da faixa."

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
    fields["updated_at"] = now_iso()
    supabase.table("download_jobs").update(fields).eq("id", job_id).execute()


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


def request_item_status_from_code(code: str | None) -> str:
    return {
        "SPOTIFY_MATCH_NOT_FOUND": "not_found",
        "PLAYLIST_LIMIT_EXCEEDED": "playlist_limit_exceeded",
        "TRACK_DURATION_LIMIT_EXCEEDED": "duration_exceeded",
        "TRACK_DURATION_UNKNOWN": "skipped",
    }.get(code or "", "failed")


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
        .select("position,item_status,error_message")
        .eq("download_job_id", job_id)
        .execute()
    )
    existing = {
        int(item["position"]): item
        for item in (existing_result.data or [])
        if item.get("position") is not None
    }
    rows: list[dict] = []
    for entry in entries:
        position = int(entry.get("request_position", len(rows) + 1))
        previous = existing.get(position)
        rows.append(
            {
                "playlist_request_id": request_id,
                "download_job_id": job_id,
                "position": position,
                "item_status": previous["item_status"] if previous else (
                    "review_recommended"
                    if entry.get("spotify_match_status") == "review_recommended"
                    else "resolved"
                ),
                "source_track_id": entry.get("spotify_id"),
                "source_url": entry.get("spotify_url"),
                "youtube_url": entry.get("youtube_url") or entry.get("matched_youtube_url"),
                "youtube_video_id": entry.get("id"),
                "title": sanitize_text(entry.get("title")),
                "artists": sanitize_string_list([entry["artist"]] if entry.get("artist") else []),
                "album": sanitize_text(entry.get("spotify_album"), 300) or None,
                "duration_ms": int(float(entry["duration"]) * 1000) if entry.get("duration") is not None else None,
                "match_confidence": entry.get("spotify_match_confidence"),
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
        rows.append(
            {
                "playlist_request_id": request_id,
                "download_job_id": job_id,
                "position": position,
                "item_status": previous["item_status"] if previous else request_item_status_from_code(code),
                "source_track_id": entry.get("spotify_id"),
                "source_url": entry.get("spotify_url"),
                "youtube_url": entry.get("youtube_url") or entry.get("matched_youtube_url"),
                "youtube_video_id": entry.get("youtube_id") or entry.get("id"),
                "title": sanitize_text(entry.get("title")),
                "artists": sanitize_string_list([entry["artist"]] if entry.get("artist") else []),
                "album": sanitize_text(entry.get("spotify_album"), 300) or None,
                "duration_ms": int(float(entry["duration"]) * 1000) if entry.get("duration") is not None else None,
                "match_confidence": entry.get("spotify_match_confidence"),
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
    payload = {"item_status": status, "locked_at": None, "updated_at": now_iso(), **fields}
    query = supabase.table("playlist_request_tracks").update(payload)
    if entry.get("_request_item_id"):
        query.eq("id", entry["_request_item_id"]).execute()
    else:
        query.eq("playlist_request_id", request_id).eq(
            "position", entry.get("request_position")
        ).execute()


def set_request_item_status_by_youtube_id(request_id: str | None, youtube_id: str | None, status: str, **fields) -> None:
    """Atualiza uma troca manual, que não possui a posição da lista original."""
    if not request_id or not youtube_id:
        return
    payload = {"item_status": status, "updated_at": now_iso(), **fields}
    supabase.table("playlist_request_tracks").update(payload).eq(
        "playlist_request_id", request_id
    ).eq("youtube_video_id", youtube_id).execute()


def download_one(entry: dict, workdir: str, *, deadline: float | None = None) -> str:
    """Baixa uma faixa como mp3 (bitrate fixo AUDIO_BITRATE) e devolve o caminho.

    Tenta cada "player client" do YouTube em cascata (e, se houver cookies, com e
    sem cookie). O YouTube bloqueia clients de forma intermitente, então insistir
    em outro client costuma resolver o "playlist privada ou indisponível" quando o
    vídeo é, na verdade, público."""
    vid = entry["id"]
    kbps = AUDIO_BITRATE
    out_tmpl = os.path.join(workdir, f"{vid}.%(ext)s")

    def build_opts(client: str, use_cookie: bool) -> dict:
        opts = {
            "quiet": True,
            "no_warnings": True,
            "noplaylist": True,
            "format": "bestaudio[acodec!=none]/bestaudio/best[acodec!=none]/best",
            "outtmpl": out_tmpl,
            "max_filesize": MAX_FILE_BYTES * 4,  # corta downloads absurdos na fonte
            "postprocessors": [
                {
                    "key": "FFmpegExtractAudio",
                    "preferredcodec": "mp3",
                    "preferredquality": str(kbps),
                }
            ],
        }
        # "default" = NÃO força player_client: deixa o yt-dlp fazer a extração nativa
        # (escolhe os clients certos sozinho, com fallback e PO token). É o que mais
        # resolve o "Requested format is not available". Só força um client específico
        # quando pedido explicitamente.
        if client and client.lower() != "default":
            opts["extractor_args"] = {"youtube": {"player_client": [client]}}
        # PO token (bgutil): só entra se o provedor estiver configurado.
        if POT_PROVIDER_BASE_URL:
            ea = opts.setdefault("extractor_args", {})
            ea["youtubepot-bgutilhttp"] = {"base_url": [POT_PROVIDER_BASE_URL]}
        if use_cookie and YOUTUBE_COOKIEFILE:
            opts["cookiefile"] = YOUTUBE_COOKIEFILE
        return opts

    # Para conteúdo público, PO Token sem conta é o caminho principal. Cookies
    # são fallback apenas para conteúdo que realmente exige sessão.
    if POT_PROVIDER_BASE_URL and YOUTUBE_COOKIEFILE:
        cookie_modes = [False, True]
    elif YOUTUBE_COOKIEFILE:
        cookie_modes = [True, False]
    else:
        cookie_modes = [False]
    attempts = [(client, cookie) for cookie in cookie_modes for client in YT_PLAYER_CLIENTS]

    last_exc: Exception | None = None
    for client, use_cookie in attempts:
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
            if client and client.lower() != "default":
                command.extend(["--extractor-args", f"youtube:player_client={client}"])
            if POT_PROVIDER_BASE_URL:
                command.extend(["--extractor-args", f"youtubepot-bgutilhttp:base_url={POT_PROVIDER_BASE_URL}"])
            if use_cookie and YOUTUBE_COOKIEFILE:
                command.extend(["--cookies", YOUTUBE_COOKIEFILE])
            safe_video = require_youtube_video_url(
                entry.get("youtube_url") or f"https://www.youtube.com/watch?v={vid}"
            )
            command.append(safe_video.normalized_url)
            run_ytdlp_command(command, deadline=deadline)
            mp3 = os.path.join(workdir, f"{vid}.mp3")
            if not os.path.exists(mp3):
                last_exc = FileNotFoundError(f"yt-dlp não gerou o mp3 para {vid} (client={client})")
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
            last_exc = exc
            log(f"  ! {vid} client={client} cookie={use_cookie}: {exc}")
            continue

    raise RuntimeError(
        f"yt-dlp falhou ao baixar {vid} em todos os clients ({', '.join(YT_PLAYER_CLIENTS)}): {last_exc}"
    ) from last_exc


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
                log(f"    alt {alt['id']} falhou: {exc2}")
                continue
        raise exc  # nenhuma alternativa serviu — propaga o erro original (indisponível)


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
            key = f"tracks/{vid}.mp3"
            found = supabase.table("tracks").select("id").eq("storage_object_key", key).limit(1).execute()
            if found.data:
                track_id = found.data[0]["id"]
            else:
                mp3, used_vid, substituted = download_with_fallback(entry, workdir, deadline=deadline)
                dl_key = f"tracks/{used_vid}.mp3"
                try:
                    alt_found = (
                        supabase.table("tracks").select("id").eq("storage_object_key", dl_key).limit(1).execute()
                        if used_vid != vid
                        else None
                    )
                    if alt_found and alt_found.data:
                        track_id = alt_found.data[0]["id"]
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
            set_request_item_status_by_youtube_id(
                playlist_request_id, used_vid, "completed", track_id=track_id, error_message=None
            )
            log(f"Job {job_id} — faixa trocada com sucesso ({entry['title'][:60]})")
    except Exception as exc:  # noqa: BLE001
        code, friendly = classify_error(exc)
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
        set_request_item_status_by_youtube_id(
            playlist_request_id,
            require_youtube_video_url(safe_url).resource_id,
            request_item_status_from_code(code),
            error_message=friendly[:1000],
        )
        log(f"Job {job_id} — troca de faixa falhou [{code}]: {exc}")


def current_request_item(job_id: str, entry: dict) -> dict | None:
    result = (
        supabase.table("playlist_request_tracks")
        .select("id,item_status,attempts,last_error_code,error_message,track_id")
        .eq("download_job_id", job_id)
        .eq("position", int(entry.get("request_position") or 0))
        .limit(1)
        .execute()
    )
    return result.data[0] if result.data else None


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
            if status not in ("completed", "duplicate", "review_recommended"):
                result.update(
                    {
                        "code": code,
                        "reason": reason,
                        "skipped": {
                            "youtube_id": entry.get("id"),
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
        vid = work_entry["id"]
        used_vid = vid
        duration_seconds = work_entry.get("duration")
        key = f"tracks/{vid}.mp3"
        try:
            if duration_seconds is None:
                raise ValueError("TRACK_DURATION_UNKNOWN")
            if float(duration_seconds) > MAX_TRACK_DURATION_SECONDS:
                raise ValueError("TRACK_DURATION_LIMIT_EXCEEDED")

            found = (
                supabase.table("tracks")
                .select("id")
                .eq("storage_object_key", key)
                .limit(1)
                .execute()
            )
            reused = bool(found.data)
            if found.data:
                track_id = found.data[0]["id"]
            else:
                with tempfile.TemporaryDirectory(prefix=f"ptm-{vid}-") as workdir:
                    mp3, used_vid, substituted = download_with_fallback(
                        work_entry,
                        workdir,
                        deadline=deadline,
                    )
                    dl_key = f"tracks/{used_vid}.mp3"
                    try:
                        alt_found = (
                            supabase.table("tracks")
                            .select("id")
                            .eq("storage_object_key", dl_key)
                            .limit(1)
                            .execute()
                            if used_vid != vid
                            else None
                        )
                        if alt_found and alt_found.data:
                            track_id = alt_found.data[0]["id"]
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
                                        "spotify_match_method": work_entry.get("match_method") or "spotdl",
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

            # Bloqueios globais do YouTube não são falha da música. Devolve o
            # item ao estado retomável e não consome sua tentativa.
            if code in YOUTUBE_CIRCUIT_CODES:
                set_request_item_status(
                    playlist_request_id,
                    work_entry,
                    "resolved",
                    attempts=max(attempts - 1, 0),
                    error_message=friendly[:1000],
                    last_error_code=code,
                )
                open_youtube_circuit(code)
                return {
                    "status": "deferred",
                    "code": code,
                    "reason": friendly,
                    "abort": True,
                    "reused": False,
                    "technical": error_details(
                        exc,
                        playlist_id=playlist_id,
                        job_id=job_id,
                        track_id=work_entry.get("id"),
                        url=source_url,
                    ),
                }

            item_status = request_item_status_from_code(code)
            set_request_item_status(
                playlist_request_id,
                work_entry,
                item_status,
                error_message=friendly[:1000],
                last_error_code=code,
            )
            abort = code in JOB_ABORT_CODES
            permanent = code in PERMANENT_SKIP_CODES
            if abort or permanent or attempts >= TRACK_MAX_ATTEMPTS:
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
                    "technical": error_details(
                        exc,
                        playlist_id=playlist_id,
                        job_id=job_id,
                        track_id=work_entry.get("id"),
                        url=source_url,
                    ),
                }
            log(
                f"  retry {vid} falhou [{code}] na tentativa {attempts}; "
                f"nova tentativa será feita."
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

    # Somente a primeira execução substitui o snapshot ativo. Retomadas preservam
    # vínculos já concluídos e continuam nos itens ainda pendentes.
    if int(job.get("attempts") or 1) == 1:
        supabase.table("playlist_tracks").delete().eq("playlist_id", playlist_id).eq(
            "added_by_type", "system"
        ).execute()

    entries, skipped = list_source_entries(url)
    remaining_request_seconds(deadline)
    sync_request_items(playlist_request_id, job_id, entries, skipped)
    total = len(entries) + len(skipped)
    review_pending = sum(
        1 for entry in entries
        if entry.get("spotify_match_status") == "review_recommended"
    )
    update_job(job_id, total=total, completed=0, failed=len(skipped))
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

    completed = 0
    failed = len(skipped)
    first_error_code = skipped[0].get("code") if skipped else None
    first_error_message = skipped[0].get("reason") if skipped else None
    first_error_details = {"source_url": url, "track": skipped[0]} if skipped else None
    reused = 0
    eligible_entries = [
        entry for entry in entries
        if entry.get("spotify_match_status") != "review_recommended"
    ]
    abort_result = None
    with ThreadPoolExecutor(
        max_workers=TRACK_CONCURRENCY,
        thread_name_prefix="ptm-track",
    ) as executor:
        futures = {
            executor.submit(
                process_playlist_entry,
                job_id=job_id,
                playlist_id=playlist_id,
                playlist_request_id=playlist_request_id,
                entry=entry,
                source_url=url,
                deadline=deadline,
            ): entry
            for entry in eligible_entries
        }
        for future in as_completed(futures):
            if future.cancelled():
                continue
            result = future.result()
            status = result.get("status")
            if status in ("completed", "duplicate"):
                completed += 1
                reused += int(bool(result.get("reused")))
            elif status not in ("review_recommended", "deferred"):
                failed += 1
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

    if abort_result:
        raise RuntimeError(
            f"{abort_result.get('code')}: {abort_result.get('reason')}"
        )

    # Falha permanente ("indisponível") NÃO é erro de sistema. Se o que dava pra
    # importar foi importado e só sobraram indisponíveis, o job é SUCESSO com um
    # relatório — não uma "falha" vermelha no admin.
    skipped_codes = [s.get("code") for s in skipped]
    excluded_by_limit = sum(1 for code in skipped_codes if code == "PLAYLIST_LIMIT_EXCEEDED")
    has_real_error = any(c not in PERMANENT_SKIP_CODES for c in skipped_codes)
    only_unavailable = failed > 0 and not has_real_error

    if failed == 0:
        final_status = "done"
    elif completed > 0 and only_unavailable:
        final_status = "done"      # importou tudo que era possível; resto é indisponível
    elif completed > 0:
        final_status = "partial"   # erro real de sistema + algo importado
    else:
        final_status = "error"     # nada importado

    final_error_code = None
    final_error_message = None
    if failed > 0 and final_status != "done":
        final_error_code = "PARTIAL_IMPORT_FAILED" if completed > 0 else (first_error_code or "NO_TRACKS_DOWNLOADED")
        final_error_message = (
            f"A solicitação foi concluída parcialmente: {completed} músicas concluídas e {failed} não concluídas."
            if completed > 0
            else (first_error_message or "Nenhuma música foi baixada da playlist.")
        )
    elif final_status == "done" and failed > 0:
        # Sucesso COM indisponíveis: informativo, não é falha.
        final_error_code = "IMPORTED_WITH_UNAVAILABLE"
        final_error_message = f"{completed} músicas importadas; {failed} indisponível(is) ou não localizada(s)."

    # Guarda o relatório sempre que algo tiver sido pulado, mesmo em sucesso,
    # para o admin exibir os indisponíveis de forma neutra.
    report_details = None
    if failed > 0:
        report_details = {
            "summary": {
                "playlist_id": playlist_id,
                "job_id": job_id,
                "source_url": url,
                "total": total,
                "completed": completed,
                "failed": failed,
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
        error=None if (completed > 0 or final_status == "done") else "nenhuma faixa baixada",
        error_code=final_error_code,
        error_message=final_error_message,
        error_details=report_details,
        last_error_at=None if (failed == 0 or final_status == "done") else now_iso(),
    )
    log(f"Job {job_id} finalizado: {final_status} ({completed} ok, {reused} reaproveitadas, {failed} falhas)")


def fail_job(job: dict, exc: Exception):
    attempts = job.get("attempts") or 1
    code, friendly = classify_error(exc)
    if code in YOUTUBE_CIRCUIT_CODES:
        open_youtube_circuit(code)
        update_job(
            job["id"],
            status="queued",
            # Mantém uma tentativa-base para que a retomada não volte a apagar
            # vínculos já concluídos; novas pausas continuam neste mesmo valor.
            attempts=1,
            started_at=job.get("started_at"),
            finished_at=None,
            locked_at=None,
            error=f"paused: {redact_sensitive(exc, SECRET_VALUES)}",
            error_code=code,
            error_message=friendly,
            error_details=error_details(exc, job_id=job.get("id"), playlist_id=job.get("playlist_id")),
            last_error_at=now_iso(),
        )
        log(f"Job {job['id']} pausado por bloqueio global do YouTube [{code}].")
        return
    # Volta para a fila se ainda tem tentativas; senao marca erro definitivo.
    if code not in NON_RETRYABLE_JOB_CODES and attempts < MAX_ATTEMPTS:
        update_job(
            job["id"],
            status="queued",
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


# --------------------------------------------------------------------------- #
# Loop principal
# --------------------------------------------------------------------------- #

def check_ffmpeg():
    try:
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
    except Exception:  # noqa: BLE001
        log("[FATAL] ffmpeg não encontrado no ambiente.")
        sys.exit(1)


def main():
    check_ffmpeg()
    set_worker_state("starting", "Validacoes de inicializacao concluidas")
    threading.Thread(target=heartbeat_loop, name="worker-heartbeat", daemon=True).start()
    threading.Thread(target=storage_audit_loop, name="storage-audit", daemon=True).start()
    log("Worker iniciado. Aguardando jobs...")
    log(
        f"  limites: {MAX_TRACKS} faixas/playlist, {MAX_FILE_MB} MB/faixa, "
        f"{MAX_CONCURRENT_JOBS} job(s), {TRACK_CONCURRENCY} faixa(s)/job, "
        f"{TRACK_MAX_ATTEMPTS} tentativa(s)/faixa, {REQUEST_TIMEOUT_SECONDS}s/solicitação"
    )
    log(
        "  PO Token automático: "
        + ("ativo (cookies como fallback)" if POT_PROVIDER_BASE_URL else "desativado")
    )
    next_stale_job_check_at = 0.0
    next_storage_deletion_check_at = 0.0
    next_circuit_log_at = 0.0
    set_worker_state("idle", "Aguardando jobs")
    while True:
        try:
            if time.monotonic() >= next_stale_job_check_at:
                try:
                    recover_stale_running_jobs()
                except Exception as exc:  # noqa: BLE001
                    log(f"Falha ao recuperar jobs abandonados: {exc}")
                next_stale_job_check_at = time.monotonic() + STALE_JOB_CHECK_SECONDS
            if time.monotonic() >= next_storage_deletion_check_at:
                next_storage_deletion_check_at = time.monotonic() + STORAGE_DELETION_POLL_SECONDS
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
            circuit_remaining, circuit_reason = youtube_circuit_remaining()
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
            job = claim_next_job()
            if not job:
                set_worker_state("idle", "Aguardando jobs")
                time.sleep(POLL_SECONDS)
                continue
            set_worker_state("working", "Processando importacao", job.get("id"))
            try:
                process_job(job)
            except Exception as exc:  # noqa: BLE001
                log(f"Job {job.get('id')} falhou: {exc.__class__.__name__}")
                fail_job(job, exc)
            finally:
                set_worker_state("idle", "Aguardando jobs")
        except Exception as exc:  # noqa: BLE001
            set_worker_state("degraded", "Falha inesperada no loop principal")
            log(f"[loop] erro inesperado: {exc}")
            time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
