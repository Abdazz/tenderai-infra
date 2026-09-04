# Multi-Country Pipeline Support — Design Spec

**Date:** 2026-06-01  
**Status:** Approved  
**Refs:** IMPROVEMENTS.md #1

---

## Context

TenderAI BF is currently a single-country system hardwired to Burkina Faso. All sources, pipeline runs, recipients, and configuration are global. This spec adds first-class `Country` support so that each country has its own isolated pipeline, sources, schedule, prompts, and email recipients — all manageable from the admin dashboard without touching code or restarting services.

All existing data (sources, runs, notices, recipients, settings) migrates to Burkina Faso (code `BF`) as part of the database migration.

---

## Architecture Decision

**Approach: Country context in `TenderAIState` (shared compiled graph).**

The LangGraph compiled app is stateless between invocations — there is no cross-country contamination when two countries run concurrently. A single `TenderAIGraph` instance is reused for all countries. Country-specific config (prompts, thresholds, recipients, schedule) is loaded from `CountrySettings` at the start of each `run()` call and injected into `state.country_config`. Nodes read from `state.country_config` instead of the global `settings` singleton.

This avoids per-country graph compilation overhead (Approach B/C) while achieving full runtime isolation.

---

## Section 1 — Data Model

### New table: `Country`

```
id          Integer, PK, autoincrement
name        String(255), NOT NULL         — "Burkina Faso"
code        String(10),  NOT NULL, UNIQUE — ISO 3166-1 alpha-2, e.g. "BF"
locale      String(10),  NOT NULL         — report language, e.g. "fr"
active      Boolean,     NOT NULL, default True
created_at  DateTime,    NOT NULL, default now()
updated_at  DateTime,    NOT NULL, default now(), onupdate now()
```

### New table: `CountrySettings`

Mirrors `AppSettings` with a `country_id` FK. Stores per-country operational config by section.

```
country_id  Integer, FK → countries.id  }  composite PK
section     String(64)                   }
data        JSON,     NOT NULL
updated_at  DateTime, server_default now(), onupdate now()
updated_by  Text,     nullable
```

Sections: `pipeline`, `llm`, `email`, `scheduler`, `prompts`, `classification`, `rag`.

When a new country is created, every section is seeded from the corresponding `AppSettings` row (global defaults). `AppSettings` thus serves as the template for new countries.

### Modified tables

| Table | Change | Migration behaviour |
|---|---|---|
| `Source` | `country_id Integer FK → countries.id NOT NULL` | Set to BF id for all existing rows |
| `Run` | `country_id Integer FK → countries.id nullable` | Set to BF id for all existing rows |
| `Recipient` | `country_id Integer FK → countries.id nullable` | Set to BF id for all existing rows. Note: the `Recipient` DB table is migrated for data consistency but email targeting in v1 is driven by `CountrySettings["email"]` (same mechanism as the current `AppSettings["email"]`), not by querying the `Recipient` table directly. |

### Migration

Single Alembic migration `0003_add_countries.py`:
1. Create `countries` table
2. Insert seed row for Burkina Faso: `(name="Burkina Faso", code="BF", locale="fr", active=True)`
3. Add `country_id` columns to `sources`, `runs`, `recipients`
4. Backfill all existing rows to the BF country id
5. Create `country_settings` table
6. Seed `country_settings` from `app_settings` for BF (copy each section row)

---

## Section 2 — Pipeline

### `TenderAIState` additions

```python
country_id: int = Field(...)
country_config: Dict[str, Any] = Field(default_factory=dict)
# Keys: pipeline, llm, email, scheduler, prompts, classification, rag
```

### `TenderAIGraph.run()` signature

```python
def run(
    self,
    country_id: int,
    triggered_by: str = "scheduler",
    triggered_by_user: Optional[str] = None,
    sources_override: Optional[List[Dict]] = None,
    send_email: bool = True,
) -> TenderAIState:
```

At the top of `run()`, before invoking the graph:
1. Query `CountrySettings` for `country_id` — all sections in one DB round-trip.
2. For any missing section, fall back to `AppSettings` global value.
3. Inject the merged dict into `state.country_config`.
4. Set `state.country_id = country_id`.
5. Populate `Run.country_id` when creating the DB run record.

### Node changes

| Node | Change |
|---|---|
| `load_sources` | Query `Source` filtered by `country_id = state.country_id` |
| `classify` | Read prompts and `min_relevance_score` from `state.country_config["classification"]` |
| `summarize` | Read LLM prompts from `state.country_config["prompts"]` and model params from `["llm"]` |
| `compose_report` | Use `Country.name` and `Country.locale` for report title and language |
| `email_report` | Read `to_address`, `cc_address`, `subject_template` from `state.country_config["email"]` |

Nodes that do not use country-specific config (fetch, parse, deduplicate) are unchanged.

### Global singleton

`get_pipeline()` continues to return a single `TenderAIGraph` instance. No per-country caching needed.

---

## Section 3 — Scheduler

### Per-country jobs

```python
def start_scheduler():
    countries = get_active_countries(db)
    for country in countries:
        cron = get_country_setting(country.id, "scheduler")["cron_schedule"]
        timezone = get_country_setting(country.id, "scheduler")["timezone"]
        scheduler.add_job(
            scheduled_pipeline_run,
            args=[country.id],
            trigger=CronTrigger(..., timezone=timezone),
            id=f"pipeline_{country.code}",
            name=f"Pipeline {country.name}",
            misfire_grace_time=3600,
            coalesce=True,
            max_instances=1,
        )
```

### `scheduled_pipeline_run(country_id: int)`

```python
def scheduled_pipeline_run(country_id: int):
    reload_settings_from_db(db)          # global AppSettings
    reload_country_settings(country_id)  # invalidate country config cache
    pipeline = get_pipeline()
    pipeline.run(country_id=country_id, triggered_by="scheduler")
```

### Hot-reschedule on settings change

`PUT /countries/{country_id}/settings/scheduler` triggers `reschedule_country_job(country_id)`:
1. `scheduler.remove_job(f"pipeline_{country.code}")`
2. Re-add the job with the new cron from the just-saved `CountrySettings`.

The scheduler exposes `get_scheduler_instance()` so API handlers can call this without circular imports.

### `run_on_startup`

If `CountrySettings["scheduler"]["run_on_startup"]` is `True` for a country, its job fires once immediately at scheduler startup.

---

## Section 4 — API

### New router: `api/routers/countries.py`

```
GET    /api/v1/admin/countries
POST   /api/v1/admin/countries
GET    /api/v1/admin/countries/{country_id}
PUT    /api/v1/admin/countries/{country_id}
DELETE /api/v1/admin/countries/{country_id}          — soft-delete (sets active=False)

GET    /api/v1/admin/countries/{country_id}/settings
GET    /api/v1/admin/countries/{country_id}/settings/{section}
PUT    /api/v1/admin/countries/{country_id}/settings/{section}
       — if section == "scheduler": calls reschedule_country_job()

POST   /api/v1/admin/countries/{country_id}/run      — manual trigger
```

### POST `/countries` behaviour

1. Insert `Country` row.
2. For each settings section, copy the corresponding `AppSettings` row into `CountrySettings` (pre-filled defaults).
3. Return the created country with its seeded settings.

### Existing endpoints — `country_id` filter

| Endpoint | Change |
|---|---|
| `GET /runs` | Optional `?country_id=` query param |
| `GET /sources` | Optional `?country_id=` query param |
| `GET /notices` | Optional `?country_id=` query param (via join through `Run`) |
| `POST /runs` (manual trigger) | Body gains required `country_id` field |

Endpoints called without `country_id` return data across all countries (backward-compatible).

### Pydantic schemas

New file `api/schemas/countries.py`:
- `CountryCreate`: name, code, locale
- `CountryRead`: all fields + active
- `CountryUpdate`: name, locale, active (code is immutable after creation)

---

## Section 5 — Frontend

### Country context

New `CountryContext` (React context + provider) wraps the dashboard layout. Stores:
- `selectedCountry: Country | null`
- `countries: Country[]`
- `setSelectedCountry(country: Country): void`

Default: first active country returned by `GET /countries` (BF for existing installs).

### `CountrySelector` component

Dropdown in the top navigation bar listing all active countries. Persists selection to `localStorage` so it survives page refresh.

### Impacted pages

| Page | Change |
|---|---|
| `runs` | All API calls pass `country_id` from context |
| `sources` | API calls filtered; new source form pre-selects current country |
| `settings` | Loads `GET /countries/{id}/settings` instead of global `GET /settings` |
| `logs` | Filtered by `country_id` |
| `reports` | Filtered by `country_id` |

### New page: `/countries`

Accessible from admin sidebar. Contains:

1. **Country list** — table with name, code, locale, active toggle, edit/delete actions.
2. **Add country button** → multi-tab creation form:
   - Tab 1 — Basic info: name, code (ISO), locale
   - Tab 2 — Pipeline & LLM (pre-filled from global AppSettings)
   - Tab 3 — Scheduler: cron expression, timezone, run_on_startup
   - Tab 4 — Email & recipients
   - Tab 5 — System prompts
   - Tab 6 — Classification & RAG

On save, POSTs to `/api/v1/admin/countries` then shows the country detail page.

### Next.js proxy route

New file: `app/api/proxy/countries/[...path]/route.ts` — mirrors the existing proxy pattern in the project.

---

## Out of Scope (this spec)

- Per-country UNGM/source filtering by geography at the HTTP level (handled by configuring distinct `list_url` per source per country)
- Cross-country deduplication (notices are deduplicated within a country's run only)
- Per-country user roles/permissions
- Country-level audit log
