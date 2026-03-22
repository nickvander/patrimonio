# Build stage
FROM rust:1.85-slim AS builder

WORKDIR /app

# Install dependencies for sqlx (OpenSSL, pkg-config)
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

# Cache dependencies: copy Cargo files first
COPY Cargo.toml Cargo.lock* ./
RUN mkdir src && echo "fn main() {}" > src/main.rs
RUN cargo build --release 2>/dev/null || true
RUN rm -rf src

# Copy actual source and build
COPY . .
# Skip sqlx compile-time checks in Docker (no DB available at build time)
ENV SQLX_OFFLINE=true
RUN cargo build --release

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/patrimonio /usr/local/bin/patrimonio
COPY --from=builder /app/migrations /app/migrations

WORKDIR /app
ENV PORT=8080
EXPOSE 8080

CMD ["patrimonio"]
