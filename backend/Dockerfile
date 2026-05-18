# Build stage
FROM rust:1.88-slim AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

# Cache dependencies: copy Cargo files and build deps only
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {println!(\"dummy\");}" > src/main.rs
RUN cargo build --release || true
# Remove the dummy build artifacts for the main binary, but keep dep caches
RUN rm -f target/release/deps/patrimonio* target/release/patrimonio*

# Copy actual source
COPY . .
# Touch main.rs so cargo knows it changed
RUN touch src/main.rs

# Build the real binary
# SQLX_OFFLINE skips compile-time DB checks for sqlx macros 
ENV SQLX_OFFLINE=true
RUN cargo build --release

# Verify the binary exists and is not trivially small
RUN ls -la target/release/patrimonio && test $(stat -c%s target/release/patrimonio) -gt 1000000
# Same check for the rotate_encryption_key one-shot — it's shipped alongside
# so the operator can run a key rotation from the same image instead of
# needing a Rust toolchain on the host. See docs/operations.md.
RUN ls -la target/release/rotate_encryption_key && test $(stat -c%s target/release/rotate_encryption_key) -gt 1000000

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates qpdf && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/patrimonio /usr/local/bin/patrimonio
COPY --from=builder /app/target/release/rotate_encryption_key /usr/local/bin/rotate_encryption_key
COPY --from=builder /app/migrations /app/migrations

WORKDIR /app
ENV PORT=8080
EXPOSE 8080

CMD ["patrimonio"]
