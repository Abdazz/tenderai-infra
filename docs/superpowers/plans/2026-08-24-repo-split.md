# Séparation du monorepo en 3 repos — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extraire le monorepo TenderAI BF actuel (`/home/yulcom/web/tender-ai`) en 3 repositories GitHub indépendants — `tenderai-backend`, `tenderai-frontend`, `tenderai-infra` — chacun avec son historique git préservé, sa propre CI, et un déploiement fonctionnel en staging puis production.

**Architecture:** `git filter-repo` extrait, pour chaque cible, l'historique des chemins pertinents dans un clone jetable, avec renommage des Dockerfiles vers la racine de leur nouveau repo. Chaque repo reçoit ensuite une passe de réorganisation (Makefile scindé, Dockerfiles déplacés, docker-compose adapté, CI dédiée, CLAUDE.md scopé). Le repo `infra` ne construit aucune image : il consomme les images publiées par `backend`/`frontend` sur GHCR et pilote uniquement le déploiement (SSH, `workflow_dispatch`).

**Tech Stack:** git filter-repo, Docker/docker-compose, GitHub Actions, GHCR, gh CLI.

**Spec:** `docs/superpowers/specs/2026-08-24-repo-split-design.md`

## Global Constraints

- Historique git préservé pour le code source (backend `src/`/`tests/`/`alembic/`, frontend `frontend/`, et les Dockerfiles) via `git filter-repo` sur des clones jetables — jamais sur le monorepo original.
- Repos hébergés sous le compte GitHub `abdazz`, noms : `tenderai-backend`, `tenderai-frontend`, `tenderai-infra`.
- `infra/Dockerfile.ui` n'est pas migré (fichier mort confirmé).
- Aucune image n'est construite dans `tenderai-infra` — uniquement dans `tenderai-backend` (images `api`, `worker`) et `tenderai-frontend` (image `frontend`), publiées sous les noms GHCR existants (`ghcr.io/abdazz/tenderai-bf-{api,frontend,worker}`) — inchangés pour ne pas casser `docker-compose.server.yml`.
- Migrations Alembic déjà cuites dans l'image `api` via `COPY alembic/ alembic/` dans `Dockerfile.api` (vérifié) — le bind-mount `./alembic` dans `docker-compose.server.yml` est supprimé (devenu inutile et dangereux : il pourrait faire tourner un ancien tag d'image avec des migrations d'une autre version).
- CI de `tenderai-infra` : déploiement uniquement via `workflow_dispatch` manuel — jamais de déploiement automatique déclenché par un push sur `backend`/`frontend`.
- Le monorepo original n'est ni supprimé ni modifié pendant l'extraction ; il n'est archivé (lecture seule) qu'à la toute fin, après validation complète du cutover.
- Toute étape touchant les serveurs de production/staging (SSH, secrets GitHub, archivage du monorepo) requiert une confirmation explicite de l'utilisateur avant exécution — ce sont des actions sur un système partagé et difficilement réversibles.

---

## File Structure

### `tenderai-backend` (nouveau repo)
```
tenderai-backend/
├── src/tenderai_bf/          # historique préservé (filter-repo)
├── tests/                    # historique préservé
├── alembic/                  # historique préservé
├── alembic.ini                # historique préservé
├── pyproject.toml / poetry.lock   # historique préservé
├── ruff.toml                  # historique préservé
├── scripts/generate_presentation.py  # historique préservé
├── Dockerfile.api              # historique préservé (renommé depuis infra/Dockerfile.api)
├── Dockerfile.worker           # historique préservé (renommé depuis infra/Dockerfile.worker)
├── docker-compose.yml          # NOUVEAU : postgres/minio/createbuckets/api/worker uniquement
├── docker-compose.override.dev.yml  # NOUVEAU : ports exposés (api/postgres/minio)
├── Makefile                    # NOUVEAU : cibles dev/test/migrate/run-once (sans déploiement)
├── CLAUDE.md                   # NOUVEAU : scope backend
├── README.md                   # NOUVEAU : pointeur vers les 2 autres repos
└── .github/workflows/ci.yml    # NOUVEAU : lint+test+build+push api/worker
```

### `tenderai-frontend` (nouveau repo)
```
tenderai-frontend/
├── (contenu actuel de frontend/, remonté à la racine)  # historique préservé
├── Dockerfile.frontend          # historique préservé (renommé depuis infra/Dockerfile.frontend, COPY paths adaptés)
├── CLAUDE.md                    # NOUVEAU
├── README.md                    # NOUVEAU
└── .github/workflows/ci.yml     # NOUVEAU : lint+build+push frontend
```

### `tenderai-infra` (nouveau repo)
```
tenderai-infra/
├── docker-compose.yml           # NOUVEAU : full-stack, build depuis checkouts frères
├── docker-compose.server.yml    # historique préservé, bind-mount alembic retiré
├── docker-compose.override.dev.yml  # NOUVEAU : full-stack (incl. frontend)
├── nginx/                       # historique préservé (aplati depuis infra/nginx/)
├── apache2/                     # historique préservé (aplati depuis infra/apache2/)
├── postgres-init/.gitkeep       # NOUVEAU (le dossier original est vide)
├── settings.yaml                # historique préservé
├── .env.example / .env.prod.example / .env.staging.example  # historique préservé
├── scripts/deploy.sh, diagnose.sh, update-apache2.sh  # historique préservé
├── Makefile                     # NOUVEAU : cibles up/down/logs/deploy*
├── CLAUDE.md                    # NOUVEAU
├── README.md                    # NOUVEAU
└── .github/workflows/deploy.yml # NOUVEAU : workflow_dispatch uniquement
```

---

## Task 1: Prérequis — outillage et création des 3 repos GitHub vides

**Files:** aucun fichier dans le monorepo modifié.

- [ ] **Step 1: Installer git-filter-repo**

```bash
pip install --user git-filter-repo
git filter-repo --version
```
Attendu : affiche un numéro de version (ex: `git-filter-repo 2.x.x`). Si `pip install --user` ne met pas le binaire dans le PATH, ajouter `~/.local/bin` au PATH ou utiliser `python3 -m pip install --user git-filter-repo` puis appeler via `python3 -m git_filter_repo`.

- [ ] **Step 2: Créer les 3 repos GitHub vides (privés)**

```bash
gh repo create abdazz/tenderai-backend --private --description "TenderAI BF — backend API, pipelines LangGraph, IA"
gh repo create abdazz/tenderai-frontend --private --description "TenderAI BF — frontend Next.js"
gh repo create abdazz/tenderai-infra --private --description "TenderAI BF — Docker, CI/CD, déploiement, monitoring"
```

- [ ] **Step 3: Vérifier la création**

```bash
gh repo view abdazz/tenderai-backend --json name,visibility
gh repo view abdazz/tenderai-frontend --json name,visibility
gh repo view abdazz/tenderai-infra --json name,visibility
```
Attendu : les 3 commandes retournent un JSON avec `"visibility": "PRIVATE"` et le bon `name`, sans erreur 404.

---

## Task 2: Extraire et pousser `tenderai-backend`

**Files:**
- Create (dans un clone jetable, pas dans le monorepo) : historique filtré de `src/`, `tests/`, `alembic/`, `alembic.ini`, `pyproject.toml`, `poetry.lock`, `ruff.toml`, `scripts/generate_presentation.py`, `Dockerfile.api`, `Dockerfile.worker`.

- [ ] **Step 1: Cloner le monorepo dans un répertoire jetable**

```bash
rm -rf /tmp/tenderai-backend-extract
git clone /home/yulcom/web/tender-ai /tmp/tenderai-backend-extract
cd /tmp/tenderai-backend-extract
```

- [ ] **Step 2: Filtrer l'historique aux chemins backend, avec renommage des Dockerfiles**

```bash
git filter-repo \
  --path src/ \
  --path tests/ \
  --path alembic/ \
  --path alembic.ini \
  --path pyproject.toml \
  --path poetry.lock \
  --path ruff.toml \
  --path scripts/generate_presentation.py \
  --path infra/Dockerfile.api \
  --path infra/Dockerfile.worker \
  --path-rename infra/Dockerfile.api:Dockerfile.api \
  --path-rename infra/Dockerfile.worker:Dockerfile.worker
```

- [ ] **Step 3: Vérifier que l'historique est cohérent**

```bash
git log --oneline | wc -l
git log --oneline -- Dockerfile.api | head -3
ls src/tenderai_bf tests alembic Dockerfile.api Dockerfile.worker pyproject.toml
```
Attendu : le nombre de commits est > 0 et inférieur au nombre de commits du monorepo original (`git -C /home/yulcom/web/tender-ai log --oneline | wc -l`) ; `Dockerfile.api` a au moins un commit dans son historique (preuve que le renommage a conservé l'historique) ; tous les fichiers/dossiers listés existent.

- [ ] **Step 4: Pousser vers le nouveau repo**

```bash
git remote add origin git@github.com:abdazz/tenderai-backend.git
git branch -M main
git push -u origin main
```

- [ ] **Step 5: Vérifier côté GitHub**

```bash
gh repo view abdazz/tenderai-backend --json defaultBranchRef,pushedAt
```
Attendu : `defaultBranchRef.name` = `main`, `pushedAt` récent (quelques secondes).

---

## Task 3: Réorganiser `tenderai-backend` (Makefile, compose, CI, docs)

**Files:**
- Create: `Makefile` (racine du clone local de `tenderai-backend`)
- Create: `docker-compose.yml`
- Create: `docker-compose.override.dev.yml`
- Create: `CLAUDE.md`
- Create: `README.md`
- Create: `.github/workflows/ci.yml`

Travailler dans un clone local propre (pas `/tmp/tenderai-backend-extract`, qui a servi uniquement à l'extraction) :

```bash
rm -rf /tmp/tenderai-backend-work
git clone git@github.com:abdazz/tenderai-backend.git /tmp/tenderai-backend-work
cd /tmp/tenderai-backend-work
```

- [ ] **Step 1: Écrire le nouveau `Makefile`**

```makefile
.PHONY: help install install-dev lint format test type-check up down logs migrate revision run-once build-report test-email up-deps clean

help: ## Show this help message
	@echo "TenderAI BF Backend - Makefile Commands"
	@echo "========================================"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

install: ## Install dependencies with Poetry
	poetry install

install-dev: ## Install all dependencies including dev extras
	poetry install --extras "full" --with dev

lint: ## Run linting with ruff
	poetry run ruff check src tests
	poetry run ruff format --check src tests

format: ## Format code with ruff
	poetry run ruff format src tests
	poetry run ruff check --fix src tests

type-check: ## Run type checking with mypy
	poetry run mypy src/tenderai_bf

test: ## Run unit tests
	poetry run pytest tests/ -v

test-cov: ## Run tests with coverage
	poetry run pytest tests/ --cov=tenderai_bf --cov-report=html --cov-report=term

test-smoke: ## Run smoke tests only
	poetry run pytest tests/test_smoke.py -v

up: ## Start api+worker+deps with docker-compose
	docker-compose up -d

down: ## Stop all services
	docker-compose down

logs: ## Show logs from all services
	docker-compose logs -f

logs-api: ## Show API service logs
	docker-compose logs -f api

logs-worker: ## Show worker service logs
	docker-compose logs -f worker

up-deps: ## Start only database and storage dependencies
	docker-compose up -d postgres minio createbuckets

restart: ## Restart all services
	docker-compose restart

rebuild: ## Rebuild and restart services
	docker-compose down
	docker-compose build --no-cache
	docker-compose up -d

migrate: ## Apply database migrations
	poetry run alembic upgrade head

migrate-docker: ## Apply migrations using docker
	docker-compose exec api alembic upgrade head

revision: ## Create new migration
	@read -p "Enter migration message: " message; \
	poetry run alembic revision --autogenerate -m "$$message"

revision-docker: ## Create new migration using docker
	@read -p "Enter migration message: " message; \
	docker-compose exec api alembic revision --autogenerate -m "$$message"

reset-db: ## Reset database (WARNING: destroys data)
	@echo "WARNING: This will destroy all data. Are you sure? [y/N]" && read ans && [ $${ans:-N} = y ]
	docker-compose down -v
	docker-compose up -d postgres
	sleep 5
	$(MAKE) migrate

run-once: ## Execute pipeline once
	poetry run python -m tenderai_bf.cli run-once

run-once-docker: ## Execute pipeline once using docker
	docker-compose exec api python -m tenderai_bf.cli run-once

build-report: ## Generate report only
	poetry run python -m tenderai_bf.cli build-report

test-email: ## Test email configuration
	poetry run python -m tenderai_bf.cli test-email

init-db: ## Initialize database schema
	poetry run python -m tenderai_bf.cli init-db

scheduler: ## Start scheduler daemon
	poetry run python -m tenderai_bf.scheduler.schedule

health: ## Check API health
	@curl -f http://localhost:8000/health || echo "API not responding"

ps: ## Show running containers
	docker-compose ps

stats: ## Show container statistics
	docker stats

clean: ## Clean up temporary files and caches
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .ruff_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .mypy_cache -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.pyc" -delete 2>/dev/null || true

clean-docker: ## Clean up Docker resources
	docker-compose down -v --remove-orphans
	docker system prune -f

backup: ## Backup database
	@timestamp=$$(date +%Y%m%d_%H%M%S); \
	docker-compose exec postgres pg_dump -U tenderai tenderai_bf > backup_$$timestamp.sql; \
	echo "Backup created: backup_$$timestamp.sql"

shell: ## Open shell in API container
	docker-compose exec api bash

shell-db: ## Open database shell
	docker-compose exec postgres psql -U tenderai -d tenderai_bf

install-hooks: ## Install pre-commit hooks
	poetry run pre-commit install

version: ## Show current version
	@poetry version

dev: format lint test ## Run development checks (format, lint, test)

ci: lint type-check test ## Run CI checks

setup: install-dev up-deps migrate ## Complete development setup
	@echo "Development environment setup complete!"
```

- [ ] **Step 2: Écrire `docker-compose.yml`**

```yaml
services:
  postgres:
    image: postgres:16-alpine
    container_name: tenderai-postgres
    environment:
      POSTGRES_DB: ${DATABASE_NAME:-tenderai_bf}
      POSTGRES_USER: ${DATABASE_USER:-tenderai}
      POSTGRES_PASSWORD: ${DATABASE_PASSWORD:-tenderai_pass}
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale=C"
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DATABASE_USER:-tenderai} -d ${DATABASE_NAME:-tenderai_bf}"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped
    networks:
      - tenderai-network

  minio:
    image: minio/minio:latest
    container_name: tenderai-minio
    environment:
      MINIO_ROOT_USER: ${MINIO_ACCESS_KEY:-minioadmin}
      MINIO_ROOT_PASSWORD: ${MINIO_SECRET_KEY:-minioadmin123}
    volumes:
      - minio-data:/data
    command: server /data --console-address ":9001"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 20s
      retries: 3
    restart: unless-stopped
    networks:
      - tenderai-network

  createbuckets:
    image: minio/mc:latest
    container_name: tenderai-createbuckets
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      until /usr/bin/mc alias set myminio http://minio:9000 ${MINIO_ACCESS_KEY:-minioadmin} ${MINIO_SECRET_KEY:-minioadmin123}; do
        echo 'Waiting for MinIO...'; sleep 2;
      done;
      /usr/bin/mc mb myminio/${MINIO_BUCKET_NAME:-tenderai-bf} --ignore-existing;
      /usr/bin/mc anonymous set public myminio/${MINIO_BUCKET_NAME:-tenderai-bf}/reports;
      exit 0;
      "
    networks:
      - tenderai-network

  api:
    build:
      context: .
      dockerfile: Dockerfile.api
    container_name: tenderai-api
    env_file: .env
    environment:
      - DATABASE_URL=postgresql://${DATABASE_USER:-tenderai}:${DATABASE_PASSWORD:-tenderai_pass}@postgres:5432/${DATABASE_NAME:-tenderai_bf}
      - MINIO_ENDPOINT=minio:9000
      - MINIO_SECURE=false
      - HF_HOME=/app/cache/huggingface
      - TRANSFORMERS_CACHE=/app/cache/huggingface
      - TORCH_HOME=/app/cache/torch
      - EASYOCR_MODULE_PATH=/app/cache/easyocr
      - PASSLIB_SKIP_WRAPPING_BUG_CHECK=1
    volumes:
      - ./settings.yaml:/app/settings.yaml:ro
      - ./logs:/app/logs
      - api-cache:/app/cache
      - chroma-data:/app/data/chroma_db
      - ./src:/app/src
      - ./alembic:/app/alembic
      - ./tests:/app/tests
    command: ["uvicorn", "tenderai_bf.api.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
    depends_on:
      postgres:
        condition: service_healthy
      minio:
        condition: service_healthy
      createbuckets:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: unless-stopped
    networks:
      - tenderai-network

  worker:
    build:
      context: .
      dockerfile: Dockerfile.worker
    container_name: tenderai-worker
    env_file: .env
    environment:
      - DATABASE_URL=postgresql://${DATABASE_USER:-tenderai}:${DATABASE_PASSWORD:-tenderai_pass}@postgres:5432/${DATABASE_NAME:-tenderai_bf}
      - MINIO_ENDPOINT=minio:9000
      - MINIO_SECURE=false
      - PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
    volumes:
      - ./settings.yaml:/app/settings.yaml:ro
      - ./logs:/app/logs
      - worker-cache:/app/cache
      - worker-temp:/tmp/ocr
      - chroma-data:/app/data/chroma_db
      - ./src:/app/src
    depends_on:
      - postgres
      - minio
    restart: unless-stopped
    networks:
      - tenderai-network

volumes:
  postgres-data:
    driver: local
  minio-data:
    driver: local
  api-cache:
    driver: local
  worker-cache:
    driver: local
  worker-temp:
    driver: local
  chroma-data:
    driver: local

networks:
  tenderai-network:
    driver: bridge
```

Note : `settings.yaml` doit exister à la racine de `tenderai-backend` pour que ce compose fonctionne en local — Step 5 de cette tâche copie `.env.example` mais pas `settings.yaml` (qui appartient à `tenderai-infra`). Documenter dans le README que le dev doit copier `settings.yaml` depuis `tenderai-infra` (ou un exemplaire minimal) pour lancer `make up` localement — voir Step 4.

- [ ] **Step 3: Écrire `docker-compose.override.dev.yml`**

```yaml
services:
  postgres:
    ports:
      - "${POSTGRES_PORT:-5432}:5432"
  minio:
    ports:
      - "${MINIO_PORT:-9000}:9000"
      - "${MINIO_CONSOLE_PORT:-9001}:9001"
  api:
    ports:
      - "${API_PORT:-8000}:8000"
```

- [ ] **Step 4: Écrire `CLAUDE.md`**

```markdown
# CLAUDE.md

Backend de TenderAI BF — API FastAPI, pipeline LangGraph (`agents/graph.py`), classification IA, génération de rapports DOCX, livraison email.

Ce repo fait partie d'une architecture à 3 repos : `tenderai-backend` (ce repo), `tenderai-frontend`, `tenderai-infra`. Le développement local de ce repo est autonome (`make setup` démarre postgres/minio/api/worker). Pour un test d'intégration full-stack avec le frontend, voir `tenderai-infra`.

## Commands

```bash
make install-dev      # deps + dev tools
make dev               # format + lint + test
make up-deps            # postgres, minio, createbuckets
make migrate             # alembic upgrade head
make run-once             # exécute le pipeline une fois
make test                  # pytest tests/ -v
```

## Architecture

Voir le pipeline LangGraph dans `src/tenderai_bf/agents/graph.py` : `load_sources → fetch_listings → extract_item_links → fetch_items → parse_extract → classify → deduplicate → summarize → compose_report → email_report`.

## Config locale

`settings.yaml` (racine de ce repo, non versionné ici — copié depuis `tenderai-infra`) et `.env` (copié depuis `.env.example`) sont requis pour `make up`.
```

- [ ] **Step 5: Écrire `README.md`**

```markdown
# TenderAI BF — Backend

API, pipeline LangGraph, IA et traitements asynchrones du harvester d'appels d'offres TenderAI BF.

Fait partie de l'architecture à 3 repos :
- [`tenderai-frontend`](https://github.com/abdazz/tenderai-frontend) — interface Next.js
- [`tenderai-infra`](https://github.com/abdazz/tenderai-infra) — Docker, CI/CD, déploiement

## Démarrage rapide

```bash
cp .env.example .env
# Copier settings.yaml depuis tenderai-infra vers la racine de ce repo
make install-dev
make up-deps
make migrate
make run-once
```

Voir `CLAUDE.md` pour le détail des commandes disponibles.
```

- [ ] **Step 6: Créer `.env.example` minimal (copié du monorepo, filtré aux besoins backend)**

```bash
cp /home/yulcom/web/tender-ai/.env.example /tmp/tenderai-backend-work/.env.example
```

- [ ] **Step 7: Écrire la CI `.github/workflows/ci.yml`**

```yaml
name: Backend CI

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_PREFIX: ghcr.io/abdazz/tenderai-bf

jobs:
  lint-test:
    name: Lint & Test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - name: Install Poetry
        run: pip install poetry==1.8.3
      - name: Install dependencies
        run: poetry install --extras "full" --with dev
      - name: Lint
        run: |
          poetry run ruff check src tests
          poetry run ruff format --check src tests
      - name: Type check
        run: poetry run mypy src/tenderai_bf
      - name: Test
        run: poetry run pytest tests/ -v --no-cov

  build-and-push:
    name: Build & Push Images
    runs-on: ubuntu-latest
    needs: [lint-test]
    if: github.event_name == 'push'
    permissions:
      contents: read
      packages: write
    strategy:
      matrix:
        service: [api, worker]
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.IMAGE_PREFIX }}-${{ matrix.service }}
          tags: |
            type=ref,event=branch
            type=semver,pattern={{version}}
            type=sha,prefix={{branch}}-
            type=raw,value=latest,enable={{is_default_branch}}
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile.${{ matrix.service }}
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          platforms: linux/amd64
```

- [ ] **Step 8: Vérifier le build Docker en local**

```bash
cd /tmp/tenderai-backend-work
docker build -f Dockerfile.api -t tenderai-backend-api-test .
docker build -f Dockerfile.worker -t tenderai-backend-worker-test .
```
Attendu : les deux builds se terminent avec exit code 0.

- [ ] **Step 9: Commit et push**

```bash
git add Makefile docker-compose.yml docker-compose.override.dev.yml CLAUDE.md README.md .env.example .github/workflows/ci.yml
git commit -m "chore: reorganize repo layout post-split (Makefile, compose, CI, docs)"
git push origin main
```

---

## Task 4: Valider `tenderai-backend` en autonomie

**Files:** aucun (validation uniquement).

- [ ] **Step 1: Lancer le stack backend seul**

`tenderai-infra` n'existe pas encore à ce stade du plan (Tasks 8-9 viennent après), donc `settings.yaml` n'est pas disponible depuis ce repo. Pour cette validation, le copier depuis le monorepo original :

```bash
cd /tmp/tenderai-backend-work
cp .env.example .env
cp /home/yulcom/web/tender-ai/settings.yaml ./settings.yaml
cp docker-compose.override.dev.yml docker-compose.override.yml
make up-deps
```
Attendu : `postgres`, `minio`, `createbuckets` démarrent et passent `healthy` (`docker-compose ps`).

- [ ] **Step 2: Appliquer les migrations et démarrer l'API**

```bash
docker-compose up -d --build api
```
Attendu : le container `api` passe `healthy` dans les 60s (`docker-compose ps api`).

- [ ] **Step 3: Vérifier le endpoint santé**

```bash
curl -f http://localhost:8000/health
```
Attendu : réponse HTTP 200.

- [ ] **Step 4: Lancer la suite de tests**

```bash
make test
```
Attendu : tous les tests passent (0 échec).

- [ ] **Step 5: Arrêter le stack**

```bash
docker-compose down
```

---

## Task 5: Extraire et pousser `tenderai-frontend`

**Files:**
- Create (dans un clone jetable) : historique filtré de `frontend/` (renommé à la racine) et `infra/Dockerfile.frontend` (renommé `Dockerfile.frontend`).

- [ ] **Step 1: Cloner le monorepo dans un répertoire jetable**

```bash
rm -rf /tmp/tenderai-frontend-extract
git clone /home/yulcom/web/tender-ai /tmp/tenderai-frontend-extract
cd /tmp/tenderai-frontend-extract
```

- [ ] **Step 2: Filtrer l'historique, remonter `frontend/` à la racine, renommer le Dockerfile**

```bash
git filter-repo \
  --path frontend/ \
  --path infra/Dockerfile.frontend \
  --path-rename frontend/:'' \
  --path-rename infra/Dockerfile.frontend:Dockerfile.frontend
```

- [ ] **Step 3: Vérifier**

```bash
git log --oneline | wc -l
git log --oneline -- Dockerfile.frontend | head -3
ls package.json Dockerfile.frontend app lib
```
Attendu : commits > 0 ; `Dockerfile.frontend` a un historique ; `package.json`, `app/`, `lib/` existent à la racine.

- [ ] **Step 4: Pousser**

```bash
git remote add origin git@github.com:abdazz/tenderai-frontend.git
git branch -M main
git push -u origin main
```

- [ ] **Step 5: Vérifier côté GitHub**

```bash
gh repo view abdazz/tenderai-frontend --json defaultBranchRef,pushedAt
```
Attendu : `defaultBranchRef.name` = `main`.

---

## Task 6: Réorganiser `tenderai-frontend` (Dockerfile, CI, docs)

**Files:**
- Modify: `Dockerfile.frontend` (chemins `COPY` relatifs à la nouvelle racine)
- Create: `CLAUDE.md`, `README.md`, `.github/workflows/ci.yml`

```bash
rm -rf /tmp/tenderai-frontend-work
git clone git@github.com:abdazz/tenderai-frontend.git /tmp/tenderai-frontend-work
cd /tmp/tenderai-frontend-work
```

- [ ] **Step 1: Adapter les chemins `COPY` dans `Dockerfile.frontend`**

Le Dockerfile actuel copie depuis `frontend/` (chemin relatif au contexte racine du monorepo). Le contexte de build est désormais la racine de ce repo, donc `frontend/` doit devenir `.`.

Remplacer :
```dockerfile
COPY frontend/package.json frontend/package-lock.json* ./
```
par :
```dockerfile
COPY package.json package-lock.json* ./
```

Remplacer :
```dockerfile
COPY frontend/ .
```
par :
```dockerfile
COPY . .
```

Le reste du fichier (étapes `builder`, `runner`, `USER nextjs`, etc.) reste inchangé.

- [ ] **Step 2: Écrire `CLAUDE.md`**

```markdown
# CLAUDE.md

Frontend Next.js de TenderAI BF. Communique avec le backend (`tenderai-backend`) exclusivement via HTTP (routes proxy dans `app/api/proxy/*`).

Fait partie de l'architecture à 3 repos : `tenderai-backend`, `tenderai-frontend` (ce repo), `tenderai-infra`.

## Commands

```bash
npm install
npm run dev     # http://localhost:3000, attend NEXT_PUBLIC_API_URL
npm run build
npm run lint
```

## Config locale

`NEXT_PUBLIC_API_URL` doit pointer vers une instance backend en cours d'exécution (locale via `tenderai-backend`, ou staging).
```

- [ ] **Step 3: Écrire `README.md`**

```markdown
# TenderAI BF — Frontend

Interface Next.js du harvester d'appels d'offres TenderAI BF.

Fait partie de l'architecture à 3 repos :
- [`tenderai-backend`](https://github.com/abdazz/tenderai-backend) — API et pipelines
- [`tenderai-infra`](https://github.com/abdazz/tenderai-infra) — Docker, CI/CD, déploiement

## Démarrage rapide

```bash
npm install
NEXT_PUBLIC_API_URL=http://localhost:8000 npm run dev
```
```

- [ ] **Step 4: Écrire la CI `.github/workflows/ci.yml`**

```yaml
name: Frontend CI

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_PREFIX: ghcr.io/abdazz/tenderai-bf

jobs:
  lint-build:
    name: Lint & Build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - run: npm ci
      - run: npm run lint
      - run: npm run build

  build-and-push:
    name: Build & Push Image
    runs-on: ubuntu-latest
    needs: [lint-build]
    if: github.event_name == 'push'
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.IMAGE_PREFIX }}-frontend
          tags: |
            type=ref,event=branch
            type=semver,pattern={{version}}
            type=sha,prefix={{branch}}-
            type=raw,value=latest,enable={{is_default_branch}}
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile.frontend
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          platforms: linux/amd64
```

- [ ] **Step 5: Vérifier le build Docker en local**

```bash
docker build -f Dockerfile.frontend -t tenderai-frontend-test .
```
Attendu : exit code 0.

- [ ] **Step 6: Commit et push**

```bash
git add Dockerfile.frontend CLAUDE.md README.md .github/workflows/ci.yml
git commit -m "chore: adapt Dockerfile paths, add CI and docs post-split"
git push origin main
```

---

## Task 7: Valider `tenderai-frontend` en autonomie

**Files:** aucun (validation uniquement).

- [ ] **Step 1: Installer et builder**

```bash
cd /tmp/tenderai-frontend-work
npm install
npm run build
```
Attendu : build réussi, exit code 0.

- [ ] **Step 2: Lancer en dev contre un backend local**

Task 4 arrête son stack à la fin (Step 5) — il sera donc arrêté à ce stade. Le relancer :

```bash
cd /tmp/tenderai-backend-work
cp docker-compose.override.dev.yml docker-compose.override.yml 2>/dev/null || true
docker-compose up -d postgres minio createbuckets api
```
Attendre que `api` soit `healthy` (`docker-compose ps api`) avant de continuer.

```bash
NEXT_PUBLIC_API_URL=http://localhost:8000 npm run dev &
sleep 5
curl -f http://localhost:3000
kill %1
```
Attendu : réponse HTTP 200 sur `localhost:3000`.

---

## Task 8: Extraire et pousser `tenderai-infra`

**Files:**
- Create (dans un clone jetable) : historique filtré de `docker-compose.yml`, `docker-compose.server.yml`, `docker-compose.override.dev.yml`, `infra/nginx/`, `infra/apache2/`, `settings.yaml`, `.env.example`, `.env.prod.example`, `.env.staging.example`, `scripts/deploy.sh`, `scripts/diagnose.sh`, `scripts/update-apache2.sh`, aplatis.

- [ ] **Step 1: Cloner le monorepo dans un répertoire jetable**

```bash
rm -rf /tmp/tenderai-infra-extract
git clone /home/yulcom/web/tender-ai /tmp/tenderai-infra-extract
cd /tmp/tenderai-infra-extract
```

- [ ] **Step 2: Filtrer l'historique, aplatir `infra/*` et `scripts/*` retenus**

```bash
git filter-repo \
  --path docker-compose.yml \
  --path docker-compose.server.yml \
  --path docker-compose.override.dev.yml \
  --path infra/nginx/ \
  --path infra/apache2/ \
  --path settings.yaml \
  --path .env.example \
  --path .env.prod.example \
  --path .env.staging.example \
  --path scripts/deploy.sh \
  --path scripts/diagnose.sh \
  --path scripts/update-apache2.sh \
  --path-rename infra/nginx/:nginx/ \
  --path-rename infra/apache2/:apache2/ \
  --path-rename scripts/deploy.sh:scripts/deploy.sh \
  --path-rename scripts/diagnose.sh:scripts/diagnose.sh \
  --path-rename scripts/update-apache2.sh:scripts/update-apache2.sh
```

- [ ] **Step 3: Vérifier**

```bash
git log --oneline | wc -l
ls docker-compose.yml docker-compose.server.yml nginx apache2 settings.yaml scripts
```
Attendu : commits > 0 ; tous les chemins existent à la racine (sans préfixe `infra/`).

- [ ] **Step 4: Pousser**

```bash
git remote add origin git@github.com:abdazz/tenderai-infra.git
git branch -M main
git push -u origin main
```

- [ ] **Step 5: Vérifier côté GitHub**

```bash
gh repo view abdazz/tenderai-infra --json defaultBranchRef,pushedAt
```
Attendu : `defaultBranchRef.name` = `main`.

---

## Task 9: Réorganiser `tenderai-infra` (compose full-stack, Makefile, CI déploiement, docs)

**Files:**
- Modify: `docker-compose.server.yml` (retrait du bind-mount `./alembic`)
- Create: `docker-compose.yml` (réécrit, full-stack, build depuis checkouts frères)
- Create: `docker-compose.override.dev.yml` (réécrit, full-stack)
- Create: `Makefile`, `CLAUDE.md`, `README.md`, `.github/workflows/deploy.yml`
- Create: `postgres-init/.gitkeep`

```bash
rm -rf /tmp/tenderai-infra-work
git clone git@github.com:abdazz/tenderai-infra.git /tmp/tenderai-infra-work
cd /tmp/tenderai-infra-work
```

- [ ] **Step 1: Retirer le bind-mount `./alembic` de `docker-compose.server.yml`**

Dans le service `api` de `docker-compose.server.yml`, la ligne suivante est présente (confirmé) et doit être supprimée :
```yaml
      - ./alembic:/app/alembic
```
Les migrations sont désormais cuites dans l'image `api` (`COPY alembic/ alembic/` dans `Dockerfile.api`, vérifié en Task 2). Vérifier après coup avec `grep -n alembic docker-compose.server.yml` — la commande ne doit plus rien retourner pour le service `api`.

- [ ] **Step 2: Réécrire `docker-compose.yml` en full-stack, build depuis checkouts frères**

```yaml
services:
  postgres:
    image: postgres:16-alpine
    container_name: tenderai-postgres
    environment:
      POSTGRES_DB: ${DATABASE_NAME:-tenderai_bf}
      POSTGRES_USER: ${DATABASE_USER:-tenderai}
      POSTGRES_PASSWORD: ${DATABASE_PASSWORD:-tenderai_pass}
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale=C"
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - ./postgres-init:/docker-entrypoint-initdb.d
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DATABASE_USER:-tenderai} -d ${DATABASE_NAME:-tenderai_bf}"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped
    networks:
      - tenderai-network

  minio:
    image: minio/minio:latest
    container_name: tenderai-minio
    environment:
      MINIO_ROOT_USER: ${MINIO_ACCESS_KEY:-minioadmin}
      MINIO_ROOT_PASSWORD: ${MINIO_SECRET_KEY:-minioadmin123}
    volumes:
      - minio-data:/data
    command: server /data --console-address ":9001"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 20s
      retries: 3
    restart: unless-stopped
    networks:
      - tenderai-network

  createbuckets:
    image: minio/mc:latest
    container_name: tenderai-createbuckets
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      until /usr/bin/mc alias set myminio http://minio:9000 ${MINIO_ACCESS_KEY:-minioadmin} ${MINIO_SECRET_KEY:-minioadmin123}; do
        echo 'Waiting for MinIO...'; sleep 2;
      done;
      /usr/bin/mc mb myminio/${MINIO_BUCKET_NAME:-tenderai-bf} --ignore-existing;
      /usr/bin/mc anonymous set public myminio/${MINIO_BUCKET_NAME:-tenderai-bf}/reports;
      exit 0;
      "
    networks:
      - tenderai-network

  api:
    build:
      context: ../tenderai-backend
      dockerfile: Dockerfile.api
    container_name: tenderai-api
    env_file: .env
    environment:
      - DATABASE_URL=postgresql://${DATABASE_USER:-tenderai}:${DATABASE_PASSWORD:-tenderai_pass}@postgres:5432/${DATABASE_NAME:-tenderai_bf}
      - MINIO_ENDPOINT=minio:9000
      - MINIO_SECURE=false
      - PASSLIB_SKIP_WRAPPING_BUG_CHECK=1
    volumes:
      - ./settings.yaml:/app/settings.yaml:ro
      - ./logs:/app/logs
      - api-cache:/app/cache
      - chroma-data:/app/data/chroma_db
    depends_on:
      postgres:
        condition: service_healthy
      minio:
        condition: service_healthy
      createbuckets:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    restart: unless-stopped
    networks:
      - tenderai-network

  frontend:
    build:
      context: ../tenderai-frontend
      dockerfile: Dockerfile.frontend
    container_name: tenderai-frontend
    env_file: .env
    environment:
      - API_URL=http://api:8000
      - NEXT_PUBLIC_API_URL=http://api:8000
      - NEXT_PUBLIC_FRONTEND_URL=${FRONTEND_URL:-http://localhost:3000}
      - JWT_SECRET=${TENDERAI_JWT_SECRET}
    depends_on:
      - api
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://127.0.0.1:3000 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
    restart: unless-stopped
    networks:
      - tenderai-network

  worker:
    build:
      context: ../tenderai-backend
      dockerfile: Dockerfile.worker
    container_name: tenderai-worker
    env_file: .env
    environment:
      - DATABASE_URL=postgresql://${DATABASE_USER:-tenderai}:${DATABASE_PASSWORD:-tenderai_pass}@postgres:5432/${DATABASE_NAME:-tenderai_bf}
      - MINIO_ENDPOINT=minio:9000
      - MINIO_SECURE=false
      - PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
    volumes:
      - ./settings.yaml:/app/settings.yaml:ro
      - ./logs:/app/logs
      - worker-cache:/app/cache
      - worker-temp:/tmp/ocr
      - chroma-data:/app/data/chroma_db
    depends_on:
      - postgres
      - minio
    restart: unless-stopped
    networks:
      - tenderai-network

volumes:
  postgres-data:
    driver: local
  minio-data:
    driver: local
  api-cache:
    driver: local
  worker-cache:
    driver: local
  worker-temp:
    driver: local
  chroma-data:
    driver: local

networks:
  tenderai-network:
    driver: bridge
```

Note : ce fichier suppose que `tenderai-backend` et `tenderai-frontend` sont clonés en tant que répertoires frères de `tenderai-infra` (`../tenderai-backend`, `../tenderai-frontend`) — convention documentée dans `README.md` (Step 5).

- [ ] **Step 3: Réécrire `docker-compose.override.dev.yml` en full-stack**

```yaml
services:
  postgres:
    ports:
      - "${POSTGRES_PORT:-5432}:5432"
  minio:
    ports:
      - "${MINIO_PORT:-9000}:9000"
      - "${MINIO_CONSOLE_PORT:-9001}:9001"
  api:
    ports:
      - "${API_PORT:-8000}:8000"
  frontend:
    ports:
      - "${FRONTEND_PORT:-3000}:3000"
```

- [ ] **Step 4: Créer `postgres-init/.gitkeep`**

```bash
mkdir -p postgres-init
touch postgres-init/.gitkeep
```

- [ ] **Step 5: Écrire `Makefile`**

```makefile
.PHONY: help up down logs deploy deploy-staging backup

help: ## Show this help message
	@echo "TenderAI BF Infra - Makefile Commands"
	@echo "======================================"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

up: ## Start full stack (requires ../tenderai-backend and ../tenderai-frontend siblings)
	docker-compose up -d

down: ## Stop full stack
	docker-compose down

logs: ## Show logs from all services
	docker-compose logs -f

rebuild: ## Rebuild and restart full stack
	docker-compose down
	docker-compose build --no-cache
	docker-compose up -d

health: ## Check service health
	@curl -f http://localhost:8000/health || echo "API not responding"
	@curl -f http://localhost:3000 || echo "Frontend not responding"

ps: ## Show running containers
	docker-compose ps

deploy: ## Deploy to production (main branch)
	./scripts/deploy.sh main deploy

deploy-staging: ## Deploy to staging
	./scripts/deploy.sh develop deploy

deploy-status: ## Show deployment status
	./scripts/deploy.sh main status

deploy-logs: ## Show deployment logs (default: api)
	./scripts/deploy.sh main logs api

backup: ## Create database backup
	./scripts/deploy.sh main backup

clean-docker: ## Clean up Docker resources
	docker-compose down -v --remove-orphans
	docker system prune -f
```

- [ ] **Step 6: Écrire `CLAUDE.md`**

```markdown
# CLAUDE.md

Infrastructure de TenderAI BF : Docker, nginx/apache2, configuration opérationnelle (`settings.yaml`), CI/CD de déploiement. Ce repo ne contient aucun code applicatif et ne construit aucune image — il consomme les images publiées par `tenderai-backend` (api, worker) et `tenderai-frontend` (frontend) sur GHCR.

Fait partie de l'architecture à 3 repos : `tenderai-backend`, `tenderai-frontend`, `tenderai-infra` (ce repo).

## Développement local full-stack

Nécessite `tenderai-backend` et `tenderai-frontend` clonés en répertoires frères de ce repo :
```
dev/
├── tenderai-backend/
├── tenderai-frontend/
└── tenderai-infra/        ← ce repo
```

```bash
cp .env.example .env
cp docker-compose.override.dev.yml docker-compose.override.yml
make up
make health
```

## Déploiement

Le déploiement (staging/production) se fait exclusivement via `workflow_dispatch` sur `.github/workflows/deploy.yml` — jamais automatique. Choisir l'environnement et le tag d'image à déployer (défaut `latest`).
```

- [ ] **Step 7: Écrire `README.md`**

```markdown
# TenderAI BF — Infra

Docker, CI/CD, déploiement, monitoring et configuration opérationnelle de TenderAI BF.

Fait partie de l'architecture à 3 repos :
- [`tenderai-backend`](https://github.com/abdazz/tenderai-backend) — API et pipelines
- [`tenderai-frontend`](https://github.com/abdazz/tenderai-frontend) — interface Next.js

## Développement local full-stack

Cloner les 3 repos dans un même dossier parent :
```bash
mkdir -p ~/dev/tenderai && cd ~/dev/tenderai
git clone git@github.com:abdazz/tenderai-backend.git
git clone git@github.com:abdazz/tenderai-frontend.git
git clone git@github.com:abdazz/tenderai-infra.git
cd tenderai-infra
cp .env.example .env
cp docker-compose.override.dev.yml docker-compose.override.yml
make up
```

## Déploiement

Voir `CLAUDE.md` — déclenchement manuel via `workflow_dispatch` uniquement.
```

- [ ] **Step 8: Écrire la CI `.github/workflows/deploy.yml`**

```yaml
name: Deploy

on:
  workflow_dispatch:
    inputs:
      environment:
        description: 'Environment to deploy'
        required: true
        type: choice
        options:
          - production
          - staging
      image_tag:
        description: 'Image tag to deploy'
        required: false
        type: string
        default: 'latest'

jobs:
  deploy-production:
    name: Deploy to Production
    runs-on: ubuntu-latest
    if: inputs.environment == 'production'
    environment:
      name: production
      url: https://tender-ai.yulcom.net
    steps:
      - uses: actions/checkout@v4
      - uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}
      - name: Add server to known hosts
        env:
          HOST: ${{ secrets.PRODUCTION_HOST }}
          PORT: ${{ secrets.PRODUCTION_SSH_PORT || 22 }}
        run: |
          mkdir -p ~/.ssh
          ssh-keyscan -H -p ${PORT} ${HOST} >> ~/.ssh/known_hosts
      - name: Deploy
        env:
          HOST: ${{ secrets.PRODUCTION_HOST }}
          USER: ${{ secrets.PRODUCTION_USER }}
          PORT: ${{ secrets.PRODUCTION_SSH_PORT || 22 }}
          DEPLOY_PATH: ${{ secrets.PRODUCTION_DEPLOY_PATH || '/opt/tenderai-infra' }}
          IMAGE_TAG: ${{ inputs.image_tag }}
          TENDERAI_JWT_SECRET: ${{ secrets.TENDERAI_JWT_SECRET }}
          TENDERAI_ADMIN_PASSWORD: ${{ secrets.TENDERAI_ADMIN_PASSWORD }}
        run: |
          ssh -p ${PORT} ${USER}@${HOST} "bash -s" << ENDSSH
            set -e
            cd ${DEPLOY_PATH}
            git checkout main
            git pull origin main
            sed -i "s|^TENDERAI_JWT_SECRET=.*|TENDERAI_JWT_SECRET=${TENDERAI_JWT_SECRET}|" .env.prod
            sed -i "s|^TENDERAI_ADMIN_PASSWORD=.*|TENDERAI_ADMIN_PASSWORD=${TENDERAI_ADMIN_PASSWORD}|" .env.prod
            sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${IMAGE_TAG}|" .env.prod
            echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin
            set -a; source .env.prod; set +a
            docker compose --env-file .env.prod down --remove-orphans || true
            mkdir -p logs/nodes 2>/dev/null || true
            docker compose --env-file .env.prod pull api frontend worker || true
            docker compose --env-file .env.prod up -d postgres minio createbuckets
            until docker compose --env-file .env.prod exec -T postgres pg_isready -U \${POSTGRES_USER:-tenderai} -d \${POSTGRES_DB:-tenderai_bf} </dev/null; do sleep 3; done
            for i in \$(seq 1 20); do
              docker compose --env-file .env.prod exec -T minio curl -sf http://localhost:9000/minio/health/live </dev/null > /dev/null 2>&1 && break
              [ \$i -eq 20 ] && exit 1
              sleep 5
            done
            docker compose --env-file .env.prod run --no-deps --rm api alembic upgrade head </dev/null
            docker compose --env-file .env.prod run --no-deps --rm api tenderai create-admin </dev/null || true
            docker compose --env-file .env.prod run --no-deps --rm api tenderai seed-sources </dev/null || true
            docker compose --env-file .env.prod up -d api frontend worker nginx
            for i in \$(seq 1 18); do
              docker compose --env-file .env.prod exec -T api curl -sf http://localhost:8000/health </dev/null > /dev/null 2>&1 && break
              [ \$i -eq 18 ] && exit 1
              sleep 10
            done
            docker image prune -f
          ENDSSH
      - name: Health check
        run: |
          sleep 10
          curl -f https://tender-ai.yulcom.net/health

  deploy-staging:
    name: Deploy to Staging
    runs-on: ubuntu-latest
    if: inputs.environment == 'staging'
    environment:
      name: staging
      url: https://stagingtenderai.yulcom.net
    steps:
      - uses: actions/checkout@v4
      - uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}
      - name: Add server to known hosts
        env:
          HOST: ${{ secrets.PRODUCTION_HOST }}
          PORT: ${{ secrets.PRODUCTION_SSH_PORT || 22 }}
        run: |
          mkdir -p ~/.ssh
          ssh-keyscan -H -p ${PORT} ${HOST} >> ~/.ssh/known_hosts
      - name: Deploy
        env:
          HOST: ${{ secrets.PRODUCTION_HOST }}
          USER: ${{ secrets.PRODUCTION_USER }}
          PORT: ${{ secrets.PRODUCTION_SSH_PORT || 22 }}
          DEPLOY_PATH: ${{ secrets.STAGING_DEPLOY_PATH || '/opt/tenderai-infra-staging' }}
          IMAGE_TAG: ${{ inputs.image_tag }}
          TENDERAI_JWT_SECRET: ${{ secrets.TENDERAI_JWT_SECRET }}
          TENDERAI_ADMIN_PASSWORD: ${{ secrets.TENDERAI_ADMIN_PASSWORD }}
        run: |
          ssh -p ${PORT} ${USER}@${HOST} "bash -s" << ENDSSH
            set -e
            cd ${DEPLOY_PATH}
            git config pull.ff only
            git pull origin main
            sed -i "s|^TENDERAI_JWT_SECRET=.*|TENDERAI_JWT_SECRET=${TENDERAI_JWT_SECRET}|" .env.staging
            sed -i "s|^TENDERAI_ADMIN_PASSWORD=.*|TENDERAI_ADMIN_PASSWORD=${TENDERAI_ADMIN_PASSWORD}|" .env.staging
            sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${IMAGE_TAG}|" .env.staging
            echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin
            set -a; source .env.staging; set +a
            docker compose --env-file .env.staging down --remove-orphans || true
            docker compose --env-file .env.staging pull api frontend worker || true
            docker compose --env-file .env.staging up -d postgres minio createbuckets
            until docker compose --env-file .env.staging exec -T postgres pg_isready -U \${POSTGRES_USER:-tenderai} -d \${POSTGRES_DB:-tenderai_bf} </dev/null; do sleep 3; done
            docker compose --env-file .env.staging run --no-deps --rm api alembic upgrade head </dev/null
            docker compose --env-file .env.staging run --no-deps --rm api tenderai create-admin </dev/null || true
            docker compose --env-file .env.staging run --no-deps --rm api tenderai seed-sources </dev/null || true
            docker compose --env-file .env.staging up -d api frontend worker nginx
            docker image prune -f
          ENDSSH
      - name: Health check
        run: |
          sleep 30
          curl -f https://stagingtenderai.yulcom.net/health
```

- [ ] **Step 9: Commit et push**

```bash
git add docker-compose.server.yml docker-compose.yml docker-compose.override.dev.yml postgres-init Makefile CLAUDE.md README.md .github/workflows/deploy.yml
git commit -m "chore: rewrite compose for polyrepo (sibling builds), add deploy CI, docs"
git push origin main
```

---

## Task 10: Valider `tenderai-infra` en autonomie (checkouts frères)

**Files:** aucun (validation uniquement).

- [ ] **Step 1: Organiser les 3 clones en frères**

```bash
mkdir -p /tmp/tenderai-dev
cp -r /tmp/tenderai-backend-work /tmp/tenderai-dev/tenderai-backend
cp -r /tmp/tenderai-frontend-work /tmp/tenderai-dev/tenderai-frontend
cp -r /tmp/tenderai-infra-work /tmp/tenderai-dev/tenderai-infra
```

- [ ] **Step 2: Copier `settings.yaml` dans `tenderai-backend` (nécessaire pour Task 4, refaire ici si besoin) et lancer le stack full**

```bash
cd /tmp/tenderai-dev/tenderai-infra
cp .env.example .env
cp docker-compose.override.dev.yml docker-compose.override.yml
make up
```
Attendu : `docker-compose ps` montre `postgres`, `minio`, `createbuckets`, `api`, `worker`, `frontend` — `api` et `frontend` `healthy` sous 2 minutes.

- [ ] **Step 3: Vérifier la santé full-stack**

```bash
make health
```
Attendu : les deux `curl` retournent HTTP 200 (pas de message "not responding").

- [ ] **Step 4: Arrêter le stack**

```bash
make down
```

---

## Task 11: Migrer les secrets GitHub Actions vers `tenderai-infra` ⚠️ confirmation utilisateur requise

**Files:** aucun fichier — secrets GitHub uniquement.

⚠️ Cette tâche manipule des identifiants de production (clé SSH, mot de passe admin, secret JWT). Ne pas l'exécuter automatiquement — l'utilisateur doit fournir les valeurs lui-même, elles ne doivent jamais transiter par un agent ou un log.

- [ ] **Step 1: Lister les secrets actuellement configurés sur le monorepo**

```bash
gh secret list --repo abdazz/tender-ai
```
Attendu : liste incluant `SSH_PRIVATE_KEY`, `PRODUCTION_HOST`, `PRODUCTION_USER`, `PRODUCTION_SSH_PORT`, `PRODUCTION_DEPLOY_PATH`, `STAGING_DEPLOY_PATH`, `TENDERAI_JWT_SECRET`, `TENDERAI_ADMIN_PASSWORD`.

- [ ] **Step 2: L'utilisateur copie chaque secret vers `tenderai-infra`**

Pour chaque secret listé à l'étape 1, l'utilisateur exécute (valeur saisie interactivement, jamais en argument de ligne de commande) :
```bash
gh secret set NOM_DU_SECRET --repo abdazz/tenderai-infra
```

- [ ] **Step 3: Vérifier que les secrets sont présents sur `tenderai-infra`**

```bash
gh secret list --repo abdazz/tenderai-infra
```
Attendu : mêmes noms que Step 1.

- [ ] **Step 4: Configurer les GitHub Environments `production` et `staging` sur `tenderai-infra`**

Dans l'UI GitHub (`Settings > Environments`), recréer les environnements `production` et `staging` avec les mêmes règles de protection (reviewers requis, etc.) que sur le monorepo actuel. Étape manuelle, non scriptable via `gh` de façon fiable pour les règles de protection — l'utilisateur la réalise lui-même.

---

## Task 12: Cutover staging ⚠️ confirmation utilisateur requise

**Files:** aucun fichier local — actions sur le serveur staging.

⚠️ Nécessite un accès SSH au serveur staging. Confirmer avec l'utilisateur avant exécution — c'est un changement sur un système partagé.

- [ ] **Step 1: Créer le nouveau répertoire de déploiement sur le serveur staging**

```bash
ssh <staging-host> "mkdir -p /opt/tenderai-infra-staging"
ssh <staging-host> "git clone git@github.com:abdazz/tenderai-infra.git /opt/tenderai-infra-staging"
```

- [ ] **Step 2: Copier la configuration existante depuis l'ancien répertoire de déploiement**

Le chemin exact de l'ancien `DEPLOY_PATH` staging n'est pas connu à l'écriture de ce plan (il vit dans le secret GitHub `STAGING_DEPLOY_PATH`, valeur non lisible via `gh secret list`). Le récupérer auprès de l'utilisateur ou via `gh secret list --repo abdazz/tender-ai` (noms seulement) puis en interrogeant l'utilisateur pour la valeur, avant de lancer :

```bash
ssh <staging-host> "cp <ancien-deploy-path-staging>/.env.staging /opt/tenderai-infra-staging/.env.staging"
ssh <staging-host> "cp <ancien-deploy-path-staging>/settings.yaml /opt/tenderai-infra-staging/settings.yaml"
```

- [ ] **Step 3: Déclencher le déploiement staging via `workflow_dispatch`**

```bash
gh workflow run deploy.yml --repo abdazz/tenderai-infra -f environment=staging -f image_tag=latest
```

- [ ] **Step 4: Suivre l'exécution et vérifier la santé**

```bash
gh run watch --repo abdazz/tenderai-infra
curl -f https://stagingtenderai.yulcom.net/health
```
Attendu : le workflow se termine en succès, le endpoint santé répond HTTP 200.

- [ ] **Step 5: Valider manuellement un parcours applicatif complet sur staging**

Se connecter à `https://stagingtenderai.yulcom.net`, vérifier login, affichage des appels d'offres, génération de rapport — avant de passer au cutover production.

---

## Task 13: Cutover production ⚠️ confirmation utilisateur explicite requise

**Files:** aucun fichier local — actions sur le serveur de production.

⚠️ **Ne pas exécuter sans confirmation explicite de l'utilisateur.** Ce cutover affecte l'application en production (`tender-ai.yulcom.net`). Ne procéder qu'après validation complète de la Task 12 (staging).

- [ ] **Step 1: Créer le nouveau répertoire de déploiement sur le serveur de production**

```bash
ssh <production-host> "mkdir -p /opt/tenderai-infra"
ssh <production-host> "git clone git@github.com:abdazz/tenderai-infra.git /opt/tenderai-infra"
```

- [ ] **Step 2: Copier la configuration existante**

L'ancien répertoire de déploiement production est `/home/tender-ai/Tender-AI` (confirmé, distinct du chemin de dev local) :

```bash
ssh <production-host> "cp /home/tender-ai/Tender-AI/.env.prod /opt/tenderai-infra/.env.prod"
ssh <production-host> "cp /home/tender-ai/Tender-AI/settings.yaml /opt/tenderai-infra/settings.yaml"
```

- [ ] **Step 3: Déclencher le déploiement production via `workflow_dispatch`**

```bash
gh workflow run deploy.yml --repo abdazz/tenderai-infra -f environment=production -f image_tag=latest
```

- [ ] **Step 4: Suivre l'exécution et vérifier la santé**

```bash
gh run watch --repo abdazz/tenderai-infra
curl -f https://tender-ai.yulcom.net/health
```
Attendu : le workflow se termine en succès, le endpoint santé répond HTTP 200.

- [ ] **Step 5: Valider manuellement un parcours applicatif complet en production**

Mêmes vérifications que Task 12 Step 5, sur `https://tender-ai.yulcom.net`.

- [ ] **Step 6: Désactiver l'ancien workflow CI/CD du monorepo**

```bash
gh workflow disable ci-cd.yml --repo abdazz/tender-ai
```
Empêche tout déploiement accidentel depuis l'ancien monorepo une fois le cutover validé.

---

## Task 14: Archiver le monorepo original ⚠️ confirmation utilisateur explicite requise

**Files:** `README.md` du monorepo original (`/home/yulcom/web/tender-ai`).

⚠️ Ne procéder qu'après confirmation explicite de l'utilisateur, et uniquement une fois la Task 13 validée en production depuis au moins quelques jours (fenêtre de retour arrière raisonnable).

- [ ] **Step 1: Ajouter un README de redirection**

Modifier `/home/yulcom/web/tender-ai/README.md` : ajouter en tout premier, avant tout le reste du contenu :

```markdown
> **⚠️ Ce repo est archivé.** Le code a été séparé en 3 repos le 2026-08-24 :
> - [`tenderai-backend`](https://github.com/abdazz/tenderai-backend)
> - [`tenderai-frontend`](https://github.com/abdazz/tenderai-frontend)
> - [`tenderai-infra`](https://github.com/abdazz/tenderai-infra)
>
> Cet historique est conservé pour référence uniquement.

```

- [ ] **Step 2: Commit**

```bash
cd /home/yulcom/web/tender-ai
git add README.md
git commit -m "docs: mark monorepo as archived, point to split repos"
git push origin main
```

- [ ] **Step 3: Archiver le repo sur GitHub (lecture seule)**

```bash
gh repo archive abdazz/tender-ai
```

---

## Nettoyage des clones de travail temporaires

- [ ] **Step final: Supprimer les répertoires jetables `/tmp`**

```bash
rm -rf /tmp/tenderai-backend-extract /tmp/tenderai-frontend-extract /tmp/tenderai-infra-extract
```
(`/tmp/tenderai-backend-work`, `/tmp/tenderai-frontend-work`, `/tmp/tenderai-infra-work` et `/tmp/tenderai-dev/` peuvent être conservés ou déplacés vers l'emplacement définitif de développement local choisi par l'utilisateur, ex. `~/dev/tenderai/`.)
