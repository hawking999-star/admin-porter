FROM denoland/deno:bin-2.8.1 AS deno

FROM python:3.12-slim

# ffmpeg converte o áudio em mp3; Deno resolve os desafios JavaScript que o
# yt-dlp exige para expor todos os formatos do YouTube.
COPY --from=deno /deno /usr/local/bin/deno

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# -u = logs sem buffer (aparecem na hora no painel do Railway)
CMD ["python", "-u", "main.py"]
