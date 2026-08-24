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
