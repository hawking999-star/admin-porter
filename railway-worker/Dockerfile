FROM python:3.12-slim

# ffmpeg é necessário para converter o áudio em mp3
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# -u = logs sem buffer (aparecem na hora no painel do Railway)
CMD ["python", "-u", "main.py"]
