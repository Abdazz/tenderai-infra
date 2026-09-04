# Renommage "tenderai-bf" → "tenderai" — infra & images Docker (sous-projet A) — Design

**Date :** 2026-08-28
**Origine :** question soulevée par l'utilisateur pendant la clôture de la tâche 12 (cutover staging, chantier 1) — pourquoi la mention "BF" (Burkina Faso) persiste-t-elle partout dans les noms de packages/images, alors que le produit a pivoté vers un modèle multi-pays (chantier 0) ? Et pourquoi les 3 nouveaux repos publient-ils vers les mêmes packages GHCR que l'ancien monorepo ?

Ce document couvre uniquement le **sous-projet A** : le renommage des artefacts d'infrastructure (préfixe d'image GHCR, noms d'images Docker, chaîne User-Agent du scraper). Le **sous-projet B** — renommage du package Python `tenderai_bf` lui-même (imports, `pyproject.toml`, point d'entrée CLI, `Makefile`, config mypy, tests, `CMD` du Dockerfile — 41+ fichiers dans `tenderai-backend`) — est explicitement hors scope et fera l'objet de sa propre spec, décidé séparément par l'utilisateur du fait de son risque de régression plus élevé.

## Contexte

Le nom "BF" remonte à l'origine du projet ("TenderAI BF", harvester de marchés publics pour le seul Burkina Faso). Le chantier 0 (data model multi-company) puis le chantier 1 (séparation en 3 repos) ont fait évoluer le produit vers un modèle multi-pays sans jamais renommer les artefacts — ce n'était dans le périmètre d'aucun des deux. Lors du repo-split, `IMAGE_PREFIX: ghcr.io/abdazz/tenderai-bf` a simplement été recopié tel quel dans les nouveaux workflows CI — aucune décision délibérée de conserver ce préfixe, juste une config héritée non révisée.

## Audit de l'empreinte réelle

Recherche exhaustive (`grep -rl "tenderai-bf"`) dans les 3 repos + inspection du flux de déploiement réel (`tenderai-infra/.github/workflows/deploy.yml`) :

| Fichier | Contenu actuel | Impact |
|---|---|---|
| `tenderai-backend/.github/workflows/ci.yml` | `IMAGE_PREFIX: ghcr.io/abdazz/tenderai-bf` | Détermine les noms `tenderai-bf-api`/`tenderai-bf-worker` poussés sur GHCR |
| `tenderai-frontend/.github/workflows/ci.yml` | `IMAGE_PREFIX: ghcr.io/abdazz/tenderai-bf` | Détermine `tenderai-bf-frontend` |
| `tenderai-infra/docker-compose.server.yml` | 3 lignes `image: ghcr.io/abdazz/tenderai-bf-{api,frontend,worker}:${IMAGE_TAG}` | Images effectivement tirées par le serveur au déploiement |
| `tenderai-infra/settings.yaml` | `user_agent: "TenderAI-BF/1.0 (+https://github.com/your-org/tenderai-bf)"` | Envoyé aux portails de marchés publics externes lors du scraping — cosmétique mais visible par des tiers |
| `tenderai-backend/pyproject.toml`, `.env.example`, `docker-compose.yml`, `src/tenderai_bf/**` | Nom du package Python, imports | **Hors scope** — sous-projet B |
| `tenderai-infra/.env*.example` — `MINIO_BUCKET_NAME=tenderai-bf` | Nom du bucket MinIO déjà provisionné en staging (données réelles) | **Hors scope — exclu explicitement** (voir Décisions) |
| `tenderai-backend/.env.example` — `DATABASE_NAME=tenderai_bf` | Nom de la base Postgres déjà provisionnée en staging (données réelles) | **Hors scope — exclu explicitement** |
| `tenderai-infra/settings.yaml` — clé `logging.loggers.tenderai_bf` | Namespace de logger lié au nom du package Python | **Hors scope** — doit rester synchronisé avec le nom réel du package tant que le sous-projet B n'est pas fait ; le renommer maintenant casserait silencieusement le filtrage des niveaux de log |
| `tenderai-infra/scripts/deploy.sh` | `DEPLOY_DIR="/opt/tenderai-bf"`, `REPO_URL=".../Tender-AI.git"` | **Mort** — non invoqué par `deploy.yml` (vérifié par grep), pointe déjà vers l'ancien monorepo. Le chemin de déploiement réel est `/opt/tenderai-infra-staging` (staging) / `/opt/tenderai-infra` (prod), sans "bf" — aucun renommage de répertoire serveur nécessaire. |

## Décisions validées

### 1. Nouveau nom
`tenderai` remplace `tenderai-bf` (suffixe pays supprimé, cohérent avec le pivot multi-pays). Nouveaux noms :
- Préfixe GHCR : `ghcr.io/abdazz/tenderai`
- Images : `tenderai-api`, `tenderai-worker`, `tenderai-frontend`

### 2. Base de données et bucket MinIO — exclus de ce sous-projet
`DATABASE_NAME=tenderai_bf` et `MINIO_BUCKET_NAME=tenderai-bf` restent inchangés indéfiniment sur les environnements déjà provisionnés (staging, futur prod). Ce sont des identifiants de données réelles, pas de simples libellés — les renommer impliquerait soit une migration de données avec risque d'indisponibilité, soit deux ressources parallèles à réconcilier. Décision utilisateur explicite : hors scope, aucune migration.

### 3. Package Python et namespace de logger — différés (sous-projet B)
`tenderai_bf` (package, imports, `pyproject.toml`, CLI, `Makefile`, mypy, tests, `Dockerfile` `CMD`, clé `logging.loggers.tenderai_bf` de `settings.yaml`) reste inchangé dans ce sous-projet. Fera l'objet d'une spec séparée, du fait du risque de régression plus élevé (41+ fichiers source touchés dans `tenderai-backend`).

### 4. `scripts/deploy.sh` — laissé tel quel
Script mort, non invoqué par la CI, déjà obsolète (pointe vers l'ancien monorepo). Sa correction ou suppression n'est pas nécessaire au bon fonctionnement du renommage — laissé en l'état par décision utilisateur, à traiter dans un futur nettoyage si besoin.

### 5. Anciens packages GHCR — non supprimés
Après ce changement, les nouveaux pushes iront vers `tenderai-api`/`tenderai-worker`/`tenderai-frontend`. Les anciens packages `tenderai-bf-api`/`tenderai-bf-worker`/`tenderai-bf-frontend` deviennent orphelins (plus aucun nouveau push) mais ne sont **pas supprimés** dans le cadre de ce sous-projet — une suppression de package GHCR est une action destructive distincte, qui nécessiterait une confirmation explicite séparée de l'utilisateur le moment venu.

### 6. Permissions GHCR pour les nouveaux noms de packages
Le premier push vers un nom de package GHCR inédit (`tenderai-api`, etc.) depuis un repo qui a déjà les droits d'écriture sur le même namespace utilisateur (`abdazz`) crée le package automatiquement — pas besoin de reproduire manuellement la procédure "Manage Actions access" déjà suivie pour `tenderai-bf-*`, puisqu'il s'agit d'un nom de package tout nouveau (pas d'ACL préexistante à corriger). À vérifier concrètement lors du premier run CI post-renommage : si un `permission_denied` apparaît malgré tout, appliquer la même procédure manuelle (UI GitHub, pas de CLI disponible sur compte perso) que documentée dans `docs/PROJECT_STATUS.md` pour la tâche 12.

### 7. Périmètre : staging uniquement
La production tourne encore sur les images de l'ancien monorepo (`ci-cd.yml`, non touché ici) tant que la tâche 13 (cutover prod, chantier 1) n'a pas été exécutée avec confirmation explicite de l'utilisateur. Ce renommage ne touche donc que le serveur staging déjà cutover à la tâche 12.

### 8. Séquence de déploiement
1. Éditer les 4 fichiers listés dans l'audit (3 `IMAGE_PREFIX`/`image:` + 1 `user_agent`), sur la branche `staging` de chaque repo concerné (`tenderai-backend`, `tenderai-frontend`, `tenderai-infra`).
2. Pousser — la CI de `tenderai-backend` et `tenderai-frontend` reconstruit et pousse les images sous les nouveaux noms.
3. Re-déclencher `tenderai-infra`'s `deploy.yml` (`environment=staging`, `image_tag=staging`) pour que le serveur tire les images renommées via le nouveau `docker-compose.server.yml`.
4. Valider : `curl https://stagingtenderai.yulcom.net/health` → 200, puis vérification visuelle rapide dans le navigateur (le frontend doit continuer à fonctionner normalement — aucun changement fonctionnel attendu, seul le nom de l'image change).

### 9. Rollback
Chaque étape est un simple revert de commit + nouveau push (CI rebuild) ou un nouveau `workflow_dispatch` de `deploy.yml` avec l'ancien `docker-compose.server.yml`. Aucune migration de données irréversible n'est impliquée dans ce sous-projet — le rollback est aussi simple que le déploiement initial.
