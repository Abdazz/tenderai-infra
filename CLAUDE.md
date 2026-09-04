# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this directory.

## Project Overview

TenderAI is a multi-agent RFP/tender harvester, multi-company/multi-tenant and multi-country. It autonomously scrapes procurement portals, classifies opportunities using AI, deduplicates them, generates French-language DOCX reports, and delivers them via email. Stack: Python 3.11+, LangGraph, FastAPI, Next.js (React frontend), PostgreSQL, MinIO, APScheduler.

**This directory is itself the `tenderai-infra` git repo** (Docker, nginx/apache2, operational config, deploy workflow — see "Infra" section below). `tenderai-backend` and `tenderai-frontend` are nested inside it as their own independent git checkouts (separate remotes, separate history) — gitignored from this repo's perspective, never tracked here:

```
tenderai/                    ← this repo (tenderai-infra)
├── tenderai-backend/        # FastAPI + LangGraph pipeline (Python) — own git repo, gitignored
├── tenderai-frontend/       # Next.js dashboard (React/TypeScript) — own git repo, gitignored
├── docker-compose*.yml, nginx/, apache2/, settings.yaml, .github/  # infra content, tracked here
└── docs/                    # chantier tracking, audit reports, specs/plans — tracked here
```

Each of the three repos has its **own `CLAUDE.md`** with repo-specific commands (poetry/make for backend, npm for frontend; infra's own commands are in the "Infra" section below) — read the one for the repo you're working in for exact build/test/lint/deploy commands. This file's non-infra sections cover what's shared across all three.

`docs/` (this repo) holds `docs/PROJECT_STATUS.md`, the chantier tracking doc, and `docs/superpowers/specs|plans/*` design docs — check there for project history and current chantier status. The original monorepo (`tender-ai`, at `/home/yulcom/web/tender-ai`) is retired planning history predating this split — no active development or tracking happens there anymore.

## Git workflow (mandatory)

Every repo in this project (this one, `tenderai-backend`, `tenderai-frontend`) **must have a `staging` branch**. All work lands on `staging` first — where it gets deployed and exercised as a real test — and only moves to `main` after that validation passes. Never merge or push feature work directly to `main`; `main` only receives already-validated work promoted from `staging`.

Work that spans more than one repo (e.g. a backend API change plus its matching frontend consumer) should be merged to each repo's `staging` and deployed together via this repo's deploy workflow, then verified live before considering the change complete.

See `docs/PROJECT_STATUS.md` for the current state of each chantier.

## Multi-tenant model (cross-cutting, backend + frontend)

- Roles: `super_admin` (company_id=NULL, sees everything), `company_admin`, `company_viewer` — scoped to one company.
- JWT carries a `company_id` claim; backend enforces scoping via `require_company_scope`/`CompanyScopedUser` (403, not 404, on cross-tenant access).
- Frontend mirrors this with a `CompanyContext` (nested around the pre-existing `CountryContext`) and a `CompanySelector` shown only to `super_admin`.

## Staging environment

- Live at `https://stagingtenderai.yulcom.net`.
- Deployed via this repo's `deploy.yml` GitHub Actions workflow (`gh workflow run deploy.yml --repo <repo> --ref staging -f environment=staging -f image_tag=staging`).
- GHCR (GitHub Container Registry) images require a one-time manual "Manage Actions access" grant per package in the GitHub web UI — no CLI/API path exists for this on a personal account.

## Infra (this repo's own scope)

Infrastructure de TenderAI : Docker, nginx/apache2, configuration opérationnelle (`settings.yaml`), CI/CD de déploiement. Ce repo ne contient aucun code applicatif et ne construit aucune image — il consomme les images publiées par `tenderai-backend` (api, worker) et `tenderai-frontend` (frontend) sur GHCR.

### Développement local full-stack

`tenderai-backend` et `tenderai-frontend` sont clonés **comme sous-dossiers de ce repo** (voir layout ci-dessus), gitignorés depuis ici :

```bash
cd tenderai
git clone git@github.com:abdazz/tenderai-backend.git
git clone git@github.com:abdazz/tenderai-frontend.git
cp .env.example .env
cp docker-compose.override.dev.yml docker-compose.override.yml
make up
make health
```

### Déploiement

Le déploiement (staging/production) se fait exclusivement via `workflow_dispatch` sur `.github/workflows/deploy.yml` — jamais automatique. Choisir l'environnement et le tag d'image à déployer (défaut `latest`). Le déploiement s'exécute contre un checkout indépendant de ce repo sur le serveur (`/opt/tenderai-infra*`) — il ne dépend d'aucun chemin relatif vers `tenderai-backend`/`tenderai-frontend` (les images Docker prébuilt sont tirées de GHCR, pas construites sur le serveur).
