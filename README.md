# TenderAI BF — Infra

Docker, CI/CD, déploiement, monitoring et configuration opérationnelle de TenderAI BF.

Fait partie de l'architecture à 3 repos :
- [`tenderai-backend`](https://github.com/abdazz/tenderai-backend) — API et pipelines
- [`tenderai-frontend`](https://github.com/abdazz/tenderai-frontend) — interface Next.js

## Développement local full-stack

Ce repo est la racine — cloner `tenderai-backend` et `tenderai-frontend` comme sous-dossiers ici :
```bash
git clone git@github.com:abdazz/tenderai-infra.git tenderai && cd tenderai
git clone git@github.com:abdazz/tenderai-backend.git
git clone git@github.com:abdazz/tenderai-frontend.git
cp .env.example .env
cp docker-compose.override.dev.yml docker-compose.override.yml
make up
```

## Déploiement

Voir `CLAUDE.md` — déclenchement manuel via `workflow_dispatch` uniquement.
