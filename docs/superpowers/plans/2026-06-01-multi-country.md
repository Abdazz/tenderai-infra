# Multi-Country Pipeline Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-class `Country` entity so every source, run, notice, recipient, pipeline execution, schedule, and config section is scoped to a country, managed from the admin dashboard without code changes or restarts.

**Architecture:** Single compiled `TenderAIGraph` shared across all countries (stateless between invocations). Country-specific config (prompts, thresholds, recipients, schedule) is loaded from a `CountrySettings` DB table at the start of each `run()` call and injected into `TenderAIState.country_config`. All nodes read country-specific values from `state.country_config` with fallback to global `AppSettings`. One APScheduler job per active country.

**Tech Stack:** Python 3.11, SQLAlchemy, Alembic, FastAPI, Pydantic v2, APScheduler, Next.js 14 (App Router), TypeScript, Tailwind CSS.

**Spec:** `docs/superpowers/specs/2026-06-01-multi-country-design.md`

---

## File Map

**New — backend:**
- `alembic/versions/0003_add_countries.py`
- `src/tenderai_bf/country_store.py`
- `src/tenderai_bf/api/routers/countries.py`
- `src/tenderai_bf/api/schemas/countries.py`
- `tests/test_country_store.py`
- `tests/api/test_countries_endpoints.py`

**Modified — backend:**
- `src/tenderai_bf/models.py` — add `Country`, `CountrySettings`; add `country_id` FK to `Source`, `Run`, `Recipient`
- `src/tenderai_bf/agents/graph.py` — `TenderAIState` + `run()` country context
- `src/tenderai_bf/agents/nodes/load_sources.py` — filter by `country_id`
- `src/tenderai_bf/agents/nodes/classify.py` — use `state.country_config`
- `src/tenderai_bf/agents/nodes/summarize.py` — use `state.country_config`
- `src/tenderai_bf/agents/nodes/email_report.py` — use `state.country_config["email"]`
- `src/tenderai_bf/scheduler/schedule.py` — per-country jobs + hot reschedule
- `src/tenderai_bf/api/main.py` — register countries router; seed BF at startup
- `src/tenderai_bf/api/routers/runs.py` — add `country_id` filter
- `src/tenderai_bf/api/routers/sources.py` — add `country_id` filter

**New — frontend:**
- `frontend/contexts/country-context.tsx`
- `frontend/components/country-selector.tsx`
- `frontend/app/(dashboard)/countries/page.tsx`
- `frontend/app/(dashboard)/countries/new/page.tsx`
- `frontend/app/api/proxy/countries/route.ts`
- `frontend/app/api/proxy/countries/[id]/route.ts`
- `frontend/app/api/proxy/countries/[id]/settings/route.ts`
- `frontend/app/api/proxy/countries/[id]/settings/[section]/route.ts`
- `frontend/app/api/proxy/countries/[id]/run/route.ts`

**Modified — frontend:**
- `frontend/components/sidebar.tsx` — add /countries link + `CountrySelector`
- `frontend/app/(dashboard)/layout.tsx` — wrap with `CountryProvider`
- `frontend/app/(dashboard)/settings/page.tsx` — load per-country settings
- `frontend/app/(dashboard)/runs/page.tsx` — pass `country_id` from context
- `frontend/app/(dashboard)/sources/page.tsx` — pass `country_id` from context

---

## Task 1: Country and CountrySettings models

**Files:**
- Modify: `src/tenderai_bf/models.py`
- Test: `tests/test_country_store.py` (model column tests)

- [ ] **Step 1: Write the failing model tests**

Create `tests/test_country_store.py`:

```python
import os
import pytest
from sqlalchemy import create_engine, inspect
from sqlalchemy.orm import Session

os.environ.setdefault("TENDERAI_JWT_SECRET", "test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx")
os.environ.setdefault("TENDERAI_ADMIN_PASSWORD", "test-admin-password-not-real")

from tenderai_bf.db import Base


@pytest.fixture
def db():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    with Session(engine) as session:
        yield session


def test_country_table_has_expected_columns(db):
    from tenderai_bf.models import Country
    engine = db.get_bind()
    inspector = inspect(engine)
    cols = {c["name"] for c in inspector.get_columns("countries")}
    assert {"id", "name", "code", "locale", "active", "created_at", "updated_at"}.issubset(cols)


def test_country_settings_table_has_expected_columns(db):
    from tenderai_bf.models import CountrySettings
    engine = db.get_bind()
    inspector = inspect(engine)
    cols = {c["name"] for c in inspector.get_columns("country_settings")}
    assert {"country_id", "section", "data", "updated_at", "updated_by"}.issubset(cols)


def test_source_has_country_id_column(db):
    engine = db.get_bind()
    inspector = inspect(engine)
    cols = {c["name"] for c in inspector.get_columns("sources")}
    assert "country_id" in cols


def test_run_has_country_id_column(db):
    engine = db.get_bind()
    inspector = inspect(engine)
    cols = {c["name"] for c in inspector.get_columns("runs")}
    assert "country_id" in cols
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /home/yulcom/web/tender-ai
poetry run pytest tests/test_country_store.py -v --no-cov
```
Expected: 4 failures — `countries`, `country_settings`, `country_id` columns don't exist yet.

- [ ] **Step 3: Add Country and CountrySettings to models.py**

In `src/tenderai_bf/models.py`, after the `AppSettings` class, add:

```python
class Country(Base):
    """Countries with independent pipeline configurations."""

    __tablename__ = "countries"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(255), nullable=False)
    code = Column(String(10), nullable=False, unique=True, index=True)
    locale = Column(String(10), nullable=False, default="fr")
    active = Column(Boolean, nullable=False, default=True, index=True)
    created_at = Column(DateTime, nullable=False, default=func.now())
    updated_at = Column(DateTime, nullable=False, default=func.now(), onupdate=func.now())

    settings = relationship("CountrySettings", back_populates="country", cascade="all, delete-orphan")
    sources = relationship("Source", back_populates="country")
    runs = relationship("Run", back_populates="country")

    def __repr__(self) -> str:
        return f"<Country(code='{self.code}', name='{self.name}', active={self.active})>"


class CountrySettings(Base):
    """Per-country operational settings, one row per section."""

    __tablename__ = "country_settings"

    country_id = Column(Integer, ForeignKey("countries.id"), primary_key=True)
    section = Column(String(64), primary_key=True)
    data = Column(JSON, nullable=False)
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())
    updated_by = Column(Text, nullable=True)

    country = relationship("Country", back_populates="settings")

    def __repr__(self) -> str:
        return f"<CountrySettings(country_id={self.country_id}, section='{self.section}')>"
```

Then add `country_id` FK to `Source`, `Run`, and `Recipient`. In the `Source` class, after the `enabled` column:

```python
    country_id = Column(Integer, ForeignKey("countries.id"), nullable=True, index=True)
```

In the `Source` relationships, add:
```python
    country = relationship("Country", back_populates="sources")
```

In the `Run` class, after `triggered_by_user`:
```python
    country_id = Column(Integer, ForeignKey("countries.id"), nullable=True, index=True)
```

In the `Run` relationships, add:
```python
    country = relationship("Country", back_populates="runs")
```

In the `Recipient` class, after `enabled`:
```python
    country_id = Column(Integer, ForeignKey("countries.id"), nullable=True, index=True)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
poetry run pytest tests/test_country_store.py -v --no-cov
```
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add src/tenderai_bf/models.py tests/test_country_store.py
git commit -m "feat(models): add Country, CountrySettings; add country_id FK to Source, Run, Recipient"
```

---

## Task 2: Alembic migration 0003

**Files:**
- Create: `alembic/versions/0003_add_countries.py`

- [ ] **Step 1: Create the migration file**

Create `alembic/versions/0003_add_countries.py`:

```python
"""add_countries

Revision ID: 0003
Revises: 0002
Create Date: 2026-06-01
"""
import sqlalchemy as sa
from alembic import op

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 1. Create countries table
    op.create_table(
        "countries",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("code", sa.String(10), nullable=False),
        sa.Column("locale", sa.String(10), nullable=False, server_default="fr"),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("code", name="uq_countries_code"),
    )

    # 2. Seed Burkina Faso as the default country
    op.execute(
        "INSERT INTO countries (name, code, locale, active) "
        "VALUES ('Burkina Faso', 'BF', 'fr', true)"
    )

    # 3. sources.country_id — nullable first for backfill, then NOT NULL
    op.add_column("sources", sa.Column("country_id", sa.Integer(), nullable=True))
    op.execute("UPDATE sources SET country_id = (SELECT id FROM countries WHERE code = 'BF')")
    op.alter_column("sources", "country_id", nullable=False)
    op.create_foreign_key("fk_sources_country_id", "sources", "countries", ["country_id"], ["id"])

    # 4. runs.country_id — nullable (older runs may not have a country)
    op.add_column("runs", sa.Column("country_id", sa.Integer(), nullable=True))
    op.execute("UPDATE runs SET country_id = (SELECT id FROM countries WHERE code = 'BF')")
    op.create_foreign_key("fk_runs_country_id", "runs", "countries", ["country_id"], ["id"])

    # 5. recipients.country_id — nullable
    op.add_column("recipients", sa.Column("country_id", sa.Integer(), nullable=True))
    op.execute("UPDATE recipients SET country_id = (SELECT id FROM countries WHERE code = 'BF')")
    op.create_foreign_key("fk_recipients_country_id", "recipients", "countries", ["country_id"], ["id"])

    # 6. Create country_settings table
    op.create_table(
        "country_settings",
        sa.Column("country_id", sa.Integer(), nullable=False),
        sa.Column("section", sa.String(64), nullable=False),
        sa.Column("data", sa.JSON(), nullable=False),
        sa.Column(
            "updated_at",
            sa.DateTime(),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column("updated_by", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("country_id", "section"),
        sa.ForeignKeyConstraint(["country_id"], ["countries.id"], name="fk_country_settings_country_id"),
    )

    # 7. Seed country_settings for BF from app_settings
    op.execute("""
        INSERT INTO country_settings (country_id, section, data, updated_by)
        SELECT
            (SELECT id FROM countries WHERE code = 'BF'),
            section,
            data,
            'migration_0003'
        FROM app_settings
    """)


def downgrade() -> None:
    op.drop_table("country_settings")
    op.drop_constraint("fk_recipients_country_id", "recipients", type_="foreignkey")
    op.drop_column("recipients", "country_id")
    op.drop_constraint("fk_runs_country_id", "runs", type_="foreignkey")
    op.drop_column("runs", "country_id")
    op.drop_constraint("fk_sources_country_id", "sources", type_="foreignkey")
    op.drop_column("sources", "country_id")
    op.drop_table("countries")
```

- [ ] **Step 2: Run the migration against the dev database**

```bash
make migrate
```
Expected: `Running upgrade 0002 -> 0003` with no errors.

- [ ] **Step 3: Verify the migration**

```bash
poetry run python -c "
from sqlalchemy import create_engine, inspect, text
import os
engine = create_engine(os.environ['TENDERAI_DATABASE_URL'])
insp = inspect(engine)
with engine.connect() as conn:
    bf = conn.execute(text('SELECT id, name, code FROM countries WHERE code = :c'), {'c': 'BF'}).fetchone()
    print('BF country:', bf)
    cs_count = conn.execute(text('SELECT COUNT(*) FROM country_settings')).scalar()
    print('country_settings rows:', cs_count)
"
```
Expected: BF country row printed, `country_settings` rows ≥ number of `app_settings` rows.

- [ ] **Step 4: Commit**

```bash
git add alembic/versions/0003_add_countries.py
git commit -m "feat(db): migration 0003 — countries, country_settings, country_id FKs, seed BF"
```

---

## Task 3: CountryStore

**Files:**
- Create: `src/tenderai_bf/country_store.py`
- Modify: `tests/test_country_store.py` (add CountryStore tests)

- [ ] **Step 1: Add CountryStore tests**

Append to `tests/test_country_store.py`:

```python
def test_country_store_get_section_returns_none_when_absent(db):
    from tenderai_bf.models import Country
    from tenderai_bf.country_store import CountryStore
    country = Country(name="Test", code="XX", locale="fr")
    db.add(country)
    db.commit()
    assert CountryStore.get_section(db, country.id, "pipeline") is None


def test_country_store_put_and_get_section(db):
    from tenderai_bf.models import Country
    from tenderai_bf.country_store import CountryStore
    country = Country(name="Test", code="TT", locale="fr")
    db.add(country)
    db.commit()
    CountryStore.put_section(db, country.id, "pipeline", {"min_relevance_score": 0.6}, updated_by="test")
    result = CountryStore.get_section(db, country.id, "pipeline")
    assert result == {"min_relevance_score": 0.6}


def test_country_store_get_all_with_fallback_uses_global_for_missing(db):
    from tenderai_bf.models import Country, AppSettings
    from tenderai_bf.country_store import CountryStore
    # Insert global setting
    db.add(AppSettings(section="email", data={"to_address": "global@example.com"}, updated_by="test"))
    db.commit()
    # Country with no country-specific email setting
    country = Country(name="New", code="NW", locale="fr")
    db.add(country)
    db.commit()
    result = CountryStore.get_all_with_fallback(db, country.id)
    assert result["email"]["to_address"] == "global@example.com"


def test_country_store_get_all_with_fallback_country_overrides_global(db):
    from tenderai_bf.models import Country, AppSettings
    from tenderai_bf.country_store import CountryStore
    db.add(AppSettings(section="email", data={"to_address": "global@example.com"}, updated_by="test"))
    db.commit()
    country = Country(name="Override", code="OV", locale="fr")
    db.add(country)
    db.commit()
    CountryStore.put_section(db, country.id, "email", {"to_address": "country@example.com"}, updated_by="test")
    result = CountryStore.get_all_with_fallback(db, country.id)
    assert result["email"]["to_address"] == "country@example.com"


def test_country_store_seed_from_global_copies_all_sections(db):
    from tenderai_bf.models import Country, AppSettings
    from tenderai_bf.country_store import CountryStore
    db.add(AppSettings(section="pipeline", data={"max_items_per_run": 100}, updated_by="test"))
    db.add(AppSettings(section="llm", data={"provider": "groq"}, updated_by="test"))
    db.commit()
    country = Country(name="Seed", code="SD", locale="fr")
    db.add(country)
    db.commit()
    seeded = CountryStore.seed_from_global(db, country.id)
    assert set(seeded) == {"pipeline", "llm"}
    assert CountryStore.get_section(db, country.id, "pipeline") == {"max_items_per_run": 100}
```

- [ ] **Step 2: Run to verify failure**

```bash
poetry run pytest tests/test_country_store.py -v --no-cov
```
Expected: 5 new failures — `country_store` module not found.

- [ ] **Step 3: Create country_store.py**

Create `src/tenderai_bf/country_store.py`:

```python
"""Per-country DB-backed settings store. One row per (country_id, section) in country_settings."""

from typing import Optional
from sqlalchemy.orm import Session

from .models import AppSettings, CountrySettings

MUTABLE_SECTIONS = frozenset(
    {"pipeline", "scheduler", "llm", "email", "rag", "classification", "prompts"}
)


class CountryStore:

    @staticmethod
    def get_section(db: Session, country_id: int, section: str) -> Optional[dict]:
        row = (
            db.query(CountrySettings)
            .filter(
                CountrySettings.country_id == country_id,
                CountrySettings.section == section,
            )
            .first()
        )
        return row.data if row else None

    @staticmethod
    def put_section(
        db: Session, country_id: int, section: str, data: dict, updated_by: str = "system"
    ) -> None:
        row = CountrySettings(
            country_id=country_id, section=section, data=data, updated_by=updated_by
        )
        db.merge(row)
        db.commit()

    @staticmethod
    def get_all(db: Session, country_id: int) -> dict[str, dict]:
        rows = (
            db.query(CountrySettings)
            .filter(CountrySettings.country_id == country_id)
            .all()
        )
        return {row.section: row.data for row in rows}

    @staticmethod
    def get_all_with_fallback(db: Session, country_id: int) -> dict[str, dict]:
        """Return per-country settings, falling back to global AppSettings for missing sections."""
        global_rows = db.query(AppSettings).all()
        merged = {row.section: row.data for row in global_rows}
        country_rows = db.query(CountrySettings).filter(
            CountrySettings.country_id == country_id
        ).all()
        for row in country_rows:
            merged[row.section] = row.data
        return merged

    @staticmethod
    def seed_from_global(db: Session, country_id: int) -> list[str]:
        """Copy AppSettings rows into CountrySettings for a new country. Idempotent."""
        global_rows = db.query(AppSettings).all()
        seeded: list[str] = []
        for row in global_rows:
            exists = (
                db.query(CountrySettings)
                .filter(
                    CountrySettings.country_id == country_id,
                    CountrySettings.section == row.section,
                )
                .first()
            )
            if not exists:
                db.add(
                    CountrySettings(
                        country_id=country_id,
                        section=row.section,
                        data=row.data,
                        updated_by="seed",
                    )
                )
                seeded.append(row.section)
        db.commit()
        return seeded
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
poetry run pytest tests/test_country_store.py -v --no-cov
```
Expected: all 9 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/tenderai_bf/country_store.py tests/test_country_store.py
git commit -m "feat: CountryStore — per-country settings CRUD with global fallback"
```

---

## Task 4: TenderAIState + TenderAIGraph.run() country context

**Files:**
- Modify: `src/tenderai_bf/agents/graph.py`

- [ ] **Step 1: Write failing tests for run() with country_id**

Create `tests/test_pipeline_country.py`:

```python
import os
import pytest
from unittest.mock import MagicMock, patch

os.environ.setdefault("TENDERAI_JWT_SECRET", "test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx")
os.environ.setdefault("TENDERAI_ADMIN_PASSWORD", "test-admin-password-not-real")


def test_tenderai_state_has_country_fields():
    from tenderai_bf.agents.graph import TenderAIState
    state = TenderAIState(country_id=1)
    assert state.country_id == 1
    assert state.country_name == ""
    assert state.country_locale == "fr"
    assert state.country_config == {}


def test_run_sets_country_id_on_state():
    """run() must inject country context into state before graph execution."""
    from tenderai_bf.agents.graph import TenderAIGraph

    mock_country = MagicMock()
    mock_country.id = 1
    mock_country.name = "Burkina Faso"
    mock_country.locale = "fr"

    mock_config = {"pipeline": {"min_relevance_score": 0.5}, "email": {"to_address": "x@y.com"}}

    with patch("tenderai_bf.agents.graph.get_db_context") as mock_db_ctx, \
         patch("tenderai_bf.agents.graph.CountryStore") as mock_store:

        mock_session = MagicMock()
        mock_session.query.return_value.filter.return_value.first.return_value = mock_country
        mock_db_ctx.return_value.__enter__ = lambda s: mock_session
        mock_db_ctx.return_value.__exit__ = MagicMock(return_value=False)
        mock_store.get_all_with_fallback.return_value = mock_config

        graph = TenderAIGraph()

        captured_state = {}
        original_invoke = graph.app.invoke

        def mock_invoke(state, *a, **kw):
            captured_state["country_id"] = state.country_id
            captured_state["country_name"] = state.country_name
            captured_state["country_config"] = state.country_config
            return state

        graph.app.invoke = mock_invoke
        graph.run(country_id=1, triggered_by="test")

        assert captured_state["country_id"] == 1
        assert captured_state["country_name"] == "Burkina Faso"
        assert captured_state["country_config"] == mock_config
```

- [ ] **Step 2: Run to verify failure**

```bash
poetry run pytest tests/test_pipeline_country.py -v --no-cov
```
Expected: failures — `TenderAIState` has no `country_id` field, `run()` doesn't accept `country_id`.

- [ ] **Step 3: Update TenderAIState in graph.py**

In `src/tenderai_bf/agents/graph.py`, add three fields to `TenderAIState` after `started_at`:

```python
    # Country context — populated by run() before graph execution
    country_id: int = 0
    country_name: str = ""
    country_locale: str = "fr"
    country_config: Dict[str, Any] = Field(default_factory=dict)
```

- [ ] **Step 4: Update TenderAIGraph.run() signature and country loading**

Replace the `run()` method signature from:
```python
    def run(self, 
            triggered_by: str = "scheduler",
            triggered_by_user: Optional[str] = None,
            sources_override: Optional[List[Dict]] = None,
            send_email: bool = True) -> TenderAIState:
```
to:
```python
    def run(self,
            country_id: int,
            triggered_by: str = "scheduler",
            triggered_by_user: Optional[str] = None,
            sources_override: Optional[List[Dict]] = None,
            send_email: bool = True) -> TenderAIState:
```

At the very start of `run()`, right after `state = TenderAIState()`, add the country loading block (before the `log_run_start` call):

```python
        # Load country context
        from ..country_store import CountryStore
        from ..models import Country as CountryModel
        try:
            with get_db_context() as _db:
                _country = _db.query(CountryModel).filter(CountryModel.id == country_id).first()
                if not _country:
                    state.add_error("pipeline", f"Country {country_id} not found")
                    state.error_occurred = True
                    return state
                state.country_id = country_id
                state.country_name = _country.name
                state.country_locale = _country.locale
                state.country_config = CountryStore.get_all_with_fallback(_db, country_id)
        except Exception as _e:
            state.add_error("pipeline", f"Failed to load country config: {_e}")
            state.error_occurred = True
            return state
```

Also update the `Run` creation block inside `run()` to include `country_id`:
```python
                run = Run(
                    id=run_id,
                    status="running",
                    started_at=state.started_at,
                    triggered_by=triggered_by,
                    triggered_by_user=triggered_by_user,
                    country_id=country_id,
                )
```

- [ ] **Step 5: Update callers of run() in cli.py and admin router**

In `src/tenderai_bf/cli.py`, find the `run_once` command and update the `pipeline.run()` call to pass `country_id`. For now, add a `--country-id` option with default `1`:

```python
# Find: pipeline.run(triggered_by="cli", ...)
# Replace with:
pipeline.run(country_id=country_id, triggered_by="cli", ...)
```

Add a `country_id` parameter to the CLI command:
```python
@app.command()
def run_once(
    country_id: int = typer.Option(1, "--country-id", help="Country ID to run pipeline for"),
    ...
):
```

In `src/tenderai_bf/api/routers/admin.py`, find `POST /run` or the manual run endpoint and update to pass `country_id`. Add `country_id: int` to the request body model and pass it to `pipeline.run()`.

- [ ] **Step 6: Run tests to verify they pass**

```bash
poetry run pytest tests/test_pipeline_country.py -v --no-cov
```
Expected: all 2 tests PASS.

- [ ] **Step 7: Run full test suite to catch regressions**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Expected: all existing tests PASS (callers updated in step 5).

- [ ] **Step 8: Commit**

```bash
git add src/tenderai_bf/agents/graph.py src/tenderai_bf/cli.py src/tenderai_bf/api/routers/admin.py tests/test_pipeline_country.py
git commit -m "feat(pipeline): TenderAIState country context + run(country_id) signature"
```

---

## Task 5: load_sources node — filter by country_id

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/load_sources.py`

- [ ] **Step 1: Write failing test**

Append to `tests/test_pipeline_country.py`:

```python
def test_load_sources_filters_by_country_id():
    """In DB mode, load_sources must query only sources belonging to state.country_id."""
    from tenderai_bf.agents.graph import TenderAIState
    from tenderai_bf.agents.nodes.load_sources import load_sources_node

    state = TenderAIState(country_id=42)
    state.country_config = {"pipeline": {}}

    source_bf = {"id": 1, "name": "Source BF", "country_id": 42, "enabled": True,
                 "base_url": "http://bf.example", "list_url": "http://bf.example/list",
                 "parser_type": "html", "rate_limit": "10/m", "patterns": {}}

    mock_session = MagicMock()
    mock_query = MagicMock()
    mock_session.query.return_value = mock_query
    mock_query.filter.return_value = mock_query
    mock_query.all.return_value = []

    with patch("tenderai_bf.agents.nodes.load_sources.get_db_context") as mock_ctx, \
         patch("tenderai_bf.agents.nodes.load_sources.settings") as mock_settings:
        mock_settings.use_database_sources = True
        mock_settings.get_active_sources.return_value = []
        mock_ctx.return_value.__enter__ = lambda s: mock_session
        mock_ctx.return_value.__exit__ = MagicMock(return_value=False)

        load_sources_node(state)

        # The query must have been filtered — check that filter was called at least once
        assert mock_session.query.called
```

- [ ] **Step 2: Run to confirm it fails**

```bash
poetry run pytest tests/test_pipeline_country.py::test_load_sources_filters_by_country_id -v --no-cov
```

- [ ] **Step 3: Update load_sources.py to filter by country_id**

In `src/tenderai_bf/agents/nodes/load_sources.py`, in the DB mode section (MODE 2), update the `Source` query that finds an existing source:

```python
# Replace:
db_source = session.query(Source).filter(
    Source.name == source_name
).first()

# With:
db_source = session.query(Source).filter(
    Source.name == source_name,
    Source.country_id == state.country_id,
).first()
```

When creating a new source in DB mode, add `country_id`:
```python
db_source = Source(
    name=source_name,
    base_url=config_source.get('base_url', ''),
    list_url=config_source.get('list_url', ''),
    parser_type=config_source.get('parser', 'html'),
    rate_limit=config_source.get('rate_limit', '10/m'),
    enabled=config_source.get('enabled', True),
    patterns=config_source.get('patterns', {}),
    country_id=state.country_id,
)
```

- [ ] **Step 4: Run tests**

```bash
poetry run pytest tests/test_pipeline_country.py -v --no-cov
```
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/tenderai_bf/agents/nodes/load_sources.py tests/test_pipeline_country.py
git commit -m "feat(nodes): load_sources filters sources by state.country_id"
```

---

## Task 6: classify node — use state.country_config

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/classify.py`

- [ ] **Step 1: Write failing test**

Append to `tests/test_pipeline_country.py`:

```python
def test_classify_uses_country_keywords():
    """classify_with_keywords must use state.country_config['classification']['relevant_keywords']."""
    from tenderai_bf.agents.graph import TenderAIState
    from tenderai_bf.agents.nodes.classify import classify_with_keywords

    state = TenderAIState(country_id=1)
    state.country_config = {
        "classification": {"relevant_keywords": {"it": ["informatique", "logiciel"]}},
        "pipeline": {"min_relevance_score": 0.5, "use_llm_classification": False},
    }
    state.items_parsed = [
        {"title": "Fourniture de logiciel", "description": "Achat logiciel", "url": "http://x.com"}
    ]

    result = classify_with_keywords(state)
    relevant = [i for i in result.items_parsed if i.get("is_relevant")]
    assert len(relevant) == 1


def test_classify_uses_country_min_relevance_score():
    """Classify must use state.country_config['pipeline']['min_relevance_score']."""
    from tenderai_bf.agents.graph import TenderAIState
    from tenderai_bf.agents.nodes.classify import classify_with_keywords

    state = TenderAIState(country_id=1)
    state.country_config = {
        "classification": {"relevant_keywords": {"all": ["xyz_never_matches"]}},
        "pipeline": {"min_relevance_score": 0.99, "use_llm_classification": False},
    }
    state.items_parsed = [
        {"title": "Travaux routiers", "description": "Construction route", "url": "http://x.com"}
    ]

    result = classify_with_keywords(state)
    assert all(not i.get("is_relevant") for i in result.items_parsed)
```

- [ ] **Step 2: Run to confirm failure**

```bash
poetry run pytest tests/test_pipeline_country.py::test_classify_uses_country_keywords tests/test_pipeline_country.py::test_classify_uses_country_min_relevance_score -v --no-cov
```

- [ ] **Step 3: Update classify.py to use state.country_config**

In `src/tenderai_bf/agents/nodes/classify.py`, in the `classify_node` function, replace:
```python
        if settings.processing.use_llm_classification:
```
with:
```python
        _pipeline_cfg = getattr(state, 'country_config', {}).get("pipeline", {})
        _use_llm = _pipeline_cfg.get("use_llm_classification", settings.processing.use_llm_classification)
        if _use_llm:
```

In `classify_with_keywords`, replace the keywords loading block:
```python
        if hasattr(settings, 'classification') and hasattr(settings.classification, 'relevant_keywords'):
            # Load from settings
            relevant_keywords = settings.classification.relevant_keywords
            for category, keywords in relevant_keywords.items():
                it_keywords.extend(keywords)
```
with:
```python
        _cls_cfg = getattr(state, 'country_config', {}).get("classification", {})
        relevant_keywords = _cls_cfg.get("relevant_keywords", None)
        if relevant_keywords is None and hasattr(settings, 'classification') and hasattr(settings.classification, 'relevant_keywords'):
            relevant_keywords = settings.classification.relevant_keywords
        if relevant_keywords:
            for category, keywords in relevant_keywords.items():
                it_keywords.extend(keywords)
```

Replace all three occurrences of `settings.processing.min_relevance_score` in `classify_with_keywords` with:
```python
getattr(state, 'country_config', {}).get("pipeline", {}).get("min_relevance_score", settings.processing.min_relevance_score)
```

- [ ] **Step 4: Run tests**

```bash
poetry run pytest tests/test_pipeline_country.py -v --no-cov
```
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/tenderai_bf/agents/nodes/classify.py tests/test_pipeline_country.py
git commit -m "feat(nodes): classify reads keywords and thresholds from state.country_config"
```

---

## Task 7: summarize, compose_report, and email_report nodes — use state.country_config

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/summarize.py`
- Modify: `src/tenderai_bf/agents/nodes/compose_report.py`
- Modify: `src/tenderai_bf/agents/nodes/email_report.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_pipeline_country.py`:

```python
def test_summarize_uses_country_prompts():
    """generate_summary_with_llm must use state.country_config['prompts']['summarization']."""
    from tenderai_bf.agents.graph import TenderAIState
    from tenderai_bf.agents.nodes.summarize import generate_summary_with_llm

    state = TenderAIState(country_id=1)
    state.country_config = {
        "prompts": {
            "summarization": {
                "system": "Tu es un assistant pour la Côte d'Ivoire.",
                "user_template": "Résume: {tender_details}",
            }
        },
        "llm": {"provider": "groq"},
    }

    item = {"title": "Test", "description": "Desc", "url": "http://x.com"}

    with patch("tenderai_bf.agents.nodes.summarize.get_llm_instance") as mock_llm_fn:
        mock_llm = MagicMock()
        mock_llm.invoke.return_value = MagicMock(content="Résumé test")
        mock_llm_fn.return_value = mock_llm

        result = generate_summary_with_llm(item, state=state)
        assert result == "Résumé test"
        # Verify the country prompt was used
        call_arg = mock_llm.invoke.call_args[0][0]
        assert "Côte d'Ivoire" in str(call_arg) or "Résume" in str(call_arg)


def test_email_report_uses_country_to_address():
    """email_report must use state.country_config['email']['to_address']."""
    from tenderai_bf.agents.graph import TenderAIState

    state = TenderAIState(country_id=1)
    state.country_config = {"email": {"to_address": "ci-team@example.com", "from_address": "bot@example.com", "subject_prefix": "[CI]", "from_name": "Bot", "signature": ""}}
    state.report_bytes = b"fake pdf"
    state.report_url = "http://minio/report.docx"

    with patch("tenderai_bf.agents.nodes.email_report.settings") as mock_settings, \
         patch("tenderai_bf.agents.nodes.email_report.SMTPClient") as mock_smtp_cls:
        mock_settings.email.to_address = "global@example.com"
        mock_settings.is_production = False
        mock_settings.recipients = []
        mock_smtp = MagicMock()
        mock_smtp.send_email.return_value = True
        mock_smtp_cls.return_value.__enter__ = lambda s: mock_smtp
        mock_smtp_cls.return_value.__exit__ = MagicMock(return_value=False)

        from tenderai_bf.agents.nodes.email_report import email_report_node
        email_report_node(state)

        call_kwargs = mock_smtp.send_email.call_args
        recipients_used = call_kwargs[1].get("recipients") or call_kwargs[0][0] if call_kwargs else []
        assert "ci-team@example.com" in str(recipients_used)
        assert "global@example.com" not in str(recipients_used)
```

- [ ] **Step 2: Run to confirm failure**

```bash
poetry run pytest tests/test_pipeline_country.py::test_summarize_uses_country_prompts tests/test_pipeline_country.py::test_email_report_uses_country_to_address -v --no-cov
```

- [ ] **Step 3: Update summarize.py**

In `src/tenderai_bf/agents/nodes/summarize.py`, update `generate_summary_with_llm` to accept an optional `state` parameter and use country prompts:

Change the signature from:
```python
def generate_summary_with_llm(item: Dict) -> str:
```
to:
```python
def generate_summary_with_llm(item: Dict, state=None) -> str:
```

Replace the prompts loading block:
```python
        # Get summarization prompts from configuration
        summarization_prompts = settings.prompts.get('summarization', {})
        system_prompt = summarization_prompts.get('system', '')
        user_template = summarization_prompts.get('user_template', '')
```
with:
```python
        # Get summarization prompts — country-specific if available
        _prompts_cfg = getattr(state, 'country_config', {}).get("prompts", {}) if state else {}
        _global_prompts = settings.prompts if hasattr(settings, 'prompts') else {}
        _summ = _prompts_cfg.get("summarization") or (
            _global_prompts.get("summarization", {}) if isinstance(_global_prompts, dict)
            else getattr(_global_prompts, "summarization", {})
        )
        if hasattr(_summ, "dict"):
            _summ = _summ.dict()
        summarization_prompts = _summ if isinstance(_summ, dict) else {}
        system_prompt = summarization_prompts.get('system', '')
        user_template = summarization_prompts.get('user_template', '')
```

In the `summarize_node` function, find where `generate_summary_with_llm(item)` is called and update it to pass state:
```python
# Replace:
summary_fr = generate_summary_with_llm(item)
# With:
summary_fr = generate_summary_with_llm(item, state=state)
```

- [ ] **Step 4: Update compose_report.py to use country name and locale**

In `src/tenderai_bf/agents/nodes/compose_report.py`, find where the report title or country name is referenced and replace any hardcoded "Burkina Faso" string with `getattr(state, 'country_name', 'Burkina Faso')`. Also pass `getattr(state, 'country_locale', 'fr')` to any locale-dependent report generation call (e.g., report title language, date formatting). If the report class accepts a `country_name` parameter, pass `state.country_name`; otherwise patch the title string directly.

Example replacement pattern (adapt to actual code):
```python
# Replace any hardcoded country name, e.g.:
# report_title = "Rapport de veille — Burkina Faso"
# With:
country_name = getattr(state, 'country_name', 'Burkina Faso')
report_title = f"Rapport de veille — {country_name}"
```

- [ ] **Step 5: Update email_report.py**

In `src/tenderai_bf/agents/nodes/email_report.py`, replace the recipients loading block:
```python
    if settings.email.to_address:
        recipients.append(settings.email.to_address)
    if settings.is_production and settings.recipients:
        for recipient in settings.recipients:
            if 'email' in recipient and recipient['email'] not in recipients:
                recipients.append(recipient['email'])
```
with:
```python
    _email_cfg = getattr(state, 'country_config', {}).get("email", {})
    _to = _email_cfg.get("to_address") or settings.email.to_address
    if _to:
        recipients.append(_to)
    if settings.is_production and settings.recipients:
        for recipient in settings.recipients:
            if 'email' in recipient and recipient['email'] not in recipients:
                recipients.append(recipient['email'])
```

- [ ] **Step 6: Run all pipeline country tests**

```bash
poetry run pytest tests/test_pipeline_country.py -v --no-cov
```
Expected: all tests PASS.

- [ ] **Step 7: Run full test suite**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Expected: all PASS.

- [ ] **Step 8: Commit**

```bash
git add src/tenderai_bf/agents/nodes/summarize.py src/tenderai_bf/agents/nodes/compose_report.py src/tenderai_bf/agents/nodes/email_report.py tests/test_pipeline_country.py
git commit -m "feat(nodes): summarize, compose_report, and email_report use state.country_config"
```

---

## Task 8: Scheduler — per-country jobs and hot reschedule

**Files:**
- Modify: `src/tenderai_bf/scheduler/schedule.py`

- [ ] **Step 1: Write failing tests**

Create `tests/test_scheduler_country.py`:

```python
import os
import pytest
from unittest.mock import MagicMock, patch, call

os.environ.setdefault("TENDERAI_JWT_SECRET", "test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx")
os.environ.setdefault("TENDERAI_ADMIN_PASSWORD", "test-admin-password-not-real")


def test_get_scheduler_instance_returns_none_before_start():
    from tenderai_bf.scheduler.schedule import get_scheduler_instance
    # reset module state
    import tenderai_bf.scheduler.schedule as sched_mod
    sched_mod._scheduler_instance = None
    assert get_scheduler_instance() is None


def test_reschedule_country_job_does_nothing_when_scheduler_not_started():
    import tenderai_bf.scheduler.schedule as sched_mod
    sched_mod._scheduler_instance = None
    # Should not raise
    from tenderai_bf.scheduler.schedule import reschedule_country_job
    reschedule_country_job(1, "BF", {"cron_schedule": "0 7 * * *", "timezone": "UTC", "enabled": True})


def test_reschedule_country_job_replaces_existing_job():
    from tenderai_bf.scheduler.schedule import reschedule_country_job
    import tenderai_bf.scheduler.schedule as sched_mod

    mock_scheduler = MagicMock()
    mock_scheduler.get_job.return_value = MagicMock()  # job exists
    sched_mod._scheduler_instance = mock_scheduler

    reschedule_country_job(
        1, "BF",
        {"cron_schedule": "0 8 * * *", "timezone": "Africa/Abidjan", "enabled": True,
         "max_concurrent_runs": 1}
    )

    mock_scheduler.remove_job.assert_called_once_with("pipeline_BF")
    mock_scheduler.add_job.assert_called_once()
    add_call_kwargs = mock_scheduler.add_job.call_args[1]
    assert add_call_kwargs["id"] == "pipeline_BF"


def test_reschedule_country_job_disabled_removes_without_readding():
    from tenderai_bf.scheduler.schedule import reschedule_country_job
    import tenderai_bf.scheduler.schedule as sched_mod

    mock_scheduler = MagicMock()
    mock_scheduler.get_job.return_value = MagicMock()
    sched_mod._scheduler_instance = mock_scheduler

    reschedule_country_job(1, "CI", {"cron_schedule": "0 7 * * *", "timezone": "UTC", "enabled": False})

    mock_scheduler.remove_job.assert_called_once_with("pipeline_CI")
    mock_scheduler.add_job.assert_not_called()
```

- [ ] **Step 2: Run to confirm failure**

```bash
poetry run pytest tests/test_scheduler_country.py -v --no-cov
```
Expected: failures — `get_scheduler_instance` and `reschedule_country_job` don't exist.

- [ ] **Step 3: Rewrite schedule.py**

Replace the content of `src/tenderai_bf/scheduler/schedule.py` with:

```python
"""APScheduler-based scheduling for TenderAI BF — one job per active country."""

import pytz
from apscheduler.schedulers.blocking import BlockingScheduler
from apscheduler.triggers.cron import CronTrigger

from ..agents import get_pipeline
from ..config import settings
from ..logging import get_logger

logger = get_logger(__name__)

_scheduler_instance = None


def get_scheduler_instance() -> BlockingScheduler | None:
    """Return the running scheduler, or None if not started."""
    return _scheduler_instance


def _make_trigger(cron_schedule: str, timezone_str: str) -> CronTrigger:
    tz = pytz.timezone(timezone_str)
    minute, hour, day, month, dow = cron_schedule.strip().split()
    return CronTrigger(
        minute=minute, hour=hour, day=day, month=month, day_of_week=dow, timezone=tz
    )


def reschedule_country_job(country_id: int, country_code: str, scheduler_cfg: dict) -> None:
    """Remove and optionally re-add the APScheduler job for a country.

    Called by the settings API when a country's scheduler section is updated.
    No-op if the scheduler hasn't been started yet.
    """
    scheduler = get_scheduler_instance()
    if scheduler is None:
        return

    job_id = f"pipeline_{country_code}"
    if scheduler.get_job(job_id):
        scheduler.remove_job(job_id)

    if not scheduler_cfg.get("enabled", True):
        return

    trigger = _make_trigger(
        scheduler_cfg["cron_schedule"],
        scheduler_cfg.get("timezone", "UTC"),
    )
    scheduler.add_job(
        scheduled_pipeline_run,
        args=[country_id],
        trigger=trigger,
        id=job_id,
        name=f"Pipeline {country_code}",
        misfire_grace_time=3600,
        coalesce=True,
        max_instances=scheduler_cfg.get("max_concurrent_runs", 1),
    )
    logger.info("Country job rescheduled", country_code=country_code, cron=scheduler_cfg["cron_schedule"])


def scheduled_pipeline_run(country_id: int) -> None:
    """Execute the pipeline for one country as a scheduled job."""

    try:
        from ..db import get_session_factory
        from ..config import reload_settings_from_db
        SessionLocal = get_session_factory()
        db_session = SessionLocal()
        try:
            reload_settings_from_db(db_session)
        finally:
            db_session.close()
    except Exception as e:
        logger.warning("Could not reload settings from DB before run", error=str(e))

    logger.info("Starting scheduled pipeline run", country_id=country_id)

    try:
        pipeline = get_pipeline()
        result = pipeline.run(country_id=country_id, triggered_by="scheduler")

        if result.error_occurred:
            logger.error(
                "Scheduled pipeline run failed",
                country_id=country_id,
                errors_count=len(result.errors),
                run_id=result.run_id,
            )
        elif result.warnings:
            logger.warning(
                "Scheduled pipeline run completed with warnings",
                country_id=country_id,
                run_id=result.run_id,
                warnings_count=len(result.warnings),
            )
        else:
            logger.info(
                "Scheduled pipeline run completed",
                country_id=country_id,
                run_id=result.run_id,
                relevant_items=result.stats.relevant_items,
                duration_seconds=result.stats.total_time_seconds,
            )
    except Exception as e:
        logger.error(
            "Scheduled pipeline run exception",
            country_id=country_id,
            error=str(e),
            exc_info=True,
        )


def start_scheduler() -> None:
    """Start the APScheduler daemon with one job per active country."""
    global _scheduler_instance

    logger.info("Starting TenderAI BF scheduler")

    # Load active countries
    from ..db import get_session_factory
    from ..models import Country
    from ..country_store import CountryStore

    SessionLocal = get_session_factory()
    db_session = SessionLocal()
    try:
        countries = db_session.query(Country).filter(Country.active == True).all()
        country_configs = {
            c.id: (c, CountryStore.get_all_with_fallback(db_session, c.id))
            for c in countries
        }
    finally:
        db_session.close()

    # Default scheduler config in case a country has none
    _default_cron = settings.scheduler.cron_schedule
    _default_tz = settings.scheduler.timezone

    timezone = pytz.timezone(_default_tz)
    scheduler = BlockingScheduler(timezone=timezone)
    _scheduler_instance = scheduler

    for country_id, (country, config) in country_configs.items():
        sched_cfg = config.get("scheduler", {})
        cron = sched_cfg.get("cron_schedule", _default_cron)
        tz_str = sched_cfg.get("timezone", _default_tz)
        enabled = sched_cfg.get("enabled", True)
        max_inst = sched_cfg.get("max_concurrent_runs", settings.scheduler.max_concurrent_runs)
        run_on_startup = sched_cfg.get("run_on_startup", False)

        if not enabled:
            logger.info("Country scheduler disabled, skipping", country_code=country.code)
            continue

        trigger = _make_trigger(cron, tz_str)
        scheduler.add_job(
            scheduled_pipeline_run,
            args=[country_id],
            trigger=trigger,
            id=f"pipeline_{country.code}",
            name=f"Pipeline {country.name}",
            misfire_grace_time=3600,
            coalesce=True,
            max_instances=max_inst,
        )
        logger.info(
            "Scheduler job added",
            country_code=country.code,
            cron_schedule=cron,
            timezone=tz_str,
        )

        if run_on_startup:
            logger.info("Running pipeline on startup", country_code=country.code)
            scheduled_pipeline_run(country_id)

    logger.info("Scheduler configured", jobs_count=len(scheduler.get_jobs()))

    try:
        logger.info("Scheduler started, waiting for scheduled runs...")
        scheduler.start()
    except KeyboardInterrupt:
        logger.info("Scheduler stopped by user")
        scheduler.shutdown()
    except Exception as e:
        logger.error("Scheduler error", error=str(e), exc_info=True)
        scheduler.shutdown()
        raise
```

- [ ] **Step 4: Run scheduler tests**

```bash
poetry run pytest tests/test_scheduler_country.py -v --no-cov
```
Expected: all 4 tests PASS.

- [ ] **Step 5: Run full suite**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add src/tenderai_bf/scheduler/schedule.py tests/test_scheduler_country.py
git commit -m "feat(scheduler): per-country APScheduler jobs with get_scheduler_instance and reschedule_country_job"
```

---

## Task 9: Countries API schemas

**Files:**
- Create: `src/tenderai_bf/api/schemas/countries.py`

- [ ] **Step 1: Write failing tests**

Create `tests/api/test_countries_endpoints.py`:

```python
import os
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

os.environ.setdefault("TENDERAI_JWT_SECRET", "test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx")
os.environ.setdefault("TENDERAI_ADMIN_PASSWORD", "test-admin-password-not-real")


def test_country_create_schema_validates_name():
    from tenderai_bf.api.schemas.countries import CountryCreate
    from pydantic import ValidationError
    with pytest.raises(ValidationError):
        CountryCreate(name="", code="BF", locale="fr")


def test_country_create_schema_valid():
    from tenderai_bf.api.schemas.countries import CountryCreate
    c = CountryCreate(name="Burkina Faso", code="BF", locale="fr")
    assert c.code == "BF"


def test_country_update_schema_all_optional():
    from tenderai_bf.api.schemas.countries import CountryUpdate
    u = CountryUpdate()
    assert u.name is None
    assert u.active is None


def test_country_read_schema_from_orm():
    from tenderai_bf.api.schemas.countries import CountryRead
    from datetime import datetime
    obj = CountryRead(id=1, name="BF", code="BF", locale="fr", active=True,
                      created_at=datetime.utcnow(), updated_at=datetime.utcnow())
    assert obj.id == 1
```

- [ ] **Step 2: Run to confirm failure**

```bash
poetry run pytest tests/api/test_countries_endpoints.py::test_country_create_schema_validates_name -v --no-cov
```
Expected: ImportError — schema module doesn't exist.

- [ ] **Step 3: Create api/schemas/countries.py**

Create `src/tenderai_bf/api/schemas/countries.py`:

```python
"""Pydantic schemas for Country and CountrySettings API."""

from datetime import datetime
from typing import Optional
from pydantic import BaseModel, Field


class CountryCreate(BaseModel):
    name: str = Field(min_length=1, max_length=255)
    code: str = Field(min_length=2, max_length=10)
    locale: str = Field(default="fr", min_length=2, max_length=10)


class CountryUpdate(BaseModel):
    name: Optional[str] = Field(None, min_length=1, max_length=255)
    locale: Optional[str] = Field(None, min_length=2, max_length=10)
    active: Optional[bool] = None


class CountryRead(BaseModel):
    id: int
    name: str
    code: str
    locale: str
    active: bool
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}
```

- [ ] **Step 4: Run schema tests**

```bash
poetry run pytest tests/api/test_countries_endpoints.py -k "schema" -v --no-cov
```
Expected: all 4 schema tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/tenderai_bf/api/schemas/countries.py tests/api/test_countries_endpoints.py
git commit -m "feat(api): CountryCreate, CountryRead, CountryUpdate Pydantic schemas"
```

---

## Task 10: Countries API router + register in main.py

**Files:**
- Create: `src/tenderai_bf/api/routers/countries.py`
- Modify: `src/tenderai_bf/api/main.py`
- Modify: `src/tenderai_bf/api/routers/__init__.py` (if it imports routers)

- [ ] **Step 1: Write failing endpoint tests**

Append to `tests/api/test_countries_endpoints.py`:

```python
@pytest.fixture
def client():
    from sqlalchemy import create_engine
    from sqlalchemy.orm import Session
    from fastapi.testclient import TestClient
    from tenderai_bf.db import Base, _engine_registry
    from tenderai_bf.api.main import app

    engine = create_engine("sqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)

    def override_db():
        with Session(engine) as session:
            yield session

    from tenderai_bf.api.dependencies import get_db
    app.dependency_overrides[get_db] = override_db
    yield TestClient(app)
    app.dependency_overrides.clear()


def _auth_headers(client):
    resp = client.post("/api/v1/users/login", json={"username": "admin", "password": "test-admin-password-not-real"})
    token = resp.json().get("access_token", "fake-token")
    return {"Authorization": f"Bearer {token}"}


def test_list_countries_returns_empty_initially(client):
    headers = _auth_headers(client)
    resp = client.get("/api/v1/admin/countries", headers=headers)
    assert resp.status_code == 200
    assert isinstance(resp.json(), list)


def test_create_country_returns_201(client):
    headers = _auth_headers(client)
    resp = client.post(
        "/api/v1/admin/countries",
        json={"name": "Côte d'Ivoire", "code": "CI", "locale": "fr"},
        headers=headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["code"] == "CI"
    assert data["active"] is True


def test_create_duplicate_country_returns_409(client):
    headers = _auth_headers(client)
    client.post("/api/v1/admin/countries", json={"name": "Mali", "code": "ML", "locale": "fr"}, headers=headers)
    resp = client.post("/api/v1/admin/countries", json={"name": "Mali2", "code": "ML", "locale": "fr"}, headers=headers)
    assert resp.status_code == 409


def test_get_country_not_found_returns_404(client):
    headers = _auth_headers(client)
    resp = client.get("/api/v1/admin/countries/999", headers=headers)
    assert resp.status_code == 404


def test_delete_country_soft_deletes(client):
    headers = _auth_headers(client)
    r = client.post("/api/v1/admin/countries", json={"name": "Niger", "code": "NE", "locale": "fr"}, headers=headers)
    country_id = r.json()["id"]
    del_resp = client.delete(f"/api/v1/admin/countries/{country_id}", headers=headers)
    assert del_resp.status_code == 204
    get_resp = client.get(f"/api/v1/admin/countries/{country_id}", headers=headers)
    assert get_resp.json()["active"] is False
```

- [ ] **Step 2: Run to confirm failure**

```bash
poetry run pytest tests/api/test_countries_endpoints.py -k "not schema" -v --no-cov
```
Expected: failures — router not registered.

- [ ] **Step 3: Create api/routers/countries.py**

Create `src/tenderai_bf/api/routers/countries.py`:

```python
"""CRUD endpoints for countries and per-country settings."""

from fastapi import APIRouter, HTTPException, status
from sqlalchemy.exc import IntegrityError

from ...models import Country
from ...country_store import CountryStore, MUTABLE_SECTIONS
from ..dependencies import AuthenticatedUser, DatabaseSession
from ..schemas.countries import CountryCreate, CountryRead, CountryUpdate
from ..schemas.settings import SECTION_SCHEMAS

router = APIRouter()


def _get_country_or_404(country_id: int, db: DatabaseSession) -> Country:
    country = db.query(Country).filter(Country.id == country_id).first()
    if not country:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Country not found")
    return country


@router.get("", response_model=list[CountryRead])
async def list_countries(db: DatabaseSession, user: AuthenticatedUser):
    return db.query(Country).order_by(Country.name).all()


@router.post("", response_model=CountryRead, status_code=status.HTTP_201_CREATED)
async def create_country(body: CountryCreate, db: DatabaseSession, user: AuthenticatedUser):
    country = Country(name=body.name, code=body.code.upper(), locale=body.locale)
    db.add(country)
    try:
        db.flush()
        db.commit()
        db.refresh(country)
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            detail=f"Country with code '{body.code.upper()}' already exists",
        )
    CountryStore.seed_from_global(db, country.id)
    return country


@router.get("/{country_id}", response_model=CountryRead)
async def get_country(country_id: int, db: DatabaseSession, user: AuthenticatedUser):
    return _get_country_or_404(country_id, db)


@router.put("/{country_id}", response_model=CountryRead)
async def update_country(
    country_id: int, body: CountryUpdate, db: DatabaseSession, user: AuthenticatedUser
):
    country = _get_country_or_404(country_id, db)
    if body.name is not None:
        country.name = body.name
    if body.locale is not None:
        country.locale = body.locale
    if body.active is not None:
        country.active = body.active
    db.commit()
    db.refresh(country)
    return country


@router.delete("/{country_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_country(country_id: int, db: DatabaseSession, user: AuthenticatedUser):
    country = _get_country_or_404(country_id, db)
    country.active = False
    db.commit()


@router.get("/{country_id}/settings")
async def get_all_settings(country_id: int, db: DatabaseSession, user: AuthenticatedUser):
    _get_country_or_404(country_id, db)
    return CountryStore.get_all_with_fallback(db, country_id)


@router.get("/{country_id}/settings/{section}")
async def get_section(
    country_id: int, section: str, db: DatabaseSession, user: AuthenticatedUser
):
    if section not in MUTABLE_SECTIONS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=f"Unknown section: {section}")
    _get_country_or_404(country_id, db)
    data = CountryStore.get_section(db, country_id, section)
    if data is None:
        from ...models import AppSettings
        row = db.query(AppSettings).filter(AppSettings.section == section).first()
        data = row.data if row else {}
    return data


@router.put("/{country_id}/settings/{section}")
async def update_section(
    country_id: int,
    section: str,
    body: dict,
    db: DatabaseSession,
    user: AuthenticatedUser,
):
    if section not in MUTABLE_SECTIONS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=f"Unknown section: {section}")
    country = _get_country_or_404(country_id, db)
    schema_cls = SECTION_SCHEMAS.get(section)
    if schema_cls:
        schema_cls(**body)  # raises HTTP 422 on validation failure via FastAPI
    CountryStore.put_section(db, country_id, section, body, updated_by=user.username)
    if section == "scheduler":
        from ...scheduler.schedule import reschedule_country_job
        try:
            reschedule_country_job(country_id, country.code, body)
        except Exception:
            pass  # scheduler may not be running in API-only mode
    return body


@router.post("/{country_id}/run", status_code=status.HTTP_202_ACCEPTED)
async def trigger_run(country_id: int, db: DatabaseSession, user: AuthenticatedUser):
    _get_country_or_404(country_id, db)
    import asyncio
    from ...agents import get_pipeline

    async def _run():
        get_pipeline().run(
            country_id=country_id,
            triggered_by="api",
            triggered_by_user=user.username,
        )

    asyncio.create_task(_run())
    return {"status": "accepted", "country_id": country_id}
```

- [ ] **Step 4: Register router in main.py**

In `src/tenderai_bf/api/main.py`, update the import line:
```python
from .routers import health, runs, sources, reports, admin, users
```
to:
```python
from .routers import health, runs, sources, reports, admin, users, countries
```

After the existing `app.include_router` calls, add:
```python
app.include_router(countries.router, prefix="/api/v1/admin/countries", tags=["Countries"])
```

Also in the `lifespan` function, after the settings seeding block, add BF country seeding:

```python
    # Seed BF country if no countries exist yet
    try:
        from ..db import get_session_factory
        from ..models import Country as CountryModel
        from ..country_store import CountryStore
        SessionLocal = get_session_factory()
        db_session = SessionLocal()
        try:
            if not db_session.query(CountryModel).first():
                bf = CountryModel(name="Burkina Faso", code="BF", locale="fr", active=True)
                db_session.add(bf)
                db_session.commit()
                db_session.refresh(bf)
                CountryStore.seed_from_global(db_session, bf.id)
                logger.info("Seeded Burkina Faso as default country")
        finally:
            db_session.close()
    except Exception as e:
        logger.warning("Could not seed BF country", error=str(e))
```

- [ ] **Step 5: Run endpoint tests**

```bash
poetry run pytest tests/api/test_countries_endpoints.py -v --no-cov
```
Expected: all 9 tests PASS.

- [ ] **Step 6: Run full suite**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```

- [ ] **Step 7: Commit**

```bash
git add src/tenderai_bf/api/routers/countries.py src/tenderai_bf/api/main.py tests/api/test_countries_endpoints.py
git commit -m "feat(api): countries router with CRUD, per-country settings, and run trigger"
```

---

## Task 11: Add country_id filter to runs and sources endpoints

**Files:**
- Modify: `src/tenderai_bf/api/routers/runs.py`
- Modify: `src/tenderai_bf/api/routers/sources.py`

- [ ] **Step 1: Check current list endpoints**

```bash
grep -n "def list\|def get_runs\|async def" src/tenderai_bf/api/routers/runs.py | head -20
grep -n "def list\|def get_sources\|async def" src/tenderai_bf/api/routers/sources.py | head -20
```

- [ ] **Step 2: Update runs.py list endpoint**

In `src/tenderai_bf/api/routers/runs.py`, find the `GET /` list endpoint. Add an optional `country_id` query parameter and apply the filter when provided:

```python
from typing import Optional

@router.get("")
async def list_runs(
    db: DatabaseSession,
    user: AuthenticatedUser,
    country_id: Optional[int] = None,
    limit: int = 50,
    offset: int = 0,
):
    from ...models import Run
    query = db.query(Run)
    if country_id is not None:
        query = query.filter(Run.country_id == country_id)
    return query.order_by(Run.started_at.desc()).offset(offset).limit(limit).all()
```

- [ ] **Step 3: Update sources.py list endpoint**

In `src/tenderai_bf/api/routers/sources.py`, find the `GET /` list endpoint. Add an optional `country_id` query parameter:

```python
from typing import Optional

@router.get("")
async def list_sources(
    db: DatabaseSession,
    user: AuthenticatedUser,
    country_id: Optional[int] = None,
    enabled_only: bool = True,
):
    from ...models import Source
    query = db.query(Source)
    if country_id is not None:
        query = query.filter(Source.country_id == country_id)
    if enabled_only:
        query = query.filter(Source.enabled == True)
    return query.order_by(Source.name).all()
```

- [ ] **Step 4: Verify no test regressions**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/tenderai_bf/api/routers/runs.py src/tenderai_bf/api/routers/sources.py
git commit -m "feat(api): add optional country_id filter to runs and sources list endpoints"
```

---

## Task 12: Frontend CountryContext and CountrySelector

**Files:**
- Create: `frontend/contexts/country-context.tsx`
- Create: `frontend/components/country-selector.tsx`

- [ ] **Step 1: Create country-context.tsx**

Create `frontend/contexts/country-context.tsx`:

```tsx
"use client";

import { createContext, useContext, useState, useEffect, ReactNode } from "react";

export type Country = {
  id: number;
  name: string;
  code: string;
  locale: string;
  active: boolean;
};

type CountryContextValue = {
  countries: Country[];
  selectedCountry: Country | null;
  setSelectedCountry: (c: Country) => void;
  loading: boolean;
};

const CountryContext = createContext<CountryContextValue>({
  countries: [],
  selectedCountry: null,
  setSelectedCountry: () => {},
  loading: true,
});

export function CountryProvider({ children }: { children: ReactNode }) {
  const [countries, setCountries] = useState<Country[]>([]);
  const [selectedCountry, setSelectedCountryState] = useState<Country | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch("/api/proxy/countries")
      .then((r) => r.json())
      .then((data: Country[]) => {
        const active = Array.isArray(data) ? data.filter((c) => c.active) : [];
        setCountries(active);
        const storedId = typeof window !== "undefined"
          ? Number(localStorage.getItem("selectedCountryId"))
          : 0;
        const found = active.find((c) => c.id === storedId) ?? active[0] ?? null;
        setSelectedCountryState(found);
      })
      .catch(() => setCountries([]))
      .finally(() => setLoading(false));
  }, []);

  function setSelectedCountry(c: Country) {
    setSelectedCountryState(c);
    if (typeof window !== "undefined") {
      localStorage.setItem("selectedCountryId", String(c.id));
    }
  }

  return (
    <CountryContext.Provider value={{ countries, selectedCountry, setSelectedCountry, loading }}>
      {children}
    </CountryContext.Provider>
  );
}

export const useCountry = () => useContext(CountryContext);
```

- [ ] **Step 2: Create country-selector.tsx**

Create `frontend/components/country-selector.tsx`:

```tsx
"use client";

import { useCountry } from "@/contexts/country-context";

export function CountrySelector() {
  const { countries, selectedCountry, setSelectedCountry, loading } = useCountry();

  if (loading || countries.length <= 1) return null;

  return (
    <div className="px-2 pb-2">
      <select
        value={selectedCountry?.id ?? ""}
        onChange={(e) => {
          const c = countries.find((c) => c.id === Number(e.target.value));
          if (c) setSelectedCountry(c);
        }}
        className="w-full text-xs bg-slate-800 text-slate-100 border border-slate-600 rounded px-2 py-1.5 focus:outline-none focus:border-slate-400"
        aria-label="Sélectionner un pays"
      >
        {countries.map((c) => (
          <option key={c.id} value={c.id}>
            {c.name}
          </option>
        ))}
      </select>
    </div>
  );
}
```

- [ ] **Step 3: Verify TypeScript compiles**

```bash
cd /home/yulcom/web/tender-ai/frontend && npx tsc --noEmit 2>&1 | head -30
```
Expected: no errors related to new files.

- [ ] **Step 4: Commit**

```bash
git add frontend/contexts/country-context.tsx frontend/components/country-selector.tsx
git commit -m "feat(frontend): CountryContext provider and CountrySelector dropdown"
```

---

## Task 13: Frontend layout wrap + sidebar update

**Files:**
- Modify: `frontend/app/(dashboard)/layout.tsx`
- Modify: `frontend/components/sidebar.tsx`

- [ ] **Step 1: Wrap layout with CountryProvider**

In `frontend/app/(dashboard)/layout.tsx`, add the import and wrap the return:

```tsx
import { CountryProvider } from "@/contexts/country-context";
```

Change the `return` block from:
```tsx
  return (
    <div className="flex min-h-screen">
      <Sidebar role={payload.role} username={payload.sub} />
      <main className="flex-1 p-6 bg-slate-50">{children}</main>
    </div>
  );
```
to:
```tsx
  return (
    <CountryProvider>
      <div className="flex min-h-screen">
        <Sidebar role={payload.role} username={payload.sub} />
        <main className="flex-1 p-6 bg-slate-50">{children}</main>
      </div>
    </CountryProvider>
  );
```

- [ ] **Step 2: Add CountrySelector and /countries link to sidebar**

In `frontend/components/sidebar.tsx`, add the import at the top:
```tsx
import { CountrySelector } from "@/components/country-selector";
```

Add `/countries` to `adminLinks`:
```tsx
const adminLinks = [
  { href: "/users", label: "Utilisateurs" },
  { href: "/countries", label: "Pays" },
];
```

Insert `<CountrySelector />` just before the `<nav>` opening tag inside the `<aside>`:
```tsx
      <div className="p-4 border-b border-slate-700">
        <h1 className="font-bold text-lg">TenderAI BF</h1>
        <p className="text-xs text-slate-400 mt-1">{username}</p>
      </div>
      <CountrySelector />
      <nav className="flex-1 p-2 space-y-1">
```

- [ ] **Step 3: Verify TypeScript compiles**

```bash
cd /home/yulcom/web/tender-ai/frontend && npx tsc --noEmit 2>&1 | head -30
```
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add frontend/app/\(dashboard\)/layout.tsx frontend/components/sidebar.tsx
git commit -m "feat(frontend): wrap dashboard with CountryProvider, add CountrySelector and /countries nav link"
```

---

## Task 14: Frontend /countries page

**Files:**
- Create: `frontend/app/(dashboard)/countries/page.tsx`
- Create: `frontend/app/(dashboard)/countries/new/page.tsx`

- [ ] **Step 1: Create the countries list page**

Create `frontend/app/(dashboard)/countries/page.tsx`:

```tsx
"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";

type Country = { id: number; name: string; code: string; locale: string; active: boolean };

export default function CountriesPage() {
  const [countries, setCountries] = useState<Country[]>([]);
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  useEffect(() => {
    fetch("/api/proxy/countries")
      .then((r) => r.json())
      .then(setCountries)
      .finally(() => setLoading(false));
  }, []);

  async function toggleActive(country: Country) {
    await fetch(`/api/proxy/countries/${country.id}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ active: !country.active }),
    });
    setCountries((prev) =>
      prev.map((c) => (c.id === country.id ? { ...c, active: !c.active } : c))
    );
  }

  if (loading) return <p className="text-slate-500">Chargement...</p>;

  return (
    <div className="max-w-4xl">
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-2xl font-bold text-slate-800">Pays</h1>
        <Link
          href="/countries/new"
          className="bg-blue-600 text-white px-4 py-2 rounded-md text-sm hover:bg-blue-700"
        >
          Ajouter un pays
        </Link>
      </div>

      <div className="bg-white rounded-lg border border-slate-200 overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 border-b border-slate-200">
            <tr>
              <th className="text-left px-4 py-3 font-medium text-slate-600">Nom</th>
              <th className="text-left px-4 py-3 font-medium text-slate-600">Code</th>
              <th className="text-left px-4 py-3 font-medium text-slate-600">Locale</th>
              <th className="text-left px-4 py-3 font-medium text-slate-600">Statut</th>
              <th className="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            {countries.map((c) => (
              <tr key={c.id} className="border-b border-slate-100 hover:bg-slate-50">
                <td className="px-4 py-3 font-medium text-slate-800">{c.name}</td>
                <td className="px-4 py-3 text-slate-600 font-mono">{c.code}</td>
                <td className="px-4 py-3 text-slate-600">{c.locale}</td>
                <td className="px-4 py-3">
                  <span
                    className={`inline-flex px-2 py-0.5 rounded-full text-xs font-medium ${
                      c.active
                        ? "bg-green-100 text-green-700"
                        : "bg-slate-100 text-slate-500"
                    }`}
                  >
                    {c.active ? "Actif" : "Inactif"}
                  </span>
                </td>
                <td className="px-4 py-3 text-right space-x-2">
                  <button
                    onClick={() => toggleActive(c)}
                    className="text-xs text-slate-500 hover:text-slate-700 underline"
                  >
                    {c.active ? "Désactiver" : "Activer"}
                  </button>
                </td>
              </tr>
            ))}
            {countries.length === 0 && (
              <tr>
                <td colSpan={5} className="px-4 py-8 text-center text-slate-400">
                  Aucun pays configuré.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Create the new country form**

Create `frontend/app/(dashboard)/countries/new/page.tsx`:

```tsx
"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";

const TABS = ["Infos de base", "Pipeline & LLM", "Scheduler", "Email", "Prompts", "Classification & RAG"] as const;
type Tab = (typeof TABS)[number];

export default function NewCountryPage() {
  const router = useRouter();
  const [activeTab, setActiveTab] = useState<Tab>("Infos de base");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [basic, setBasic] = useState({ name: "", code: "", locale: "fr" });

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!basic.name || !basic.code) {
      setError("Nom et code ISO sont requis.");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const resp = await fetch("/api/proxy/countries", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(basic),
      });
      if (!resp.ok) {
        const data = await resp.json();
        setError(data.detail ?? "Erreur lors de la création.");
        return;
      }
      router.push("/countries");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="max-w-2xl">
      <h1 className="text-2xl font-bold text-slate-800 mb-6">Nouveau pays</h1>

      <div className="flex gap-1 mb-6 flex-wrap">
        {TABS.map((tab) => (
          <button
            key={tab}
            onClick={() => setActiveTab(tab)}
            className={`px-3 py-1.5 rounded text-sm font-medium transition-colors ${
              activeTab === tab
                ? "bg-blue-600 text-white"
                : "bg-slate-100 text-slate-600 hover:bg-slate-200"
            }`}
          >
            {tab}
          </button>
        ))}
      </div>

      <form onSubmit={handleSubmit} className="bg-white rounded-lg border border-slate-200 p-6">
        {activeTab === "Infos de base" && (
          <div className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-slate-700 mb-1">Nom du pays</label>
              <input
                type="text"
                value={basic.name}
                onChange={(e) => setBasic({ ...basic, name: e.target.value })}
                placeholder="ex. Côte d'Ivoire"
                className="w-full border border-slate-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:border-blue-500"
                required
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-slate-700 mb-1">Code ISO 3166-1 alpha-2</label>
              <input
                type="text"
                value={basic.code}
                onChange={(e) => setBasic({ ...basic, code: e.target.value.toUpperCase() })}
                placeholder="ex. CI"
                maxLength={2}
                className="w-full border border-slate-300 rounded-md px-3 py-2 text-sm font-mono focus:outline-none focus:border-blue-500"
                required
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-slate-700 mb-1">Locale</label>
              <select
                value={basic.locale}
                onChange={(e) => setBasic({ ...basic, locale: e.target.value })}
                className="w-full border border-slate-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:border-blue-500"
              >
                <option value="fr">Français (fr)</option>
                <option value="en">Anglais (en)</option>
              </select>
            </div>
          </div>
        )}

        {activeTab !== "Infos de base" && (
          <p className="text-sm text-slate-500 py-4">
            La configuration de cet onglet sera pré-remplie depuis les paramètres globaux à la création.
            Vous pourrez la modifier depuis la page Paramètres après avoir sélectionné ce pays.
          </p>
        )}

        {error && <p className="mt-4 text-sm text-red-600">{error}</p>}

        <div className="mt-6 flex gap-3">
          <button
            type="submit"
            disabled={saving}
            className="bg-blue-600 text-white px-4 py-2 rounded-md text-sm hover:bg-blue-700 disabled:opacity-50"
          >
            {saving ? "Création..." : "Créer le pays"}
          </button>
          <button
            type="button"
            onClick={() => router.push("/countries")}
            className="px-4 py-2 rounded-md text-sm text-slate-600 hover:bg-slate-100"
          >
            Annuler
          </button>
        </div>
      </form>
    </div>
  );
}
```

- [ ] **Step 3: Verify TypeScript compiles**

```bash
cd /home/yulcom/web/tender-ai/frontend && npx tsc --noEmit 2>&1 | head -30
```
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add "frontend/app/(dashboard)/countries/"
git commit -m "feat(frontend): /countries list page and /countries/new creation form"
```

---

## Task 15: Frontend proxy routes for countries

**Files:**
- Create: `frontend/app/api/proxy/countries/route.ts`
- Create: `frontend/app/api/proxy/countries/[id]/route.ts`
- Create: `frontend/app/api/proxy/countries/[id]/settings/route.ts`
- Create: `frontend/app/api/proxy/countries/[id]/settings/[section]/route.ts`
- Create: `frontend/app/api/proxy/countries/[id]/run/route.ts`

- [ ] **Step 1: Create the collection proxy (GET list, POST create)**

Create `frontend/app/api/proxy/countries/route.ts`:

```ts
import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function GET() {
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/countries`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}

export async function POST(request: NextRequest) {
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const body = await request.json();
  const res = await fetch(`${API_URL}/api/v1/admin/countries`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Step 2: Create the item proxy (GET one, PUT, DELETE)**

Create `frontend/app/api/proxy/countries/[id]/route.ts`:

```ts
import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/countries/${id}`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}

export async function PUT(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const body = await request.json();
  const res = await fetch(`${API_URL}/api/v1/admin/countries/${id}`, {
    method: "PUT",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}

export async function DELETE(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/countries/${id}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${token}` },
  });
  if (res.status === 204) return new NextResponse(null, { status: 204 });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Step 3: Create the settings proxy (GET all, GET section, PUT section)**

Create `frontend/app/api/proxy/countries/[id]/settings/route.ts`:

```ts
import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/countries/${id}/settings`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

Create `frontend/app/api/proxy/countries/[id]/settings/[section]/route.ts`:

```ts
import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string; section: string }> }
) {
  const { id, section } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/countries/${id}/settings/${section}`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}

export async function PUT(
  request: NextRequest,
  { params }: { params: Promise<{ id: string; section: string }> }
) {
  const { id, section } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const body = await request.json();
  const res = await fetch(`${API_URL}/api/v1/admin/countries/${id}/settings/${section}`, {
    method: "PUT",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Step 4: Create the run trigger proxy**

Create `frontend/app/api/proxy/countries/[id]/run/route.ts`:

```ts
import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function POST(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/countries/${id}/run`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Step 5: Verify TypeScript compiles**

```bash
cd /home/yulcom/web/tender-ai/frontend && npx tsc --noEmit 2>&1 | head -30
```
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add frontend/app/api/proxy/countries/
git commit -m "feat(frontend): Next.js proxy routes for countries API"
```

---

## Task 16: Update settings page and run/sources pages to use country context

**Files:**
- Modify: `frontend/app/(dashboard)/settings/page.tsx`
- Modify: `frontend/app/(dashboard)/runs/page.tsx` (if it fetches via proxy)
- Modify: `frontend/app/(dashboard)/sources/page.tsx` (if it fetches via proxy)

- [ ] **Step 1: Check current data-fetching in settings, runs, sources pages**

```bash
grep -n "proxy/settings\|proxy/runs\|proxy/sources\|fetch" \
  "frontend/app/(dashboard)/settings/page.tsx" \
  "frontend/app/(dashboard)/runs/page.tsx" \
  "frontend/app/(dashboard)/sources/page.tsx" 2>/dev/null | head -30
```

- [ ] **Step 2: Update settings page to load per-country settings**

In `frontend/app/(dashboard)/settings/page.tsx`:

1. Add `"use client"` directive if not already present (needed for hooks).
2. Import `useCountry`:
```tsx
import { useCountry } from "@/contexts/country-context";
```
3. Inside the component, get the selected country:
```tsx
const { selectedCountry } = useCountry();
```
4. Update the settings fetch URL from:
```tsx
fetch("/api/proxy/settings")
```
to:
```tsx
fetch(selectedCountry ? `/api/proxy/countries/${selectedCountry.id}/settings` : "/api/proxy/settings")
```
5. Add `selectedCountry?.id` to the `useEffect` dependency array so settings reload on country change.
6. Update the save (PUT) endpoint from:
```tsx
fetch(`/api/proxy/settings/${section}`, { method: "PUT", ... })
```
to:
```tsx
fetch(
  selectedCountry
    ? `/api/proxy/countries/${selectedCountry.id}/settings/${section}`
    : `/api/proxy/settings/${section}`,
  { method: "PUT", ... }
)
```

- [ ] **Step 3: Update runs page to pass country_id**

In `frontend/app/(dashboard)/runs/page.tsx`, add:
```tsx
import { useCountry } from "@/contexts/country-context";
// inside component:
const { selectedCountry } = useCountry();
```
Update the runs fetch URL to include `country_id`:
```tsx
// Replace:
fetch("/api/proxy/runs")
// With:
fetch(selectedCountry ? `/api/proxy/runs?country_id=${selectedCountry.id}` : "/api/proxy/runs")
```
Add `selectedCountry?.id` to the `useEffect` dependency array.

Also update `frontend/app/api/proxy/runs/route.ts` to forward the `country_id` query param to the backend:
```ts
export async function GET(request: NextRequest) {
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const countryId = request.nextUrl.searchParams.get("country_id");
  const url = new URL(`${API_URL}/api/v1/runs`);
  if (countryId) url.searchParams.set("country_id", countryId);

  const res = await fetch(url.toString(), {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Step 4: Update sources page to pass country_id**

In `frontend/app/(dashboard)/sources/page.tsx`, follow the same pattern as runs:
```tsx
import { useCountry } from "@/contexts/country-context";
const { selectedCountry } = useCountry();
// fetch:
fetch(selectedCountry ? `/api/proxy/sources?country_id=${selectedCountry.id}` : "/api/proxy/sources")
```

Update `frontend/app/api/proxy/sources/route.ts` GET handler:
```ts
export async function GET(request: NextRequest) {
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const countryId = request.nextUrl.searchParams.get("country_id");
  const enabledOnly = request.nextUrl.searchParams.get("enabled_only") ?? "false";
  const url = new URL(`${API_URL}/api/v1/sources`);
  url.searchParams.set("enabled_only", enabledOnly);
  if (countryId) url.searchParams.set("country_id", countryId);

  const res = await fetch(url.toString(), {
    headers: { Authorization: `Bearer ${token}` },
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Step 5: Verify TypeScript compiles with no errors**

```bash
cd /home/yulcom/web/tender-ai/frontend && npx tsc --noEmit 2>&1 | head -30
```

- [ ] **Step 6: Run final backend test suite**

```bash
cd /home/yulcom/web/tender-ai && poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add "frontend/app/(dashboard)/settings/page.tsx" \
        "frontend/app/(dashboard)/runs/page.tsx" \
        "frontend/app/(dashboard)/sources/page.tsx" \
        frontend/app/api/proxy/runs/route.ts \
        frontend/app/api/proxy/sources/route.ts
git commit -m "feat(frontend): settings, runs, sources pages filter by selected country"
```

---

## Post-Implementation Checklist

- [ ] `make migrate` runs cleanly on a clean DB
- [ ] `POST /api/v1/admin/countries` creates a country and seeds its settings from global AppSettings
- [ ] `GET /api/v1/runs?country_id=1` returns only runs for country 1
- [ ] `pipeline.run(country_id=1)` creates a `Run` record with `country_id=1`
- [ ] The scheduler starts with one job per active country
- [ ] `PUT /api/v1/admin/countries/1/settings/scheduler` hot-reschedules the job
- [ ] Country selector is visible in the sidebar when more than one country exists
- [ ] `/countries` page lists countries and the new form creates one
- [ ] Settings page loads per-country config when a country is selected
- [ ] All existing tests pass: `poetry run pytest tests/ --no-cov -m "not slow and not integration"`
- [ ] Update `IMPROVEMENTS.md`: mark item #1 as `done`
