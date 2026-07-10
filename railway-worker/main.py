"""
Porter Music — Worker de download (Railway)

O que faz, em uma frase: fica de olho na fila `download_jobs` no Supabase; quando
aparece uma playlist aprovada do YouTube, baixa o áudio (máx. 170 faixas, cada uma
<= 15 MB), sobe cada arquivo para o Cloudflare R2 e grava em `tracks` + `playlist_tracks`.

Não precisa mexer no código para operar. Tudo é controlado por variáveis de ambiente
(veja .env.example). É só rodar: `python main.py`.
"""

import hashlib
import os
import subprocess
import sys
import tempfile
import time
import traceback
from datetime import datetime, timezone

import boto3
from botocore.config import Config as BotoConfig
from botocore.exceptions import ClientError
from supabase import create_client
from yt_dlp import YoutubeDL

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
MAX_ATTEMPTS = int(env("MAX_ATTEMPTS", "3"))
YOUTUBE_COOKIES = env("YOUTUBE_COOKIES", "")
YOUTUBE_COOKIES_FILE = env("YOUTUBE_COOKIES_FILE", "")
# Ordem dos "player clients" do YouTube que o yt-dlp tenta ao baixar. Alguns
# clients ficam bloqueados de tempos em tempos; tentar vários em cascata aumenta
# muito a chance de sucesso. Dá para mudar via env sem alterar o código.
YT_PLAYER_CLIENTS = [
    c.strip() for c in env("YT_PLAYER_CLIENTS", "tv,ios,android,web").split(",") if c.strip()
]


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
    return path


YOUTUBE_COOKIEFILE = ensure_youtube_cookiefile()

supabase = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

s3 = boto3.client(
    "s3",
    endpoint_url=f"https://{R2_ACCOUNT_ID}.r2.cloudflarestorage.com",
    aws_access_key_id=R2_ACCESS_KEY_ID,
    aws_secret_access_key=R2_SECRET_ACCESS_KEY,
    region_name="auto",
    config=BotoConfig(retries={"max_attempts": 3, "mode": "standard"}),
)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def log(*args):
    print(f"[{now_iso()}]", *args, flush=True)


def classify_error(exc_or_message, context: str | None = None) -> tuple[str, str]:
    """Converte erros técnicos em código estável + mensagem operacional."""
    raw = str(exc_or_message or "").strip()
    msg = raw.lower()

    if context == "env":
        return "WORKER_ENV_MISSING", "Falha no importador: variável de ambiente obrigatória ausente."

    # Sentinelas internas do importador: comparar no texto ORIGINAL (case-sensitive).
    # Ficam no topo para não serem "engolidas" pelas regras genéricas abaixo.
    if "TRACK_DURATION_LIMIT_EXCEEDED" in raw:
        return (
            "TRACK_DURATION_LIMIT_EXCEEDED",
            f"Faixa ignorada: duração acima do limite de {MAX_TRACK_DURATION_SECONDS} segundos "
            f"({MAX_TRACK_DURATION_SECONDS // 60} min).",
        )
    if "TRACK_SIZE_LIMIT_EXCEEDED" in raw:
        return (
            "TRACK_SIZE_LIMIT_EXCEEDED",
            f"Faixa ignorada: arquivo de áudio acima do limite de {MAX_FILE_MB:.0f} MB.",
        )
    if "TRACK_DURATION_UNKNOWN" in raw:
        return "TRACK_DURATION_UNKNOWN", "Faixa ignorada: não foi possível confirmar a duração da faixa."

    if "timed out" in msg or "timeout" in msg:
        return "IMPORT_TIMEOUT", "Falha no importador: tempo limite excedido."
    if "requested format is not available" in msg or "no video formats found" in msg:
        return (
            "YOUTUBE_FORMAT_UNAVAILABLE",
            "Falha no YouTube: nenhum formato de áudio disponível para download no ambiente do importador.",
        )
    if any(p in msg for p in ("not a bot", "sign in to confirm", "confirm you’re", "confirm your age")):
        if not YOUTUBE_COOKIEFILE:
            return (
                "YOUTUBE_COOKIES_MISSING",
                "Falha ao importar: o YouTube pediu login (proteção anti-bot). "
                "Configure a variável YOUTUBE_COOKIES no Railway (cookies de uma conta logada).",
            )
        return (
            "YOUTUBE_COOKIES_INVALID",
            "Falha ao importar: o YouTube recusou os cookies atuais (podem ter expirado). "
            "Atualize a variável YOUTUBE_COOKIES no Railway.",
        )
    if "private" in msg or "unavailable" in msg or "not available" in msg or "sign in" in msg:
        # Sem cookies num IP de datacenter (Railway), o YouTube costuma recusar o
        # download mesmo de vídeos públicos. Se não houver cookie, aponte a causa provável.
        if not YOUTUBE_COOKIEFILE:
            return (
                "YOUTUBE_COOKIES_MISSING",
                "Falha ao importar: o YouTube recusou o download (provável bloqueio anti-bot). "
                "Configure a variável YOUTUBE_COOKIES no Railway para liberar.",
            )
        return "PLAYLIST_PRIVATE_OR_UNAVAILABLE", "Falha ao importar: playlist privada ou indisponível."
    if "unsupported url" in msg or "invalid url" in msg or "no suitable extractor" in msg:
        return "INVALID_URL", "Link inválido ou plataforma não suportada."
    if "permission denied" in msg or "row-level security" in msg or "rls" in msg:
        return "SUPABASE_PERMISSION_DENIED", "Falha no Supabase: permissão negada."
    if isinstance(exc_or_message, ClientError):
        code = exc_or_message.response.get("Error", {}).get("Code", "")
        if code in {"AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch"}:
            return "R2_ACCESS_DENIED", "Falha ao salvar no R2: acesso negado."
        return "R2_ERROR", "Falha ao salvar no R2."
    if "youtube" in msg or "yt_dlp" in msg or "yt-dlp" in msg:
        return "YOUTUBE_ERROR", "Falha no YouTube ao ler ou baixar a playlist."
    if "supabase" in msg or "postgrest" in msg or "duplicate key" in msg:
        return "SUPABASE_ERROR", "Falha no Supabase ao gravar a importação."
    return "IMPORTER_ERROR", raw or "Falha ao importar playlist."


def error_details(exc_or_message, **context) -> dict:
    raw = str(exc_or_message or "")
    details = {
        "raw_error": raw[:2000],
        "context": {k: v for k, v in context.items() if v is not None},
    }
    if isinstance(exc_or_message, Exception):
        details["exception_type"] = exc_or_message.__class__.__name__
        stack = traceback.format_exception(type(exc_or_message), exc_or_message, exc_or_message.__traceback__)
        details["stack"] = "".join(stack)[-4000:]
    return details


# --------------------------------------------------------------------------- #
# Fila de jobs
# --------------------------------------------------------------------------- #

def claim_next_job() -> dict | None:
    """Pega o próximo job 'queued' e marca como 'running' de forma atômica."""
    res = (
        supabase.table("download_jobs")
        .select("*")
        .eq("status", "queued")
        .order("created_at")
        .limit(1)
        .execute()
    )
    if not res.data:
        return None
    job = res.data[0]

    claim = (
        supabase.table("download_jobs")
        .update(
            {
                "status": "running",
                "started_at": now_iso(),
                "locked_at": now_iso(),
                "attempts": (job.get("attempts") or 0) + 1,
                "error": None,
                "error_code": None,
                "error_message": None,
                "error_details": None,
                "last_error_at": None,
                "updated_at": now_iso(),
            }
        )
        .eq("id", job["id"])
        .eq("status", "queued")  # só ganha se ninguém pegou antes
        .execute()
    )
    if not claim.data:
        return None  # outro worker pegou
    return claim.data[0]


def update_job(job_id: str, **fields):
    fields["updated_at"] = now_iso()
    supabase.table("download_jobs").update(fields).eq("id", job_id).execute()


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

def list_playlist_entries(url: str) -> list[dict]:
    """Retorna até MAX_TRACKS entradas (id, title, duration) da playlist/vídeo."""
    opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
        "skip_download": True,
        "playlistend": MAX_TRACKS,
    }
    if YOUTUBE_COOKIEFILE:
        opts["cookiefile"] = YOUTUBE_COOKIEFILE
    with YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False)
    entries = info.get("entries")
    if entries is None:  # link de vídeo único
        entries = [info]
    out = []
    for e in entries:
        if not e:
            continue
        vid = e.get("id")
        if not vid:
            continue
        out.append(
            {
                "id": vid,
                "title": e.get("title") or vid,
                "artist": e.get("uploader") or e.get("channel"),
                "duration": e.get("duration"),  # segundos, pode ser None
            }
        )
        if len(out) >= MAX_TRACKS:
            break
    return out


def download_one(entry: dict, workdir: str) -> str:
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
            "format": "bestaudio[acodec!=none]/best[acodec!=none]/bestaudio/best",
            "outtmpl": out_tmpl,
            "max_filesize": MAX_FILE_BYTES * 4,  # corta downloads absurdos na fonte
            "extractor_args": {"youtube": {"player_client": [client]}},
            "postprocessors": [
                {
                    "key": "FFmpegExtractAudio",
                    "preferredcodec": "mp3",
                    "preferredquality": str(kbps),
                }
            ],
        }
        if use_cookie and YOUTUBE_COOKIEFILE:
            opts["cookiefile"] = YOUTUBE_COOKIEFILE
        return opts

    # Combinações a tentar: cada client, com cookie (se houver) e depois sem.
    cookie_modes = [True, False] if YOUTUBE_COOKIEFILE else [False]
    attempts = [(client, cookie) for client in YT_PLAYER_CLIENTS for cookie in cookie_modes]

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
            with YoutubeDL(build_opts(client, use_cookie)) as ydl:
                ydl.download([f"https://www.youtube.com/watch?v={vid}"])
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


# --------------------------------------------------------------------------- #
# Processamento de um job
# --------------------------------------------------------------------------- #

def process_job(job: dict):
    job_id = job["id"]
    playlist_id = job["playlist_id"]
    url = job.get("source_url")
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

    # Limpa faixas adicionadas anteriormente por este processo (retry limpo).
    supabase.table("playlist_tracks").delete().eq("playlist_id", playlist_id).eq(
        "added_by_type", "system"
    ).execute()

    entries = list_playlist_entries(url)
    total = len(entries)
    update_job(job_id, total=total, completed=0, failed=0)
    log(f"  {total} faixas na fila (limite {MAX_TRACKS})")

    if total == 0:
        update_job(
            job_id,
            status="error",
            error="playlist vazia",
            error_code="PLAYLIST_EMPTY",
            error_message="Falha ao importar: playlist vazia ou sem músicas disponíveis.",
            error_details=error_details("playlist vazia", playlist_id=playlist_id, job_id=job_id, url=url),
            last_error_at=now_iso(),
            finished_at=now_iso(),
        )
        return

    completed = 0
    failed = 0
    position = 0
    first_error_code = None
    first_error_message = None
    first_error_details = None
    skipped: list[dict] = []  # relatório por-música: o que NÃO entrou e por quê

    reused = 0
    with tempfile.TemporaryDirectory() as workdir:
        for entry in entries:
            vid = entry["id"]
            duration_seconds = entry.get("duration")
            # Não aceite duração desconhecida: o limite precisa ser verificável
            # antes de baixar/reutilizar uma faixa. O banco repete a proteção
            # para qualquer escritor concorrente.
            # Chave GLOBAL por musica (nao por playlist): a mesma musica vira
            # 1 unico arquivo no R2 e 1 unica linha em `tracks`, compartilhada
            # por todas as playlists que a usam. Isso deduplica repetidas.
            key = f"tracks/{vid}.mp3"
            try:
                if duration_seconds is None:
                    raise ValueError("TRACK_DURATION_UNKNOWN")
                if float(duration_seconds) > MAX_TRACK_DURATION_SECONDS:
                    raise ValueError("TRACK_DURATION_LIMIT_EXCEEDED")
                # 1) Ja existe essa musica (em qualquer playlist)? Reutiliza - nao rebaixa.
                found = (
                    supabase.table("tracks")
                    .select("id")
                    .eq("storage_object_key", key)
                    .limit(1)
                    .execute()
                )
                if found.data:
                    track_id = found.data[0]["id"]
                    reused += 1
                else:
                    mp3 = download_one(entry, workdir)
                    try:
                        digest = sha256_of(mp3)
                        upload_to_r2(mp3, key)

                        meta = {
                            "youtube_id": vid,
                            "source": "youtube",
                            "source_url": f"https://www.youtube.com/watch?v={vid}",
                        }
                        if R2_PUBLIC_BASE_URL:
                            meta["public_url"] = f"{R2_PUBLIC_BASE_URL}/{key}"

                        dur_ms = int(float(duration_seconds) * 1000)
                        # upsert por storage_object_key: se dois jobs correrem juntos,
                        # nao cria duplicado (o segundo reaproveita a mesma linha).
                        track = (
                            supabase.table("tracks")
                            .upsert(
                                {
                                    "title": entry["title"][:300],
                                    "artist": (entry.get("artist") or None),
                                    "duration_ms": dur_ms,
                                    "storage_object_key": key,
                                    "content_hash": digest,
                                    "mime_type": "audio/mpeg",
                                    "status": "available",
                                    "metadata": meta,
                                },
                                on_conflict="storage_object_key",
                            )
                            .execute()
                        )
                        track_id = track.data[0]["id"]
                    finally:
                        if os.path.exists(mp3):
                            os.remove(mp3)

                # 2) Liga a faixa a ESTA playlist (no maximo uma vez por playlist).
                #    on_conflict garante reprocesso idempotente, sem duplicar o vinculo.
                position += 1
                supabase.table("playlist_tracks").upsert(
                    {
                        "playlist_id": playlist_id,
                        "track_id": track_id,
                        "position": position,
                        "added_by_type": "system",
                    },
                    on_conflict="playlist_id,track_id",
                ).execute()

                completed += 1
                update_job(job_id, completed=completed)
                tag = "reuso" if found.data else "novo"
                log(f"  ok {position}/{total} [{tag}] {entry['title'][:60]}")
            except Exception as exc:  # noqa: BLE001
                failed += 1
                code, friendly = classify_error(exc)
                details = error_details(
                    exc,
                    playlist_id=playlist_id,
                    job_id=job_id,
                    track_id=entry.get("id"),
                    url=url,
                )
                if first_error_code is None:
                    first_error_code = code
                    first_error_message = friendly
                    first_error_details = details
                skipped.append(
                    {
                        "youtube_id": entry.get("id"),
                        "title": (entry.get("title") or entry.get("id") or "")[:200],
                        "duration_seconds": duration_seconds,
                        "code": code,
                        "reason": friendly,
                    }
                )
                update_job(
                    job_id,
                    failed=failed,
                    error=str(exc),
                    error_code=code,
                    error_message=friendly,
                    error_details=details,
                    last_error_at=now_iso(),
                )
                log(f"  ! erro ao salvar {entry['id']} [{code}]: {exc}")

    final_status = "done" if failed == 0 else ("partial" if completed > 0 else "error")
    final_error_code = None
    if failed > 0:
        final_error_code = "PARTIAL_IMPORT_FAILED" if completed > 0 else (first_error_code or "NO_TRACKS_DOWNLOADED")
    final_error_message = None
    if failed > 0:
        final_error_message = (
            f"Importação parcial: {completed} músicas importadas e {failed} falharam."
            if completed > 0
            else (first_error_message or "Nenhuma música foi baixada da playlist.")
        )
    update_job(
        job_id,
        status=final_status,
        completed=completed,
        failed=failed,
        finished_at=now_iso(),
        error=None if completed > 0 else "nenhuma faixa baixada",
        error_code=final_error_code,
        error_message=final_error_message,
        error_details=None if failed == 0 else {
            "summary": {
                "playlist_id": playlist_id,
                "job_id": job_id,
                "source_url": url,
                "total": total,
                "completed": completed,
                "failed": failed,
            },
            # Relatório por-música consumido pelo Admin (sem stack sensível).
            "skipped": skipped,
            "first_error": first_error_details,
        },
        last_error_at=None if failed == 0 else now_iso(),
    )
    log(f"Job {job_id} finalizado: {final_status} ({completed} ok, {reused} reaproveitadas, {failed} falhas)")


def fail_job(job: dict, exc: Exception):
    attempts = job.get("attempts") or 1
    code, friendly = classify_error(exc)
    # Volta para a fila se ainda tem tentativas; senao marca erro definitivo.
    if attempts < MAX_ATTEMPTS:
        update_job(
            job["id"],
            status="queued",
            error=f"retry: {exc}",
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
            error=str(exc),
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
    log("Worker iniciado. Aguardando jobs...")
    log(f"  limites: {MAX_TRACKS} faixas/playlist, {MAX_FILE_MB} MB/faixa")
    while True:
        try:
            deletion_job = claim_storage_deletion_job()
            if deletion_job:
                try:
                    process_storage_deletion(deletion_job)
                except Exception as exc:  # noqa: BLE001
                    log(f"Falha ao excluir objeto órfão; retry agendado: {exc}")
                continue
            job = claim_next_job()
            if not job:
                time.sleep(POLL_SECONDS)
                continue
            try:
                process_job(job)
            except Exception as exc:  # noqa: BLE001
                traceback.print_exc()
                fail_job(job, exc)
        except Exception as exc:  # noqa: BLE001
            log(f"[loop] erro inesperado: {exc}")
            time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
