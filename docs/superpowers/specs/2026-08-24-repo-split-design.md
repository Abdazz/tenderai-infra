# Séparation du monorepo TenderAI BF en 3 repos — Design

**Date :** 2026-08-24
**Chantier :** 1/4 de la refonte SaaS (voir contexte ci-dessous). Les 3 autres chantiers (modernisation des dépendances, audit multi-tenant, audit qualité des pipelines) sont hors scope de ce document et feront chacun l'objet de leur propre spec.

## Contexte

TenderAI BF est aujourd'hui un monorepo unique contenant le backend Python (LangGraph/FastAPI), le frontend Next.js, et la configuration d'infrastructure (Docker, nginx, CI/CD, déploiement). L'objectif final est une plateforme SaaS commercialisable multi-client. Le premier chantier de cette refonte est la séparation du monorepo en 3 repositories indépendants : backend, frontend, infra.

## État actuel (audit)

- **Backend** : `src/tenderai_bf/`, `tests/`, `alembic/`, `pyproject.toml`/`poetry.lock`.
- **Frontend** : `frontend/` — Next.js 14, aucun code partagé avec le backend (aucune référence croisée trouvée), communique uniquement via HTTP (routes API proxy dans `frontend/app/api/proxy/*`).
- **Infra** : `infra/Dockerfile.{api,frontend,worker}`, `infra/nginx/`, `infra/apache2/`, `docker-compose*.yml` (racine), `settings.yaml`, `.github/workflows/ci-cd.yml`.
- **CI/CD actuel** : un seul workflow construit les 3 images (`api`, `frontend`, `worker`) avec contexte de build `.` (racine du monorepo), les publie sur GHCR (`ghcr.io/abdazz/tenderai-bf-*`), puis déploie via SSH sur le serveur (staging/production) en pullant les images et en réutilisant un clone git du monorepo comme répertoire de déploiement.
- **Déploiement serveur** : le répertoire de déploiement (`DEPLOY_PATH`) est un clone git du monorepo. `docker-compose.server.yml` y monte `./alembic` (migrations) et `./settings.yaml` en volumes dans les containers `api`/`worker`.
- **`infra/Dockerfile.ui`** : fichier mort — le CI ne construit que `api`/`frontend`/`worker`, et le script de déploiement nettoie explicitement les anciens containers `tenderai-ui` orphelins. **Non migré.**

## Décisions validées

### 1. Historique git
Conservé via `git filter-repo` (extraction de l'historique des commits touchant `src/`, `frontend/`, `infra/`+fichiers racine associés vers chaque nouveau repo respectif), plutôt qu'un historique neuf.

### 2. Hébergement des repos
Même compte GitHub que le monorepo actuel (`abdazz`), noms dérivés :
- `tenderai-backend`
- `tenderai-frontend`
- `tenderai-infra`

### 3. Répartition du contenu

| Repo | Contenu |
|---|---|
| `tenderai-backend` | `src/`, `tests/`, `alembic/`, `pyproject.toml`, `poetry.lock`, `scripts/`, `Dockerfile.api`, `Dockerfile.worker` (déplacés depuis `infra/`), `Makefile` (cibles dev/test/migrate/run-once/scheduler), sa propre CI |
| `tenderai-frontend` | contenu de `frontend/` remonté à la racine du repo, `Dockerfile.frontend` (déplacé depuis `infra/`), sa propre CI |
| `tenderai-infra` | `docker-compose.yml`, `docker-compose.server.yml`, `docker-compose.override*.yml`, `infra/nginx/`, `infra/apache2/`, `settings.yaml`, `.env*.example`, script/workflow de déploiement, `Makefile` (cibles up/down/logs/rebuild/déploiement) |

`docs/`, `README.md`, `AGENTS.md`, `technical_specifications.md` sont répartis par pertinence (doc backend → backend, doc déploiement → infra, etc.). Chaque nouveau repo reçoit son propre `CLAUDE.md` scopé à son contenu (dérivé du `CLAUDE.md` actuel). `generated_docs/`, `logs/`, `.coverage`, caches — non migrés (artefacts locaux/gitignored).

### 4. Propriété des builds Docker (Approche A — polyrepo strict)
Chaque repo applicatif construit et publie ses propres images vers GHCR via sa propre CI, déclenchée par ses propres commits/tags :
- CI `tenderai-backend` → build+push `tenderai-bf-api`, `tenderai-bf-worker`
- CI `tenderai-frontend` → build+push `tenderai-bf-frontend`

`tenderai-infra` ne construit aucune image ; il consomme des tags déjà publiés et gère uniquement l'orchestration/déploiement. Approche retenue plutôt qu'une centralisation des builds dans `infra` (rejetée : recouple les repos qu'on cherche à découpler, contraire à l'objectif SaaS multi-repo indépendant).

### 5. Migrations Alembic
Actuellement montées en volume depuis le clone monorepo sur le serveur — plus tenable une fois `alembic/` déplacé dans `tenderai-backend`, séparé du repo de déploiement. **Décision : cuire `alembic/` dans l'image `api`** (`COPY` dans `Dockerfile.api`), suppression du bind-mount correspondant dans `docker-compose.server.yml`. Bénéfice : image autonome, plus de risque de désynchronisation entre le tag d'image déployé et les fichiers de migration montés depuis le host.

### 6. Configuration opérationnelle (`settings.yaml`)
Reste montée en lecture seule depuis `tenderai-infra` — config opérationnelle (cron, seuils de scoring, sources) ajustable sans rebuild d'image. Aucun changement de mécanisme.

### 7. Fichiers `.env.prod` / `.env.staging`
Restent créés directement sur le serveur (jamais commités), dans le répertoire de déploiement — qui devient le clone de `tenderai-infra`.

### 8. Déclenchement du déploiement
CI `tenderai-backend`/`tenderai-frontend` : lint + test + build + push image à chaque push sur `main`/tag (comme aujourd'hui, scindé par repo).
CI `tenderai-infra` : **uniquement `workflow_dispatch`** — déploiement déclenché manuellement, choix de l'environnement (prod/staging) et du tag d'image à déployer (défaut `latest`). Le script SSH existant est repris tel quel, relocalisé dans `infra`. Un déclenchement automatique inter-repos (`repository_dispatch`) est explicitement hors scope (YAGNI) — envisageable dans un chantier futur de continuous deployment.

### 9. Workflow de développement local
Chaque repo autonome pour l'usage courant :
- `tenderai-backend` : conserve son propre `docker-compose.yml` (postgres, minio, createbuckets, api, worker) et les cibles Makefile dev/test/migrate/run-once — autosuffisant pour le travail API/pipeline.
- `tenderai-frontend` : `npm run dev` pointant vers `NEXT_PUBLIC_API_URL` (backend local ou staging) — pas de Docker requis pour le travail UI seul.
- `tenderai-infra` : compose full-stack pour tests d'intégration pré-release, avec un profil buildant depuis des checkouts frères (`../tenderai-backend`, `../tenderai-frontend`) plutôt que depuis GHCR. Convention à documenter : cloner les 3 repos dans un dossier parent commun.

## Hors scope de ce chantier

- Modernisation des dépendances (LangChain/LangGraph) — chantier 2.
- Audit du multi-tenant existant — chantier 3.
- Audit qualité des pipelines — chantier 4.
- Déclenchement automatique inter-repos (`repository_dispatch`) pour le déploiement continu.
- Versionnage formel du contrat d'API entre backend et frontend (OpenAPI as contract) — à considérer si des breaking changes d'API deviennent fréquents, non nécessaire immédiatement (YAGNI).

## Points ouverts pour le plan d'implémentation

- Duplication des secrets GitHub Actions (`SSH_PRIVATE_KEY`, `PRODUCTION_HOST`, `TENDERAI_JWT_SECRET`, etc.) entre le nouveau repo `tenderai-infra` (déploiement) et les repos applicatifs (si besoin de secrets de build, ex. GHCR déjà géré via `GITHUB_TOKEN` natif — pas de duplication nécessaire pour le build).
- Ordre d'exécution de la migration (quel repo extraire en premier, comment valider chaque étape avant de couper le monorepo).
- Mise à jour de `DEPLOY_PATH` sur les serveurs staging/production pour pointer vers un nouveau clone de `tenderai-infra` (avec `settings.yaml`, `.env.prod`, `.env.staging` recopiés depuis l'ancien répertoire).
