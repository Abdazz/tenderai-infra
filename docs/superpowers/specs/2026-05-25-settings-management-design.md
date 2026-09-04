# Settings Management — Design Spec

**Date:** 2026-05-25
**Status:** Approved
**Refs:** IMPROVEMENTS.md §2 (Database-persisted configuration) + §3 (Settings management module)

---

## 1. Objectif

Remplacer le dump JSON read-only de `/settings` par un système complet de gestion des paramètres :
- Tous les paramètres opérationnels sont persistés en base de données
- `settings.yaml` sert uniquement à seeder la DB au premier déploiement (ensuite ignoré)
- L'admin peut lire et modifier chaque paramètre depuis l'interface web, sans redémarrage

---

## 2. Architecture générale

```
settings.yaml          env vars (.env)
     │                      │
     └──── seed (1ère boot) ─┘
                │
         app_settings (DB)
                │
         Settings loader        ← priorité : DB > env vars > yaml défauts
                │
    ┌───────────┼───────────┐
  API          Worker    Scheduler
  FastAPI      LangGraph  APScheduler
```

**Flux de lecture au démarrage :**
1. `Settings.__init__` charge les env vars (comportement actuel conservé)
2. La couche DB est lue via `SettingsStore` : si une section existe → ses valeurs écrasent les défauts Pydantic
3. Si une section est absente de la DB → fallback sur la valeur courante (env var ou défaut yaml)

**Flux d'écriture :**
1. `PUT /api/v1/admin/settings/{section}` valide le payload (Pydantic) et persiste en DB
2. L'endpoint envoie un signal de reload aux services concernés
3. Le singleton `settings` est mis à jour en mémoire

**Seeding :**
- Exécuté au démarrage de l'API (`startup` event), après `alembic upgrade head`
- Lit `settings.yaml`, pour chaque section : INSERT si absent, ne touche pas les lignes existantes
- Idempotent — safe à redéclencher

---

## 3. Modèle base de données

### Table `app_settings`

```sql
CREATE TABLE app_settings (
    section     TEXT PRIMARY KEY,
    data        JSONB NOT NULL,
    updated_at  TIMESTAMP NOT NULL DEFAULT now(),
    updated_by  TEXT  -- username de l'admin ayant fait la dernière modification
);
```

### Sections stockées en DB

| Section | Contenu |
|---|---|
| `pipeline` | max_items_per_run, min_relevance_score, deduplication_threshold, deduplication_method, use_llm_classification, pdf_timeout, max_file_size_mb |
| `scheduler` | cron_schedule, timezone, enabled, max_concurrent_runs, run_on_startup |
| `llm` | provider, groq_model, openai_model, ollama_model, ollama_base_url, temperature, max_tokens, timeout |
| `email` | from_address, from_name, to_address, reply_to, subject_prefix, signature |
| `rag` | enabled, chunk_size, chunk_overlap, top_k_results, embedding_model, vector_search_query |
| `classification` | relevant_keywords (dict: it_services, it_hardware, it_consulting → list[str]) |
| `prompts` | extraction.system, extraction.user_template, classification.system, classification.user_template, summarization.system, summarization.user_template, deduplication.system, deduplication.user_template |

### Sections read-only (env vars uniquement, jamais en DB)

- `database` : DATABASE_URL, credentials
- `minio` : endpoint, access_key, secret_key
- `smtp` : host, port, user, password
- `security` : TENDERAI_JWT_SECRET, TENDERAI_ADMIN_PASSWORD

Ces sections sont affichées en lecture seule dans l'UI (valeurs masquées, icône cadenas).

---

## 4. Backend

### Nouveau module : `settings_store.py`

```python
class SettingsStore:
    """Lecture/écriture de app_settings en DB."""
    def get_section(db, section: str) -> dict | None
    def put_section(db, section: str, data: dict, updated_by: str) -> None
    def get_all(db) -> dict[str, dict]
    def seed_from_yaml(db, yaml_path: Path) -> list[str]  # retourne sections seedées
```

### Intégration dans `config.py`

`Settings._load_from_db(db)` est appelé après `_load_yaml_config`. Priorité finale :
1. Env vars (SecretStr, toujours depuis l'environnement)
2. DB (`app_settings`)
3. `settings.yaml` (défauts)
4. Défauts Pydantic

### Reload signals après PUT

| Section modifiée | Action |
|---|---|
| `scheduler` | `scheduler.reschedule(new_cron, new_timezone)` |
| `llm` | Invalide le singleton LLM client (reconstruit au prochain appel pipeline) |
| `pipeline`, `rag`, `classification`, `prompts`, `email` | Re-instancie le singleton `Settings` en mémoire |

### Endpoints API

```
GET  /api/v1/admin/settings                  → toutes sections (lecture, agrégat)
GET  /api/v1/admin/settings/{section}        → une section
PUT  /api/v1/admin/settings/{section}        → mettre à jour + reload
POST /api/v1/admin/settings/seed             → forcer re-seed depuis settings.yaml
```

Tous les endpoints requièrent un JWT valide (rôle `admin`).

### Schémas Pydantic par section

Un schéma de validation dédié par section :
- `PipelineSettingsSchema`, `SchedulerSettingsSchema`, `LLMSettingsSchema`, etc.
- `PUT` valide contre le schéma avant toute écriture DB

---

## 5. Frontend

### Structure fichiers

```
frontend/app/(dashboard)/settings/
  page.tsx                        ← Server Component, charge toutes sections au SSR
  settings-client.tsx             ← Client Component, tabs + forms + state

frontend/app/api/settings/
  route.ts                        ← GET toutes sections (proxy → FastAPI)
  [section]/
    route.ts                      ← GET + PUT une section (proxy → FastAPI, pattern identique à /api/proxy/sources)

frontend/components/settings/
  pipeline-section.tsx
  scheduler-section.tsx
  llm-section.tsx
  email-section.tsx
  rag-section.tsx
  classification-section.tsx
  prompts-section.tsx
  readonly-section.tsx            ← display read-only env-var sections
  prompt-editor-dialog.tsx        ← Dialog plein écran pour éditer un prompt
```

### Composants d'input par type de champ

| Type | Composant |
|---|---|
| Texte court (URL, nom, modèle) | `<Input>` |
| Nombre entier | `<Input type="number">` |
| Décimal 0.0–1.0 | `<Input type="number" step="0.01" min="0" max="1">` |
| Booléen | `<Switch>` |
| Enum (provider, dedup_method) | `<Select>` |
| Cron expression | `<Input>` + aperçu lisible ("Lun–Ven à 7h00, fuseau Ouagadougou") |
| Liste de mots-clés | `<Textarea>` un mot/expression par ligne ; split(`\n`) à la désérialisation |
| Prompt LLM | Bouton "Modifier →" ouvre `<PromptEditorDialog>` avec `<Textarea>` pleine hauteur |

### Comportement UX

- Formulaire par section (tab), bouton "Sauvegarder" en bas
- Feedback : toast succès/erreur après PUT
- Sections read-only : `<Card>` avec fond grisé, label "Géré par variable d'environnement", valeurs masquées (`***`), icône cadenas
- Cron preview : parsing côté client avec une lib légère (`cronstrue` ou calcul manuel pour les cas simples)

---

## 6. Migration Alembic

Nouvelle migration : `0002_add_app_settings.py`

```python
op.create_table(
    "app_settings",
    sa.Column("section", sa.Text(), primary_key=True),
    sa.Column("data", postgresql.JSONB(), nullable=False),
    sa.Column("updated_at", sa.DateTime(), server_default=sa.func.now(), nullable=False),
    sa.Column("updated_by", sa.Text(), nullable=True),
)
```

---

## 7. Seeding de settings.yaml

Au `startup` de l'API (`lifespan` FastAPI) :

```python
async def seed_settings_on_startup(db):
    seeded = settings_store.seed_from_yaml(db, Path("settings.yaml"))
    if seeded:
        logger.info("Settings seeded from YAML", sections=seeded)
```

Après ce seeding initial, `settings.yaml` devient un artefact de bootstrap. Les modifications ultérieures passent uniquement par l'UI/API.

---

## 8. Hors périmètre

- Historique/audit par champ (possible en évolution vers Approche B)
- Support multi-pays (IMPROVEMENTS.md §1) — la table `app_settings` pourra recevoir une colonne `country_id` FK quand ce besoin arrivera
- Gestion des destinataires email (table `recipients` existante — interface CRUD séparée)
