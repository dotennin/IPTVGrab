# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 – Build the frontend (Vite + TypeScript)
# ─────────────────────────────────────────────────────────────────────────────
FROM node:20-alpine AS frontend-builder

WORKDIR /app

# Install deps first for better layer caching
COPY frontend/package.json frontend/package-lock.json frontend/
RUN cd frontend && npm ci --prefer-offline

# Copy source and build; outDir is '../static/dist' relative to frontend/
COPY frontend/ frontend/
RUN mkdir -p static && cd frontend && npm run build

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 – Build the Rust server binary
# ─────────────────────────────────────────────────────────────────────────────
FROM rust:1.85-bookworm AS builder

WORKDIR /build

# Copy workspace manifests (dependency-caching layer)
COPY Cargo.toml Cargo.lock ./
COPY crates/m3u8-core/Cargo.toml crates/m3u8-core/Cargo.toml
COPY crates/server/Cargo.toml    crates/server/Cargo.toml

# Remove mobile-ffi from the workspace (it needs mobile cross-toolchains that
# are not available here) and stub out source so `cargo fetch` can run.
RUN sed -i '/"crates\/mobile-ffi"/d' Cargo.toml \
 && mkdir -p crates/m3u8-core/src crates/server/src \
 && printf 'fn main(){}' > crates/server/src/main.rs \
 && touch crates/m3u8-core/src/lib.rs

# Pre-fetch crate registry (cached unless Cargo.lock changes)
RUN cargo fetch

# Now bring in the real source
COPY crates/m3u8-core/src/ crates/m3u8-core/src/
COPY crates/server/src/    crates/server/src/

RUN cargo build --release -p server \
 && strip target/release/m3u8-server

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3 – Minimal runtime image
# ─────────────────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/target/release/m3u8-server ./m3u8-server

# Copy only the Vite-built frontend (includes favicons, login.html, and all assets)
COPY --from=frontend-builder /app/static/dist/ /app/static/dist/

RUN mkdir -p /app/downloads

ENV HOST=0.0.0.0 \
    PORT=8765 \
    DOWNLOADS_DIR=/app/downloads \
    STATIC_DIR=/app/static \
    RUST_LOG=info

EXPOSE 8765

VOLUME ["/app/downloads"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -sf "http://localhost:${PORT}/api/auth/status" || exit 1

CMD ["/app/m3u8-server"]
