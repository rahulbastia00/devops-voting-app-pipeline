# Phase 1: Containerization & Continuous Integration (CI)

## Architecture & Objective

The objective of Phase 1 is to containerize the distributed polyglot microservices application, establish efficient container image builds using multi-stage Dockerfiles and unprivileged runtime users, and automate build testing and artifact delivery via GitHub Actions.

```mermaid
flowchart TD
    subgraph Development
        Developer[Developer Git Push]
    end

    subgraph GitHub_Actions_CI["GitHub Actions CI Pipeline (.github/workflows/ci.yaml)"]
        Trigger[Push / Workflow Dispatch] --> Matrix[Matrix Strategy: vote, result, worker]
        Matrix --> Checkout[actions/checkout@v4]
        Checkout --> SetupBuildx[docker/setup-buildx-action@v3]
        SetupBuildx --> LocalBuild["docker/build-push-action@v5<br/>Build Local Image (scan-temp)"]
        LocalBuild --> TrivyScan["Trivy Vulnerability Scan<br/>(aquasecurity/trivy-action)"]
        TrivyScan --> DockerHubAuth["docker/login-action@v3<br/>Docker Hub Auth"]
        DockerHubAuth --> PushDockerHub["docker/build-push-action@v5<br/>Push tags: latest, sha"]
    end

    subgraph Registry["Docker Hub Registry"]
        RepoVote["rahulbastia/examplevotingapp_vote"]
        RepoResult["rahulbastia/examplevotingapp_result"]
        RepoWorker["rahulbastia/examplevotingapp_worker"]
    end

    PushDockerHub --> RepoVote
    PushDockerHub --> RepoResult
    PushDockerHub --> RepoWorker
```

The application consists of three primary custom services:
1. **Vote App (`vote/`):** A Python 3.11 web frontend allowing users to cast votes between two options (Cats vs Dogs).
2. **Worker Service (`worker/`):** A .NET 7.0 background worker consuming votes from an in-memory queue (Redis) and persisting them to a relational database (PostgreSQL).
3. **Result App (`result/`):** A Node.js 18 web frontend providing real-time tally visualizations via WebSockets and direct PostgreSQL querying.

---

## Containerization Strategy & Dockerfiles

### 1. Vote Frontend Service (`vote/Dockerfile`)

The Vote service utilizes Python 3.11 on Alpine/Debian slim base. Key optimizations include:
- `PYTHONDONOTWRITEBYTECODE=1`: Prevents `.pyc` files from being written to the container layer.
- `PYTHONUNBUFFERED=1`: Ensures standard output and error streams are sent directly to terminal/logs without buffering.
- Dependency caching: `requirements.txt` is copied and installed prior to copying source code to leverage Docker layer caching.

```dockerfile
FROM python:3.11-slim

ENV PYTHONDONOTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . . 

EXPOSE 80

CMD ["python", "app.py"]
```

### 2. Result Reporting Service (`result/Dockerfile`)

The Result service is built on Node.js 18. Key security and optimization features:
- Production dependencies only (`npm install --only=production`).
- Cleaned npm cache (`npm cache clean --force`).
- Least privilege enforcement: Runs under unprivileged user `USER node` rather than `root`.

```dockerfile
FROM node:18-slim

ENV NODE_ENV=production

WORKDIR /app
COPY package*.json ./
RUN npm install --only=production && npm cache clean --force
COPY . . 

USER node
EXPOSE 4000

CMD ["node", "server.js"]
```

### 3. Worker Background Service (`worker/Dockerfile`)

The Worker service leverages a **multi-stage build** to separate the compilation environment from the minimal runtime image:
- **Build Stage (`mcr.microsoft.com/dotnet/sdk:7.0`):** Restores NuGet packages and compiles the release binary into `/app`.
- **Runtime Stage (`mcr.microsoft.com/dotnet/runtime:7.0`):** Copies only compiled binaries (`Worker.dll`) from the build stage, eliminating compilers, build tools, and package caches from the final image, significantly reducing attack surface and image size.

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:7.0 AS build
WORKDIR /source

COPY *.csproj ./
RUN dotnet restore

COPY . ./
RUN dotnet publish -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/runtime:7.0 AS runtime
WORKDIR /app
COPY --from=build /app ./

CMD ["dotnet", "Worker.dll"]
```

---

## Local Multi-Container Orchestration (`docker-compose.yaml`)

To validate end-to-end functionality locally prior to CI and cloud deployment, a multi-container Docker Compose setup isolates the services across two distinct bridge networks (`vote-tier` and `result-tier`):

```yaml
services:
  vote:
    image: rahulbastia/examplevotingapp_vote:latest
    container_name: vote-service
    ports:
      - "5000:80"
    environment:
      - OPTION_A=Cats
      - OPTION_B=Dogs
    networks:
      - vote-tier
    depends_on:
      redis:
        condition: service_healthy
    restart: unless-stopped

  result:
    image: rahulbastia/examplevotingapp_result:latest
    container_name: result-service
    ports:
      - "5001:4000"
    environment:
      - PORT=4000
    networks:
      - result-tier
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

  worker:
    image: rahulbastia/examplevotingapp_worker:latest
    container_name: worker-service
    networks:
      - vote-tier
      - result-tier
    depends_on:
      redis:
        condition: service_healthy
      db:
        condition: service_healthy
    restart: unless-stopped

  redis:
    image: redis:7.0-alpine
    container_name: redis-service
    networks:
      - vote-tier
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
    restart: unless-stopped

  db:
    image: postgres:15-alpine
    container_name: postgres-service
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: postgres
    volumes:
      - db-data:/var/lib/postgresql/data
    networks:
      - result-tier
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d postgres"]
      interval: 5s
      timeout: 3s
      retries: 5
    restart: unless-stopped

networks:
  vote-tier:
    driver: bridge
  result-tier:
    driver: bridge

volumes:
  db-data:
    driver: local
```

---

## GitHub Actions CI Pipeline (`.github/workflows/ci.yaml`)

The continuous integration pipeline is triggered on every commit to `main` that touches service code or manifests.

### Matrix Pipeline Strategy
```yaml
name: CI - Build, Scan, and Push to Docker Hub

on:
  push:
    branches:
      - main
    paths:
      - "vote/**"
      - "result/**"
      - "worker/**"
      - "k8s/**"
      - ".github/workflows/ci.*"
  workflow_dispatch:

jobs:
  build-scan-push:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        service:
          - name: vote
            context: ./vote
          - name: result
            context: ./result
          - name: worker
            context: ./worker
```

### Pipeline Stages
1. **Checkout & Buildx:** Clones the repository and configures Docker Buildx with GitHub Actions cache backend (`type=gha`).
2. **Local Image Build:** Builds the image with `load: true` and `push: false`, tagging it with `scan-temp` for static security inspection.
3. **Vulnerability Analysis:** Trivy scans the local image (covered in detail in [Phase 2: Security & DevSecOps](phase-2-security-devsecops.md)).
4. **Registry Authentication:** Authenticates against Docker Hub using encrypted secrets (`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`).
5. **Publishing:** Publishes immutable tags using both `:latest` and the unique commit hash `:${{ github.sha }}`.

---

## Verification & Testing

### Local Docker Compose Verification
```bash
# Build and start all services in detached mode
docker compose up -d --build

# Verify container health status
docker compose ps

# Test endpoints
curl -I http://localhost:5000  # Vote UI
curl -I http://localhost:5001  # Result UI

# Teardown
docker compose down -v
```

### CI Pipeline Verification
Run a manual dispatch or push to verify parallel execution:
```bash
git push origin main
```
Output validation in GitHub Actions Console:
```text
build-scan-push (vote, ./vote)   - SUCCESS
build-scan-push (result, ./result) - SUCCESS
build-scan-push (worker, ./worker) - SUCCESS
```
Image tags pushed to Docker Hub:
- `rahulbastia/examplevotingapp_vote:latest`
- `rahulbastia/examplevotingapp_result:latest`
- `rahulbastia/examplevotingapp_worker:latest`
