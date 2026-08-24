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
