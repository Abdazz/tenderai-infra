# Renommage du package Python `tenderai_bf` → `tenderai` (sous-projet B) — Design

**Date :** 2026-09-01
**Origine :** suite du [sous-projet A](2026-08-28-tenderai-bf-rename-infra-design.md) (renommage infra & images Docker, terminé le 2026-08-28), qui excluait explicitement ce sous-projet B « du fait de son risque de régression plus élevé » et le renvoyait à une spec dédiée. Demandé par l'utilisateur le 2026-08-31 dans le cadre des trois correctifs de suivi du chantier 5.

Ce document couvre le renommage du package Python importable lui-même : `src/tenderai_bf/` → `src/tenderai/`, tous les imports, `pyproject.toml`, le point d'entrée CLI, le `Makefile`, la config `ruff`/`mypy`, les tests, les `CMD` des deux Dockerfiles de `tenderai-backend`, et la coordination avec `tenderai-infra` qui référence ce chemin de module dans des command overrides Docker exécutés en production.

## Décisions validées

### 1. Périmètre — chemin d'import Python uniquement
Le nom d'affichage Poetry (`[tool.poetry] name = "tenderai-bf"` dans `pyproject.toml`) **reste inchangé** — décision utilisateur explicite (2026-09-01), ce n'est qu'une étiquette de registre/affichage, jamais importée. Seul le chemin de package réellement importé (`tenderai_bf` → `tenderai`) change, avec tout ce qui en dépend mécaniquement : `packages = [{include = ...}]`, les scripts `[tool.poetry.scripts]`, `--cov=`, `known-first-party` de ruff, `mypy src/...`.

### 2. Exclusions confirmées (identiques dans l'esprit à la Décision 2/3 du sous-projet A)
Ces occurrences textuelles de `tenderai_bf` **ne sont pas touchées** — ce sont des noms de ressources de données déjà provisionnées, pas des chemins d'import :

| Occurrence | Fichier(s) | Raison |
|---|---|---|
| `DatabaseSettings.name` (défaut `"tenderai_bf"`), `DATABASE_URL` par défaut | `tenderai-backend/src/tenderai_bf/config.py` | Nom de la base Postgres réelle |
| `sqlalchemy.url` | `tenderai-backend/alembic.ini` | Idem — config de dev locale, pointe vers la même base |
| `POSTGRES_DB`, `DATABASE_URL` (valeurs par défaut des variables d'env) | `tenderai-backend/docker-compose.yml`, `.env.example` | Idem |
| `pg_dump -U tenderai tenderai_bf`, `psql -d tenderai_bf` | `tenderai-backend/Makefile` | Idem — commandes opérant sur la base réelle |
| `DATABASE_NAME=tenderai_bf`, `POSTGRES_DB=tenderai_bf` | `tenderai-infra/.env*.example`, `docker-compose*.yml` | Base Postgres du serveur staging déjà provisionnée (déjà exclu par le sous-projet A) |
| Nom du bucket MinIO (`tenderai-bf`) | `tenderai-infra` (déjà traité comme hors-scope par le sous-projet A) | Idem |

### 3. Correctif adjacent inclus : `app_name` par défaut
`Settings.app_name` (`tenderai-backend/src/tenderai_bf/config.py`) vaut encore `"TenderAI BF"` — un résidu manqué par le nettoyage doc du sous-projet A/BF-rename. **Correction post-revue finale (2026-09-01) :** contrairement à ce que ce document affirmait initialement, `app_name` ne pilote PAS le titre FastAPI — celui-ci est codé en dur (`title="TenderAI BF API"`) dans `api/main.py:104`, indépendamment de ce setting. Les consommateurs réels de `app_name` sont : un champ de log au démarrage (`main.py:35`), la clé `"app"` de la réponse JSON de l'endpoint racine `/` (`main.py:167`), le slug de nom de fichier des rapports téléchargés (`api/routers/reports.py:139`), et le nom de pièce jointe email par défaut (`email/smtp_client.py:673`) — aucun d'eux n'est un identifiant de stockage ou de recherche, juste des libellés affichés/suggérés. Aucune valeur exacte n'est vérifiée par les tests (`test_smoke.py` ne vérifie que la présence de l'attribut). Changé en `"TenderAI"` dans le même correctif, avec un message de commit distinct de la mécanique de renommage d'import. Le titre FastAPI codé en dur (`api/main.py:104`, encore "TenderAI BF API") reste un résidu séparé, non corrigé par ce sous-projet — suivi comme nettoyage cosmétique différé (voir `docs/PROJECT_STATUS.md`).

### 4. `tenderai-infra/settings.yaml` — namespace de logger à synchroniser
Le sous-projet A avait laissé `logging.loggers.tenderai_bf` (clé de `settings.yaml`) inchangé « tant que le sous-projet B n'est pas fait ». **Correction post-revue finale (2026-09-01) :** contrairement à ce que ce document affirmait initialement, ce bloc `logging.loggers` de `settings.yaml` n'est en réalité pas lu par le backend — `config.py`'s `_load_yaml_config` ne lit que la clé `ocr` de ce fichier ; la config de logging réelle est le dict `logging_config` codé en dur dans `tenderai-backend/src/tenderai/logging.py` (lignes ~73-125), indépendant de `settings.yaml`. Ce bloc YAML est donc actuellement inerte. Renommé quand même par hygiène de cohérence de nommage (voir le commentaire ajouté dans `settings.yaml`), pas parce qu'un filtrage de logs en dépendait réellement. Renommé en même temps : les deux appels `structlog.get_logger("tenderai_bf")` dans `tenderai-backend/src/tenderai_bf/logging.py`, en `tenderai` — ceux-là sont bien actifs (via `get_logger(__name__)`, les loggers de module s'appellent `tenderai.xxx` après le renommage).

### 5. Approche — renommage mécanique, sans compatibilité descendante
`git mv src/tenderai_bf src/tenderai` puis un passage `sed` scripté sur chaque fichier concerné, restreint aux occurrences de chemin d'import/module (jamais aux lignes de noms de ressources de données listées en Décision 2, exclues manuellement). Pas de package `tenderai_bf` de compatibilité (ré-export shim) — sur-ingénierie pour un renommage à un seul consommateur (ce repo). Vérifié par : `ruff check src tests` (l'ordre des imports détecte les oublis), `mypy src/tenderai` (détecte les imports non résolus), puis la suite de tests complète (un import non renommé fait échouer la collection immédiatement).

**Fichiers concernés dans `tenderai-backend`** (chemin d'import/module, tous à modifier) :
- Répertoire : `src/tenderai_bf/` → `src/tenderai/` (renommage physique du dossier, ~76 fichiers `.py`)
- `pyproject.toml` : `packages`, `[tool.poetry.scripts]` (`tenderai`, `tenderai-api`), `--cov=`
- `ruff.toml` : `known-first-party`
- `Makefile` : `mypy src/...`, `--cov=...`, les 5 invocations `python -m tenderai_bf.cli ...` / `python -m tenderai_bf.scheduler.schedule` (pas les lignes `pg_dump`/`psql`, cf. Décision 2)
- `Dockerfile.api`, `Dockerfile.worker` : `CMD` (`uvicorn tenderai_bf.api.main:app`, `python -m tenderai_bf.cli run-scheduler`)
- `docker-compose.yml` (dev local, distinct du `docker-compose.server.yml` de l'infra) : la commande `uvicorn` du service `api`
- `alembic/env.py` : `from tenderai_bf.models import Base`
- `.github/workflows/ci.yml` : `mypy src/tenderai_bf`
- `src/tenderai_bf/logging.py` : namespace de logger (cf. Décision 4)
- `src/tenderai_bf/api/main.py` : chaîne `"tenderai_bf.api.main:app"` passée à `uvicorn.run()`
- `src/tenderai_bf/agents/extraction.py` : seul fichier à utiliser des imports absolus (`from tenderai_bf.config import ...`) plutôt que relatifs — à vérifier qu'il fonctionne toujours après renommage, sans en profiter pour le convertir en import relatif (hors scope, changement non lié)
- Commentaires d'en-tête de fichier (`# src/tenderai_bf/...`) dans `settings_store.py`, `api/schemas/settings.py` — cosmétique, mis à jour pour rester exacts
- ~40 fichiers sous `tests/` : imports `from tenderai_bf...` / `tenderai_bf.xxx` dans les mocks et fixtures
- `Settings.app_name` (cf. Décision 3, correctif adjacent)

**Fichiers concernés dans `tenderai-infra`** (coordination inter-repo, cf. Décision 6) :
- `docker-compose.server.yml` : les 2 command overrides (`uvicorn tenderai_bf.api.main:app`, `python -m tenderai_bf.cli run-scheduler`)
- `settings.yaml` : clé `logging.loggers.tenderai_bf` (cf. Décision 4)

### 6. Coordination inter-repo — le vrai risque de ce sous-projet
`tenderai-infra/docker-compose.server.yml` code en dur `tenderai_bf.api.main:app` et `python -m tenderai_bf.cli` comme **command overrides exécutés sur le serveur réel**. `tenderai-backend` et `tenderai-infra` doivent être fusionnés et déployés **ensemble** — même séquence de déploiement conjoint que les sous-projets A+B du chantier 5. Déployer le backend seul romprait au déploiement (mauvais chemin de module dans les commandes de démarrage des conteneurs, crash-loop) ; déployer l'infra seule romprait avant même que l'image backend renommée existe.

Séquence :
1. Renommer sur une branche de `tenderai-backend` (à partir de `staging`), vérifier localement (suite de tests complète, `ruff check/format`, `mypy` sans nouvelle erreur par rapport à la référence actuelle), fusionner sur `staging`.
2. Modifier `tenderai-infra/docker-compose.server.yml` et `settings.yaml` sur une branche de `tenderai-infra` (à partir de `staging`), fusionner sur `staging`.
3. Un seul déclenchement de `deploy.yml` (`environment=staging`, `image_tag=staging`) une fois les deux images à jour sur GHCR.
4. Valider : `curl https://stagingtenderai.yulcom.net/health` → `healthy`, puis un smoke test CLI en direct via `docker exec` (ex. `python -m tenderai.cli --help`) pour confirmer que le point d'entrée renommé fonctionne réellement côté serveur, pas seulement à l'import.

### 7. Rollback
Aucune migration de données impliquée — c'est un renommage de code pur. Rollback = revert des commits de fusion sur les deux repos + nouveau déploiement des images `:staging` précédentes.

### 8. Périmètre — staging uniquement
Comme le sous-projet A, ce travail ne touche que le serveur staging. La production reste sur les images de l'ancien monorepo tant que la tâche 13 (cutover prod, chantier 1) n'a pas été exécutée avec confirmation explicite de l'utilisateur.

## Tests

- Suite complète `tenderai-backend` : doit rester verte (192 passed / 4 deselected au moment de l'écriture, `-m "not slow and not integration"`, correspond au gate CI réel).
- `ruff check src tests` / `ruff format --check src tests` : propre (portée réelle du lint CI).
- `mypy src/tenderai` : aucune **nouvelle** erreur par rapport à la référence actuelle (523 erreurs pré-existantes, `continue-on-error: true` en CI — l'objectif n'est pas de les résoudre, seulement de ne pas en introduire de nouvelles liées au renommage).
- Post-déploiement : `/health` + smoke CLI en direct (cf. Décision 6, étape 4).
