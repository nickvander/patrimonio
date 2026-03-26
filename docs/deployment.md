# Deployment & Infrastructure

Patrimonio is designed for easy self-hosting and cloud deployment using containerization.

## Local Development (Docker Compose)
The fastest way to get started is using the provided Docker Compose configuration.

### Prerequisites
- Docker & Docker Compose
- Plaid API Keys (optional, for US accounts)
- ExchangeRate-API Key (optional, for real-time FX)

### Spin up the stack
```bash
docker compose up -d
```
This starts:
- **PostgreSQL 17** (Port 5432)
- **Redis 7** (Port 6379)
- **Rust API Server** (Port 8080)
- **Wait-for-DB utility** to ensure migrations run correctly.

## Production Deployment (GCP)
The project is architected for **Google Cloud Platform**:

- **Cloud Run**: Hosts the stateless Rust API.
- **Cloud SQL**: Managed PostgreSQL instance.
- **Cloud Memorystore**: Managed Redis.
- **Firebase Hosting**: High-speed hosting for the Flutter Web build.

## Continuous Integration
A GitHub Action is recommended for:
1. **Building & Testing**: Running Rust `cargo test` and Flutter `flutter analyze`.
2. **Containerization**: Building the Docker image and pushing to Artifact Registry.
3. **Documentation**: Building the MkDocs site and deploying to GitHub Pages.

### Documentation Build
```bash
# To preview locally
pip install mkdocs-material
mkdocs serve
```
