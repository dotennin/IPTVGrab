# ── Build stage (install Python deps) ────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM python:3.11-slim

# Install ffmpeg (required for segment merging)
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy installed Python packages from builder
COPY --from=builder /install /usr/local

# Copy application code
COPY main.py downloader.py run.py ./
COPY static/ ./static/

# Downloads go here – mount a host volume to persist files
ENV DOWNLOADS_DIR=/downloads
ENV PORT=8765

VOLUME ["/downloads"]
EXPOSE 8765

CMD ["python", "run.py"]
