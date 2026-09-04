# DB-First Configuration — Design Spec

**Date:** 2026-06-02  
**Status:** Approved  

---

## Problem

The pipeline currently reads operational config (LLM provider, classification keywords, processing thresholds, prompts, sources list) from the in-memory `settings` singleton, which is populated at startup from `settings.yaml` + env vars. This means:

- Sources page shows an empty list until the pipeline runs in production mode.
- Two countries cannot have different operational settings at runtime (singleton is global).
- `use_database_sources=False` (the default) silently bypasses the DB, causing confusion.
- `settings.yaml` is read at every API startup even in production, making it a hidden runtime dependency.

---

## Goal

All operational config comes from the database at runtime. `settings.yaml` is used only to seed the DB on first startup. Applies to all environments (dev, staging, prod) with no mode flag.

---

## Architecture

### Source of truth per config type

| Config type | Source | Examples |
|---|---|---|
| Infrastructure credentials | `.env` / env vars | `DATABASE_URL`, `MINIO_*`, `SMTP_HOST/PORT/USER/PASS`, `JWT_SECRET`, `GROQ_API_KEY` |
| Infrastructure non-secrets | `.env` / env vars or Python defaults | `LOG_LEVEL`, `APP_ENV`, fetch timeouts, OCR language |
| Operational config | `country_settings` table (per country) | LLM provider/model, pipeline thresholds, classification keywords, prompts, email content, RAG settings, scheduler cron |
| Sources list | `sources` table (per country) | Portal URLs, parser types, rate limits |
| Global defaults | `app_settings` table | Same sections as `country_settings`, used as fallback when a country row is missing |

### What `settings.yaml` becomes

A seed file only. Its operational sections (`llm`, `processing`, `classification`, `prompts`, `rag`, `scheduler`, `sources`, `recipients`) are read exactly once — at API startup — to populate `app_settings` if it is empty. After that, `settings.yaml` is not read again until the next cold start, and even then its data is ignored if the DB rows already exist (idempotent seed).

---

## Seeding Flow

```
API cold start
  1. Alembic migrations run (separate step, before API starts)
  2. init_database()
  3. SettingsStore.seed_from_settings(db)
       if app_settings is empty:
         reads settings.yaml via Settings singleton
         inserts 7 sections: pipeline, scheduler, llm, email, rag,
                              classification, prompts
       (idempotent — already implemented)
  4. For every active country that has no country_settings rows:
       CountryStore.seed_from_global(db, country_id)
       (copies app_settings → country_settings for that country)
  5. Log warning for any country still missing sections after seed
```

Step 4 is an addition to the existing startup. The loop ensures countries created before this migration also get their settings seeded.

---

## Pipeline Runtime Config

### `TenderAIState.country_config`

Already populated in `graph.py:TenderAIPipeline.run()` via `CountryStore.get_all_with_fallback(db, country_id)`. Returns a `dict[str, dict]` with all 7 sections for the country. No change needed here.

### `cfg()` helper

New utility function in `agents/graph.py`:

```python
def cfg(state: TenderAIState, section: str, key: str) -> Any:
    """Read state.country_config[section][key]. Raises RuntimeError if absent."""
    try:
        return state.country_config[section][key]
    except KeyError:
        raise RuntimeError(
            f"Missing DB config: country_id={state.country_id} "
            f"section='{section}' key='{key}' — run seed first"
        )
```

Fail-hard: if a section or key is missing, the pipeline stops immediately with a clear error rather than silently using a stale YAML default.

### Node migration map

| Node | Old access | New access |
|---|---|---|
| `classify.py` | `settings.processing.use_llm_classification` | `cfg(state, "pipeline", "use_llm_classification")` |
| `classify.py` | `settings.processing.min_relevance_score` | `cfg(state, "pipeline", "min_relevance_score")` |
| `classify.py` | `settings.classification.relevant_keywords` | `cfg(state, "classification", "relevant_keywords")` |
| `classify.py` | `settings.llm.provider` | `cfg(state, "llm", "provider")` |
| `deduplicate.py` | `settings.processing.deduplication_method` | `cfg(state, "pipeline", "deduplication_method")` |
| `deduplicate.py` | `settings.processing.deduplication_threshold` | `cfg(state, "pipeline", "deduplication_threshold")` |
| `deduplicate.py` | `settings.prompts` | `state.country_config.get("prompts", {})` |
| `deduplicate.py` | `settings.llm.provider` | `cfg(state, "llm", "provider")` |
| `email_report.py` | `settings.email.from_address/from_name/to_address/subject_prefix/signature` | `cfg(state, "email", "<key>")` for each |
| `email_report.py` | `settings.recipients` | query `recipients` table filtered by `country_id` |
| `extract_item_links.py` | `settings.processing.max_items_per_run` | `cfg(state, "pipeline", "max_items_per_run")` |
| `parse_pdf_rag.py` | `settings.rag.chunk_size/chunk_overlap/top_k_results/embedding_model` | `cfg(state, "rag", "<key>")` for each |
| `summarize.py` | `settings.llm.provider` | `cfg(state, "llm", "provider")` |
| `summarize.py` | `settings.prompts` | `state.country_config.get("prompts", {})` |
| `load_sources.py` | YAML branch (MODE 1) | deleted — DB only |

**What stays in `settings.*`:** infra credentials accessed directly (e.g., `settings.llm.groq_api_key`, `settings.google_search.api_key`, `settings.smtp.*`). These come from `.env` and have no `country_settings` equivalent.

---

## `config.py` Changes

### Fields removed from `Settings`

- `use_database_sources: bool`
- `sources: list[dict]`
- `recipients: list[dict]`
- `rate_limits: dict`
- `prompts: dict`

### Methods removed

- `get_active_sources()` — sources come from the `sources` table
- `reload_settings_from_db()` — singleton is no longer a proxy for operational config
- `apply_db_override()` — same reason

### `_load_yaml_config()` trimmed

Remove blocks that parse: `sources`, `recipients`, `rate_limits`, `prompts`, `classification`, `processing`, `llm`, `rag`, `scheduler`.

Keep only: `ocr`, `fetch` (HTTP timeouts, user-agent) — infra settings with no DB section.

Result: `config.py` shrinks from ~681 lines to ~350 lines.

---

## `load_sources.py` Changes

Delete MODE 1 (YAML branch, lines ~47–100). Keep only MODE 2 (DB sync). The DB sync path already handles the case where a source from `settings.yaml` doesn't exist in the DB — it creates it. Since we seed sources in migration 0006, this path will update existing sources if their URLs/settings change in `settings.yaml` on next startup.

---

## Testing

Node tests in `tests/nodes/` inject `country_config` directly into `TenderAIState`:

```python
state = TenderAIState(
    country_id=1,
    country_config={
        "pipeline": {
            "use_llm_classification": False,
            "min_relevance_score": 0.5,
            "deduplication_method": "hash_only",
            "deduplication_threshold": 0.85,
            "max_items_per_run": 100,
            "pdf_timeout": 30,
            "max_file_size_mb": 10,
        },
        "llm": {"provider": "groq", "groq_model": "llama-3.3-70b-versatile",
                "openai_model": "gpt-4o", "ollama_model": "llama3", "ollama_base_url": "",
                "temperature": 0.1, "max_tokens": 2000, "timeout": 60},
        "classification": {"relevant_keywords": {"it_services": ["informatique"]}},
        "prompts": {"extraction": {"system": "...", "user_template": "..."},
                    "classification": {"system": "...", "user_template": "..."},
                    "summarization": {"system": "...", "user_template": "..."},
                    "deduplication": {"system": "...", "user_template": "..."}},
        "email": {"from_address": "test@example.com", "from_name": "TenderAI",
                  "to_address": "dest@example.com", "subject_prefix": "[TEST]",
                  "signature": "", "reply_to": None},
        "rag": {"enabled": True, "chunk_size": 512, "chunk_overlap": 50,
                "top_k_results": 5, "embedding_model": "all-MiniLM-L6-v2",
                "vector_search_query": "appel d'offres"},
    }
)
```

No DB mock required for unit tests. Integration tests that test the full pipeline still use a real DB (existing pattern).

---

## Files Changed

| File | Type of change |
|---|---|
| `src/tenderai_bf/config.py` | Remove 5 fields, 3 methods, trim `_load_yaml_config` |
| `src/tenderai_bf/api/main.py` | Add loop to seed all existing countries |
| `src/tenderai_bf/agents/graph.py` | Add `cfg()` helper |
| `src/tenderai_bf/agents/nodes/load_sources.py` | Delete MODE 1 YAML branch |
| `src/tenderai_bf/agents/nodes/classify.py` | Replace `settings.*` → `cfg(state, ...)` |
| `src/tenderai_bf/agents/nodes/deduplicate.py` | Replace `settings.*` → `cfg(state, ...)` |
| `src/tenderai_bf/agents/nodes/email_report.py` | Replace `settings.*` → `cfg(state, ...)` |
| `src/tenderai_bf/agents/nodes/extract_item_links.py` | Replace `settings.*` → `cfg(state, ...)` |
| `src/tenderai_bf/agents/nodes/parse_pdf_rag.py` | Replace `settings.*` → `cfg(state, ...)` |
| `src/tenderai_bf/agents/nodes/summarize.py` | Replace `settings.*` → `cfg(state, ...)` |
| `tests/nodes/*.py` | Inject `country_config` into state fixtures |

---

## Out of Scope

- UI for editing `country_settings` (already exists via `/api/v1/countries/{id}/settings`)
- Adding new sections to `country_settings`
- Migrating infra credentials to DB (intentionally excluded — bootstrap problem)
