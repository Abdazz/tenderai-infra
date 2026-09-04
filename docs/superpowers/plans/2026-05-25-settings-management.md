# Settings Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persister tous les paramètres opérationnels en base de données, seeder depuis `settings.yaml` au premier boot, et remplacer la page Settings read-only par une UI complète avec formulaires par section.

**Architecture:** Table `app_settings(section PK, data JSON)` — une ligne par section de config. Le singleton `Settings` en mémoire lit la DB au démarrage et est mis à jour en place après chaque `PUT /settings/{section}`. Le frontend utilise des proxy routes Next.js vers l'API FastAPI (même pattern que `/api/proxy/sources/`).

**Tech Stack:** Python/SQLAlchemy/FastAPI (backend), Next.js 14 App Router + Tailwind (frontend), Alembic (migrations), pytest/SQLite (tests)

**Spec:** `docs/superpowers/specs/2026-05-25-settings-management-design.md`

---

## Carte des fichiers

### Créer
- `src/tenderai_bf/settings_store.py` — lecture/écriture `app_settings` en DB + seeding
- `src/tenderai_bf/api/schemas/__init__.py` — package vide
- `src/tenderai_bf/api/schemas/settings.py` — schémas Pydantic de validation par section
- `alembic/versions/0002_add_app_settings.py` — migration table `app_settings`
- `tests/test_settings_store.py` — tests SettingsStore
- `tests/api/test_settings_endpoints.py` — tests API endpoints
- `frontend/app/api/proxy/settings/route.ts` — proxy GET toutes sections
- `frontend/app/api/proxy/settings/[section]/route.ts` — proxy GET + PUT une section
- `frontend/components/settings/readonly-section.tsx` — affichage read-only (env vars)
- `frontend/components/settings/prompt-editor-dialog.tsx` — Dialog textarea pour prompts
- `frontend/components/settings/pipeline-section.tsx`
- `frontend/components/settings/scheduler-section.tsx`
- `frontend/components/settings/llm-section.tsx`
- `frontend/components/settings/email-section.tsx`
- `frontend/components/settings/rag-section.tsx`
- `frontend/components/settings/classification-section.tsx`
- `frontend/components/settings/prompts-section.tsx`
- `frontend/app/(dashboard)/settings/settings-client.tsx` — tabs + orchestration

### Modifier
- `src/tenderai_bf/models.py` — ajouter `AppSettings` ORM model
- `src/tenderai_bf/config.py` — ajouter `apply_db_override()` + `reload_settings_from_db()`
- `src/tenderai_bf/api/routers/admin.py` — remplacer `GET /settings`, ajouter `GET/PUT /settings/{section}`, `POST /settings/seed`
- `src/tenderai_bf/api/main.py` — appeler le seeding dans le lifespan
- `src/tenderai_bf/scheduler/schedule.py` — lire les settings DB au début de chaque run
- `frontend/app/(dashboard)/settings/page.tsx` — Server Component qui charge toutes sections

---

## Task 1 : Migration Alembic + modèle AppSettings

**Files:**
- Create: `alembic/versions/0002_add_app_settings.py`
- Modify: `src/tenderai_bf/models.py`

- [ ] **Étape 1 — Écrire le test de migration**

```python
# tests/test_settings_store.py
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


def test_app_settings_table_has_expected_columns(db):
    from tenderai_bf.models import AppSettings
    engine = db.get_bind()
    inspector = inspect(engine)
    cols = {c["name"] for c in inspector.get_columns("app_settings")}
    assert cols == {"section", "data", "updated_at", "updated_by"}


def test_app_settings_can_insert_and_retrieve(db):
    from tenderai_bf.models import AppSettings
    row = AppSettings(section="pipeline", data={"min_relevance_score": 0.7}, updated_by="test")
    db.add(row)
    db.commit()
    found = db.query(AppSettings).filter_by(section="pipeline").first()
    assert found is not None
    assert found.data["min_relevance_score"] == 0.7
```

- [ ] **Étape 2 — Vérifier que le test échoue**

```bash
cd /home/yulcom/web/tender-ai
poetry run pytest tests/test_settings_store.py -v --no-cov
```

Attendu : `ImportError` ou `FAILED` — `AppSettings` n'existe pas encore.

- [ ] **Étape 3 — Ajouter le modèle `AppSettings` dans `models.py`**

Dans `src/tenderai_bf/models.py`, après les imports existants, ajouter à la fin du fichier :

```python
class AppSettings(Base):
    """Mutable operational settings persisted in DB."""

    __tablename__ = "app_settings"

    section = Column(String(64), primary_key=True)
    data = Column(JSON, nullable=False)
    updated_at = Column(DateTime, nullable=False, default=func.now(), onupdate=func.now())
    updated_by = Column(Text, nullable=True)

    def __repr__(self) -> str:
        return f"<AppSettings(section='{self.section}')>"
```

- [ ] **Étape 4 — Créer la migration Alembic**

```python
# alembic/versions/0002_add_app_settings.py
"""add_app_settings

Revision ID: 0002
Revises: 0001
Create Date: 2026-05-25
"""
import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "app_settings",
        sa.Column("section", sa.String(64), primary_key=True),
        sa.Column("data", sa.JSON(), nullable=False),
        sa.Column(
            "updated_at",
            sa.DateTime(),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column("updated_by", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_table("app_settings")
```

- [ ] **Étape 5 — Vérifier que les tests passent**

```bash
poetry run pytest tests/test_settings_store.py::test_app_settings_table_has_expected_columns tests/test_settings_store.py::test_app_settings_can_insert_and_retrieve -v --no-cov
```

Attendu : 2 PASSED

- [ ] **Étape 6 — Commit**

```bash
git add alembic/versions/0002_add_app_settings.py src/tenderai_bf/models.py tests/test_settings_store.py
git commit -m "feat: add AppSettings ORM model and migration"
```

---

## Task 2 : SettingsStore

**Files:**
- Create: `src/tenderai_bf/settings_store.py`
- Modify: `tests/test_settings_store.py`

- [ ] **Étape 1 — Écrire les tests SettingsStore**

Ajouter à la suite de `tests/test_settings_store.py` :

```python
def test_get_section_returns_none_when_absent(db):
    from tenderai_bf.settings_store import SettingsStore
    assert SettingsStore.get_section(db, "pipeline") is None


def test_put_section_inserts_new_row(db):
    from tenderai_bf.settings_store import SettingsStore
    SettingsStore.put_section(db, "pipeline", {"min_relevance_score": 0.8}, updated_by="admin")
    result = SettingsStore.get_section(db, "pipeline")
    assert result == {"min_relevance_score": 0.8}


def test_put_section_updates_existing_row(db):
    from tenderai_bf.settings_store import SettingsStore
    SettingsStore.put_section(db, "pipeline", {"min_relevance_score": 0.7}, updated_by="admin")
    SettingsStore.put_section(db, "pipeline", {"min_relevance_score": 0.9}, updated_by="admin")
    result = SettingsStore.get_section(db, "pipeline")
    assert result["min_relevance_score"] == 0.9


def test_get_all_returns_all_sections(db):
    from tenderai_bf.settings_store import SettingsStore
    SettingsStore.put_section(db, "pipeline", {"x": 1}, updated_by="admin")
    SettingsStore.put_section(db, "llm", {"provider": "groq"}, updated_by="admin")
    result = SettingsStore.get_all(db)
    assert "pipeline" in result
    assert "llm" in result
    assert result["pipeline"]["x"] == 1


def test_seed_from_settings_inserts_all_sections(db):
    from tenderai_bf.settings_store import SettingsStore
    seeded = SettingsStore.seed_from_settings(db)
    assert len(seeded) == 7
    assert "pipeline" in seeded
    assert "scheduler" in seeded
    assert "llm" in seeded
    assert "email" in seeded
    assert "rag" in seeded
    assert "classification" in seeded
    assert "prompts" in seeded


def test_seed_from_settings_is_idempotent(db):
    from tenderai_bf.settings_store import SettingsStore
    seeded_first = SettingsStore.seed_from_settings(db)
    seeded_second = SettingsStore.seed_from_settings(db)
    assert len(seeded_first) == 7
    assert len(seeded_second) == 0  # nothing inserted on second call
```

- [ ] **Étape 2 — Vérifier que les tests échouent**

```bash
poetry run pytest tests/test_settings_store.py -v --no-cov
```

Attendu : `ImportError: cannot import name 'SettingsStore'`

- [ ] **Étape 3 — Implémenter `settings_store.py`**

```python
# src/tenderai_bf/settings_store.py
"""DB-backed settings store. One row per section in app_settings."""

from typing import Optional
from sqlalchemy.orm import Session

from .models import AppSettings

MUTABLE_SECTIONS = frozenset(
    {"pipeline", "scheduler", "llm", "email", "rag", "classification", "prompts"}
)


class SettingsStore:

    @staticmethod
    def get_section(db: Session, section: str) -> Optional[dict]:
        row = db.query(AppSettings).filter(AppSettings.section == section).first()
        return row.data if row else None

    @staticmethod
    def put_section(
        db: Session, section: str, data: dict, updated_by: str = "system"
    ) -> None:
        row = db.query(AppSettings).filter(AppSettings.section == section).first()
        if row:
            row.data = data
            row.updated_by = updated_by
        else:
            db.add(AppSettings(section=section, data=data, updated_by=updated_by))
        db.commit()

    @staticmethod
    def get_all(db: Session) -> dict[str, dict]:
        rows = db.query(AppSettings).all()
        return {row.section: row.data for row in rows}

    @staticmethod
    def seed_from_settings(db: Session) -> list[str]:
        """Seed DB from the current in-memory Settings singleton.

        Inserts only sections that don't yet exist. Idempotent.
        Returns list of section names that were inserted.
        """
        from .config import settings as s

        sections_data: dict[str, dict] = {
            "pipeline": {
                "max_items_per_run": s.processing.max_items_per_run,
                "min_relevance_score": s.processing.min_relevance_score,
                "deduplication_threshold": s.processing.deduplication_threshold,
                "deduplication_method": s.processing.deduplication_method,
                "use_llm_classification": s.processing.use_llm_classification,
                "pdf_timeout": s.processing.pdf_timeout,
                "max_file_size_mb": s.processing.max_file_size_mb,
            },
            "scheduler": {
                "cron_schedule": s.scheduler.cron_schedule,
                "timezone": s.scheduler.timezone,
                "enabled": s.scheduler.enabled,
                "max_concurrent_runs": s.scheduler.max_concurrent_runs,
                "run_on_startup": s.scheduler.run_on_startup,
            },
            "llm": {
                "provider": s.llm.provider,
                "groq_model": s.llm.groq_model,
                "openai_model": s.llm.openai_model,
                "ollama_model": s.llm.ollama_model,
                "ollama_base_url": s.llm.ollama_base_url,
                "temperature": s.llm.temperature,
                "max_tokens": s.llm.max_tokens,
                "timeout": s.llm.timeout,
            },
            "email": {
                "from_address": s.email.from_address,
                "from_name": s.email.from_name,
                "to_address": s.email.to_address,
                "reply_to": s.email.reply_to,
                "subject_prefix": s.email.subject_prefix,
                "signature": s.email.signature,
            },
            "rag": {
                "enabled": s.rag.enabled,
                "chunk_size": s.rag.chunk_size,
                "chunk_overlap": s.rag.chunk_overlap,
                "top_k_results": s.rag.top_k_results,
                "embedding_model": s.rag.embedding_model,
                "vector_search_query": s.rag.chroma.vector_search_query,
            },
            "classification": {
                "relevant_keywords": s.classification.relevant_keywords,
            },
            "prompts": s.prompts,
        }

        seeded: list[str] = []
        for section, data in sections_data.items():
            exists = (
                db.query(AppSettings)
                .filter(AppSettings.section == section)
                .first()
            )
            if exists:
                continue
            db.add(AppSettings(section=section, data=data, updated_by="seed"))
            seeded.append(section)
        db.commit()
        return seeded
```

- [ ] **Étape 4 — Vérifier que les tests passent**

```bash
poetry run pytest tests/test_settings_store.py -v --no-cov
```

Attendu : tous PASSED

- [ ] **Étape 5 — Commit**

```bash
git add src/tenderai_bf/settings_store.py tests/test_settings_store.py
git commit -m "feat: add SettingsStore with get/put/seed_from_settings"
```

---

## Task 3 : Settings.apply_db_override + reload_settings_from_db

**Files:**
- Modify: `src/tenderai_bf/config.py`
- Modify: `tests/test_settings_store.py`

- [ ] **Étape 1 — Écrire le test de reload**

Ajouter à `tests/test_settings_store.py` :

```python
def test_reload_settings_from_db_applies_overrides(db):
    from tenderai_bf.settings_store import SettingsStore
    from tenderai_bf.config import settings, reload_settings_from_db

    original = settings.processing.min_relevance_score
    new_score = round(original + 0.1, 2) if original < 0.9 else 0.5

    SettingsStore.put_section(
        db, "pipeline",
        {
            "max_items_per_run": 100,
            "min_relevance_score": new_score,
            "deduplication_threshold": 0.75,
            "deduplication_method": "hash_similarity",
            "use_llm_classification": True,
            "pdf_timeout": 120,
            "max_file_size_mb": 50,
        },
        updated_by="test",
    )
    reload_settings_from_db(db)
    assert settings.processing.min_relevance_score == new_score
```

- [ ] **Étape 2 — Vérifier que le test échoue**

```bash
poetry run pytest tests/test_settings_store.py::test_reload_settings_from_db_applies_overrides -v --no-cov
```

Attendu : `ImportError: cannot import name 'reload_settings_from_db'`

- [ ] **Étape 3 — Ajouter `apply_db_override` à la classe `Settings` et `reload_settings_from_db` en module**

Dans `src/tenderai_bf/config.py`, ajouter à la fin de la classe `Settings` (juste avant `settings = Settings()`) :

```python
    def apply_db_override(self, section: str, data: dict) -> None:
        """Update in-memory settings for a section from a DB data dict."""
        if section == "pipeline":
            for key, value in data.items():
                if hasattr(self.processing, key):
                    setattr(self.processing, key, value)
        elif section == "scheduler":
            for key, value in data.items():
                if hasattr(self.scheduler, key):
                    setattr(self.scheduler, key, value)
        elif section == "llm":
            for key, value in data.items():
                if hasattr(self.llm, key):
                    setattr(self.llm, key, value)
        elif section == "email":
            for key, value in data.items():
                if hasattr(self.email, key):
                    setattr(self.email, key, value)
        elif section == "rag":
            for key, value in data.items():
                if key == "vector_search_query":
                    self.rag.chroma.vector_search_query = value
                elif hasattr(self.rag, key):
                    setattr(self.rag, key, value)
        elif section == "classification":
            if "relevant_keywords" in data:
                self.classification.relevant_keywords = data["relevant_keywords"]
        elif section == "prompts":
            self.prompts = data
```

Puis juste avant la ligne `settings = Settings()` à la fin du fichier, ajouter :

```python
def reload_settings_from_db(db) -> None:
    """Refresh the global settings singleton from DB. Call after startup seeding."""
    from .settings_store import SettingsStore
    all_sections = SettingsStore.get_all(db)
    for section, data in all_sections.items():
        settings.apply_db_override(section, data)
```

- [ ] **Étape 4 — Vérifier que les tests passent**

```bash
poetry run pytest tests/test_settings_store.py -v --no-cov
```

Attendu : tous PASSED

- [ ] **Étape 5 — Vérifier que la suite de tests existante ne régresse pas**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```

Attendu : tous PASSED (ignorer warnings éventuels)

- [ ] **Étape 6 — Commit**

```bash
git add src/tenderai_bf/config.py tests/test_settings_store.py
git commit -m "feat: add Settings.apply_db_override and reload_settings_from_db"
```

---

## Task 4 : Schémas Pydantic par section + dossier schemas

**Files:**
- Create: `src/tenderai_bf/api/schemas/__init__.py`
- Create: `src/tenderai_bf/api/schemas/settings.py`

- [ ] **Étape 1 — Créer le package `schemas`**

```python
# src/tenderai_bf/api/schemas/__init__.py
```

(fichier vide)

- [ ] **Étape 2 — Créer `settings.py`**

```python
# src/tenderai_bf/api/schemas/settings.py
"""Pydantic validation schemas for settings sections."""

from typing import Any, Dict, List, Optional
from pydantic import BaseModel, Field

DEDUP_METHODS = {"hash_only", "similarity_only", "hash_similarity", "llm_only", "hybrid"}
LLM_PROVIDERS = {"groq", "openai", "ollama"}


class PipelineSettingsSchema(BaseModel):
    max_items_per_run: int = Field(ge=1, le=10000)
    min_relevance_score: float = Field(ge=0.0, le=1.0)
    deduplication_threshold: float = Field(ge=0.0, le=1.0)
    deduplication_method: str
    use_llm_classification: bool
    pdf_timeout: int = Field(ge=10)
    max_file_size_mb: int = Field(ge=1)

    def model_post_init(self, __context: Any) -> None:
        if self.deduplication_method not in DEDUP_METHODS:
            raise ValueError(
                f"deduplication_method must be one of {DEDUP_METHODS}"
            )


class SchedulerSettingsSchema(BaseModel):
    cron_schedule: str
    timezone: str
    enabled: bool
    max_concurrent_runs: int = Field(ge=1)
    run_on_startup: bool

    def model_post_init(self, __context: Any) -> None:
        parts = self.cron_schedule.strip().split()
        if len(parts) != 5:
            raise ValueError("cron_schedule must have exactly 5 fields (min hr dom mon dow)")


class LLMSettingsSchema(BaseModel):
    provider: str
    groq_model: str
    openai_model: str
    ollama_model: str
    ollama_base_url: str
    temperature: float = Field(ge=0.0, le=2.0)
    max_tokens: int = Field(ge=100)
    timeout: int = Field(ge=10)

    def model_post_init(self, __context: Any) -> None:
        if self.provider not in LLM_PROVIDERS:
            raise ValueError(f"provider must be one of {LLM_PROVIDERS}")


class EmailSettingsSchema(BaseModel):
    from_address: str
    from_name: str
    to_address: str
    reply_to: Optional[str] = None
    subject_prefix: str
    signature: str


class RAGSettingsSchema(BaseModel):
    enabled: bool
    chunk_size: int = Field(ge=64)
    chunk_overlap: int = Field(ge=0)
    top_k_results: int = Field(ge=1, le=100)
    embedding_model: str
    vector_search_query: str


class PromptPair(BaseModel):
    system: str
    user_template: str


class PromptsSettingsSchema(BaseModel):
    extraction: PromptPair
    classification: PromptPair
    summarization: PromptPair
    deduplication: PromptPair


class ClassificationSettingsSchema(BaseModel):
    relevant_keywords: Dict[str, List[str]]


SECTION_SCHEMAS: Dict[str, type] = {
    "pipeline": PipelineSettingsSchema,
    "scheduler": SchedulerSettingsSchema,
    "llm": LLMSettingsSchema,
    "email": EmailSettingsSchema,
    "rag": RAGSettingsSchema,
    "classification": ClassificationSettingsSchema,
    "prompts": PromptsSettingsSchema,
}
```

- [ ] **Étape 3 — Vérifier que les schémas s'importent sans erreur**

```bash
poetry run python -c "from tenderai_bf.api.schemas.settings import SECTION_SCHEMAS; print(list(SECTION_SCHEMAS.keys()))"
```

Attendu : `['pipeline', 'scheduler', 'llm', 'email', 'rag', 'classification', 'prompts']`

- [ ] **Étape 4 — Commit**

```bash
git add src/tenderai_bf/api/schemas/__init__.py src/tenderai_bf/api/schemas/settings.py
git commit -m "feat: add Pydantic validation schemas for settings sections"
```

---

## Task 5 : Endpoints API GET / PUT / seed

**Files:**
- Modify: `src/tenderai_bf/api/routers/admin.py`
- Create: `tests/api/test_settings_endpoints.py`

- [ ] **Étape 0 — Créer le package `tests/api/`**

```bash
mkdir -p /home/yulcom/web/tender-ai/tests/api
touch /home/yulcom/web/tender-ai/tests/api/__init__.py
```

- [ ] **Étape 1 — Écrire les tests API**

```python
# tests/api/test_settings_endpoints.py
import os
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

os.environ.setdefault("TENDERAI_JWT_SECRET", "test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx")
os.environ.setdefault("TENDERAI_ADMIN_PASSWORD", "test-admin-password-not-real")

from tenderai_bf.db import Base, get_db
from tenderai_bf.api.main import app


@pytest.fixture
def test_db():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    with Session(engine) as session:
        yield session, engine


@pytest.fixture
def client(test_db):
    session, engine = test_db

    def override_get_db():
        yield session

    app.dependency_overrides[get_db] = override_get_db
    yield TestClient(app)
    app.dependency_overrides.clear()


def _auth_headers(client: TestClient) -> dict:
    """Create a test admin JWT directly."""
    from tenderai_bf.api.dependencies import create_access_token
    token = create_access_token({"sub": "testadmin", "role": "admin"})
    return {"Authorization": f"Bearer {token}"}


def test_get_all_settings_returns_sections(client):
    headers = _auth_headers(client)
    res = client.get("/api/v1/admin/settings", headers=headers)
    assert res.status_code == 200
    body = res.json()
    assert "sections" in body
    assert "readonly" in body


def test_get_section_returns_404_when_absent(client):
    headers = _auth_headers(client)
    res = client.get("/api/v1/admin/settings/pipeline", headers=headers)
    assert res.status_code == 404


def test_put_section_validates_and_saves(client, test_db):
    session, _ = test_db
    headers = _auth_headers(client)
    payload = {
        "max_items_per_run": 200,
        "min_relevance_score": 0.6,
        "deduplication_threshold": 0.8,
        "deduplication_method": "hash_similarity",
        "use_llm_classification": True,
        "pdf_timeout": 60,
        "max_file_size_mb": 100,
    }
    res = client.put("/api/v1/admin/settings/pipeline", json=payload, headers=headers)
    assert res.status_code == 200

    from tenderai_bf.settings_store import SettingsStore
    saved = SettingsStore.get_section(session, "pipeline")
    assert saved["min_relevance_score"] == 0.6
    assert saved["max_items_per_run"] == 200


def test_put_section_rejects_invalid_payload(client):
    headers = _auth_headers(client)
    payload = {"min_relevance_score": 99.0}  # > 1.0, invalid
    res = client.put("/api/v1/admin/settings/pipeline", json=payload, headers=headers)
    assert res.status_code == 422


def test_put_unknown_section_returns_400(client):
    headers = _auth_headers(client)
    res = client.put("/api/v1/admin/settings/nonexistent", json={}, headers=headers)
    assert res.status_code == 400


def test_seed_endpoint_inserts_sections(client, test_db):
    session, _ = test_db
    headers = _auth_headers(client)
    res = client.post("/api/v1/admin/settings/seed", headers=headers)
    assert res.status_code == 200
    body = res.json()
    assert "seeded" in body
    assert len(body["seeded"]) == 7


def test_get_settings_requires_auth(client):
    res = client.get("/api/v1/admin/settings")
    assert res.status_code == 401
```

- [ ] **Étape 2 — Vérifier que les tests échouent**

```bash
poetry run pytest tests/api/test_settings_endpoints.py -v --no-cov
```

Attendu : plusieurs FAILED (endpoints non implémentés)

- [ ] **Étape 3 — Remplacer les endpoints settings dans `admin.py`**

Dans `src/tenderai_bf/api/routers/admin.py` :
1. Ajouter `Body` à la ligne d'import fastapi existante : `from fastapi import APIRouter, Body, Depends, HTTPException, status`
2. Remplacer la fonction `get_settings_info` ET `reload_config` par les nouveaux endpoints ci-dessous. Garder tout le reste (login, me, change-password, test-email, clear-cache) intact.

Supprimer ces deux fonctions :
```python
@router.get("/settings")
async def get_settings_info(user: AuthenticatedUser):
    ...

@router.post("/reload-config")
async def reload_config(user: AuthenticatedUser):
    ...
```

Les remplacer par :

```python
@router.get("/settings")
async def get_all_settings(user: AuthenticatedUser, db: DatabaseSession):
    """Get all mutable settings sections from DB + read-only env-var sections."""
    from ...settings_store import SettingsStore
    mutable = SettingsStore.get_all(db)
    readonly = {
        "database": {"url": "***"},
        "minio": {
            "endpoint": settings.minio.endpoint,
            "bucket_name": settings.minio.bucket_name,
            "credentials": "***",
        },
        "smtp": {
            "host": settings.smtp.host,
            "port": settings.smtp.port,
            "credentials": "***",
        },
        "security": {
            "admin_username": settings.security.admin_username,
            "jwt_secret": "***",
            "admin_password": "***",
        },
    }
    return {"sections": mutable, "readonly": readonly}


@router.get("/settings/{section}")
async def get_section_settings(section: str, user: AuthenticatedUser, db: DatabaseSession):
    """Get a single mutable settings section from DB."""
    from ...settings_store import SettingsStore, MUTABLE_SECTIONS
    if section not in MUTABLE_SECTIONS:
        raise HTTPException(status_code=400, detail=f"Unknown section '{section}'")
    data = SettingsStore.get_section(db, section)
    if data is None:
        raise HTTPException(status_code=404, detail=f"Section '{section}' not found in DB — run /seed first")
    return data


@router.put("/settings/{section}")
async def update_section_settings(
    section: str,
    user: AuthenticatedUser,
    db: DatabaseSession,
    payload: dict = Body(...),
):
    """Validate and persist a settings section, then reload in-memory config."""
    from ...settings_store import SettingsStore, MUTABLE_SECTIONS
    from ...api.schemas.settings import SECTION_SCHEMAS
    from ...config import reload_settings_from_db

    if section not in MUTABLE_SECTIONS:
        raise HTTPException(status_code=400, detail=f"Unknown section '{section}'")

    schema_cls = SECTION_SCHEMAS[section]
    try:
        validated = schema_cls(**payload)
    except Exception as e:
        raise HTTPException(status_code=422, detail=str(e))

    SettingsStore.put_section(db, section, validated.model_dump(), updated_by=user["username"])
    reload_settings_from_db(db)

    if section == "scheduler":
        _reschedule_if_running(settings.scheduler.cron_schedule, settings.scheduler.timezone)

    logger.info("Settings updated", section=section, updated_by=user["username"])
    return {"status": "ok", "section": section}


@router.post("/settings/seed")
async def seed_settings(user: AuthenticatedUser, db: DatabaseSession):
    """Seed DB with current in-memory settings (idempotent)."""
    from ...settings_store import SettingsStore
    from ...config import reload_settings_from_db
    seeded = SettingsStore.seed_from_settings(db)
    reload_settings_from_db(db)
    logger.info("Settings seeded", sections=seeded, requested_by=user["username"])
    return {"status": "ok", "seeded": seeded}


def _reschedule_if_running(cron_schedule: str, timezone: str) -> None:
    """Signal the in-process APScheduler to use the new cron, if it's running."""
    try:
        from ...scheduler.schedule import _scheduler_instance
        if _scheduler_instance and _scheduler_instance.running:
            from apscheduler.triggers.cron import CronTrigger
            import pytz
            parts = cron_schedule.split()
            trigger = CronTrigger(
                minute=parts[0], hour=parts[1], day=parts[2],
                month=parts[3], day_of_week=parts[4],
                timezone=pytz.timezone(timezone),
            )
            _scheduler_instance.reschedule_job("daily_pipeline", trigger=trigger)
            logger.info("Scheduler rescheduled", cron=cron_schedule, tz=timezone)
    except Exception as e:
        logger.warning("Could not reschedule in-process scheduler", error=str(e))
```

- [ ] **Étape 4 — Ajouter `_scheduler_instance` dans `scheduler/schedule.py`**

Dans `src/tenderai_bf/scheduler/schedule.py`, ajouter en haut du fichier après les imports :

```python
_scheduler_instance = None  # exposed for reschedule signal from API
```

Et dans `start_scheduler()`, juste après `scheduler = BlockingScheduler(timezone=timezone)` :

```python
    global _scheduler_instance
    _scheduler_instance = scheduler
```

- [ ] **Étape 5 — Vérifier que les tests API passent**

```bash
poetry run pytest tests/api/test_settings_endpoints.py -v --no-cov
```

Attendu : tous PASSED

- [ ] **Étape 6 — Vérifier qu'il n'y a pas de régression**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```

Attendu : tous PASSED

- [ ] **Étape 7 — Commit**

```bash
git add src/tenderai_bf/api/routers/admin.py src/tenderai_bf/scheduler/schedule.py tests/api/test_settings_endpoints.py src/tenderai_bf/api/schemas/__init__.py src/tenderai_bf/api/schemas/settings.py
git commit -m "feat: add settings GET/PUT/seed API endpoints with section validation"
```

---

## Task 6 : Startup seeding + scheduler lit les settings DB

**Files:**
- Modify: `src/tenderai_bf/api/main.py`
- Modify: `src/tenderai_bf/scheduler/schedule.py`

- [ ] **Étape 1 — Ajouter le seeding au démarrage de l'API**

Dans `src/tenderai_bf/api/main.py`, dans le bloc `# Startup` du lifespan, après le bloc database, ajouter :

```python
    # Seed settings from current config if DB is empty
    try:
        from ..db import SessionLocal
        from ..settings_store import SettingsStore
        from ..config import reload_settings_from_db
        with SessionLocal() as db_session:
            seeded = SettingsStore.seed_from_settings(db_session)
            if seeded:
                logger.info("Settings seeded from config", sections=seeded)
            reload_settings_from_db(db_session)
            logger.info("Settings loaded from DB")
    except Exception as e:
        logger.warning("Could not seed/reload settings from DB", error=str(e))
```

- [ ] **Étape 2 — Vérifier que `SessionLocal` est bien exporté depuis `db.py`**

```bash
poetry run python -c "from tenderai_bf.db import SessionLocal; print('OK')"
```

Si erreur, ouvrir `src/tenderai_bf/db.py` et vérifier que `SessionLocal` y est défini. S'il ne l'est pas, l'ajouter :

```python
from sqlalchemy.orm import sessionmaker
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
```

- [ ] **Étape 3 — Faire lire les settings DB au scheduler avant chaque run**

Dans `src/tenderai_bf/scheduler/schedule.py`, au début de la fonction `scheduled_pipeline_run()`, ajouter :

```python
    # Reload settings from DB so pipeline uses latest config
    try:
        from ..db import SessionLocal
        from ..config import reload_settings_from_db
        with SessionLocal() as db_session:
            reload_settings_from_db(db_session)
    except Exception as e:
        logger.warning("Could not reload settings from DB before run", error=str(e))
```

- [ ] **Étape 4 — Vérifier que l'API démarre sans erreur**

```bash
poetry run python -c "
import os; os.environ.setdefault('TENDERAI_JWT_SECRET', 'test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx'); os.environ.setdefault('TENDERAI_ADMIN_PASSWORD', 'test-admin-password-not-real')
from tenderai_bf.api.main import app; print('App import OK')
"
```

Attendu : `App import OK`

- [ ] **Étape 5 — Commit**

```bash
git add src/tenderai_bf/api/main.py src/tenderai_bf/scheduler/schedule.py
git commit -m "feat: seed and reload settings from DB on API startup and before each scheduler run"
```

---

## Task 7 : Proxy routes Next.js

**Files:**
- Create: `frontend/app/api/proxy/settings/route.ts`
- Create: `frontend/app/api/proxy/settings/[section]/route.ts`

- [ ] **Étape 1 — Créer `frontend/app/api/proxy/settings/route.ts`**

```typescript
import { NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function GET() {
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/settings`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Étape 2 — Créer `frontend/app/api/proxy/settings/[section]/route.ts`**

```typescript
import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ section: string }> }
) {
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { section } = await params;
  const res = await fetch(`${API_URL}/api/v1/admin/settings/${section}`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}

export async function PUT(
  req: NextRequest,
  { params }: { params: Promise<{ section: string }> }
) {
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { section } = await params;
  const body = await req.json();
  const res = await fetch(`${API_URL}/api/v1/admin/settings/${section}`, {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Étape 3 — Vérifier que TypeScript compile sans erreur**

```bash
cd /home/yulcom/web/tender-ai/frontend && npx tsc --noEmit 2>&1 | head -30
```

Attendu : aucune erreur sur les nouveaux fichiers

- [ ] **Étape 4 — Commit**

```bash
git add frontend/app/api/proxy/settings/
git commit -m "feat(frontend): add settings proxy routes"
```

---

## Task 8 : Composants partagés (readonly-section, prompt-editor-dialog)

**Files:**
- Create: `frontend/components/settings/readonly-section.tsx`
- Create: `frontend/components/settings/prompt-editor-dialog.tsx`

- [ ] **Étape 1 — Créer `readonly-section.tsx`**

```tsx
// frontend/components/settings/readonly-section.tsx
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

interface ReadonlyField {
  label: string;
  value: string;
}

interface Props {
  title: string;
  fields: ReadonlyField[];
}

export function ReadonlySection({ title, fields }: Props) {
  return (
    <Card className="border-slate-200 bg-slate-50">
      <CardHeader className="pb-3">
        <div className="flex items-center gap-2">
          <span className="text-slate-400">🔒</span>
          <CardTitle className="text-base text-slate-500">{title}</CardTitle>
        </div>
        <p className="text-xs text-slate-400">
          Géré par variable d&apos;environnement — non modifiable via l&apos;interface
        </p>
      </CardHeader>
      <CardContent>
        <dl className="grid grid-cols-2 gap-x-8 gap-y-2">
          {fields.map((f) => (
            <div key={f.label}>
              <dt className="text-xs text-slate-400">{f.label}</dt>
              <dd className="text-sm font-mono text-slate-500">{f.value}</dd>
            </div>
          ))}
        </dl>
      </CardContent>
    </Card>
  );
}
```

- [ ] **Étape 2 — Créer `prompt-editor-dialog.tsx`**

```tsx
// frontend/components/settings/prompt-editor-dialog.tsx
"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";

interface Props {
  title: string;
  value: string;
  onChange: (value: string) => void;
}

export function PromptEditorDialog({ title, value, onChange }: Props) {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState(value);

  function handleOpen(isOpen: boolean) {
    if (isOpen) setDraft(value);
    setOpen(isOpen);
  }

  function handleSave() {
    onChange(draft);
    setOpen(false);
  }

  return (
    <Dialog open={open} onOpenChange={handleOpen}>
      <DialogTrigger render={<Button type="button" variant="outline" size="sm" />}>
        Modifier →
      </DialogTrigger>
      <DialogContent className="max-w-3xl h-[80vh] flex flex-col">
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
        </DialogHeader>
        <textarea
          className="flex-1 w-full font-mono text-sm p-3 border border-input rounded-md resize-none focus:outline-none focus:ring-2 focus:ring-ring bg-background"
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          spellCheck={false}
        />
        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => setOpen(false)}>
            Annuler
          </Button>
          <Button type="button" onClick={handleSave}>
            Appliquer
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
```

- [ ] **Étape 3 — Vérifier que TypeScript compile**

```bash
cd /home/yulcom/web/tender-ai/frontend && npx tsc --noEmit 2>&1 | head -20
```

Attendu : aucune erreur

- [ ] **Étape 4 — Commit**

```bash
git add frontend/components/settings/
git commit -m "feat(frontend): add ReadonlySection and PromptEditorDialog components"
```

---

## Task 9 : Composants de section (pipeline, scheduler, llm, email, rag, classification, prompts)

**Files:**
- Create: `frontend/components/settings/pipeline-section.tsx`
- Create: `frontend/components/settings/scheduler-section.tsx`
- Create: `frontend/components/settings/llm-section.tsx`
- Create: `frontend/components/settings/email-section.tsx`
- Create: `frontend/components/settings/rag-section.tsx`
- Create: `frontend/components/settings/classification-section.tsx`
- Create: `frontend/components/settings/prompts-section.tsx`

Chaque composant suit le même pattern :
- Props : `initialData: <SectionType>`
- State local `form` + `saving` + `error` + `success`
- `handleSubmit` : `PUT /api/proxy/settings/<section>`
- Bouton "Sauvegarder" en bas avec feedback inline

- [ ] **Étape 1 — Créer `pipeline-section.tsx`**

```tsx
// frontend/components/settings/pipeline-section.tsx
"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

const DEDUP_METHODS = ["hash_only", "similarity_only", "hash_similarity", "llm_only", "hybrid"];

export interface PipelineData {
  max_items_per_run: number;
  min_relevance_score: number;
  deduplication_threshold: number;
  deduplication_method: string;
  use_llm_classification: boolean;
  pdf_timeout: number;
  max_file_size_mb: number;
}

interface Props { initialData: PipelineData; }

export function PipelineSection({ initialData }: Props) {
  const [form, setForm] = useState<PipelineData>(initialData);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState(false);

  function set<K extends keyof PipelineData>(key: K, value: PipelineData[K]) {
    setForm((prev) => ({ ...prev, [key]: value }));
    setSuccess(false);
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true);
    setError("");
    setSuccess(false);
    try {
      const res = await fetch("/api/proxy/settings/pipeline", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(form),
      });
      if (!res.ok) {
        const data = await res.json();
        setError(data.detail ?? "Erreur lors de la sauvegarde");
      } else {
        setSuccess(true);
      }
    } catch {
      setError("Erreur réseau.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Card>
      <CardHeader><CardTitle>Pipeline</CardTitle></CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1">
              <Label>Items max par run</Label>
              <Input type="number" value={form.max_items_per_run} min={1} max={10000}
                onChange={(e) => set("max_items_per_run", Number(e.target.value))} />
            </div>
            <div className="space-y-1">
              <Label>Score de pertinence minimum (0–1)</Label>
              <Input type="number" value={form.min_relevance_score} min={0} max={1} step={0.01}
                onChange={(e) => set("min_relevance_score", Number(e.target.value))} />
            </div>
            <div className="space-y-1">
              <Label>Seuil de déduplication (0–1)</Label>
              <Input type="number" value={form.deduplication_threshold} min={0} max={1} step={0.01}
                onChange={(e) => set("deduplication_threshold", Number(e.target.value))} />
            </div>
            <div className="space-y-1">
              <Label>Méthode de déduplication</Label>
              <select value={form.deduplication_method}
                onChange={(e) => set("deduplication_method", e.target.value)}
                className="w-full border border-input rounded-md px-3 py-2 text-sm bg-background">
                {DEDUP_METHODS.map((m) => <option key={m} value={m}>{m}</option>)}
              </select>
            </div>
            <div className="space-y-1">
              <Label>Timeout PDF (secondes)</Label>
              <Input type="number" value={form.pdf_timeout} min={10}
                onChange={(e) => set("pdf_timeout", Number(e.target.value))} />
            </div>
            <div className="space-y-1">
              <Label>Taille max fichier (Mo)</Label>
              <Input type="number" value={form.max_file_size_mb} min={1}
                onChange={(e) => set("max_file_size_mb", Number(e.target.value))} />
            </div>
          </div>
          <div className="flex items-center gap-2">
            <input id="llm-classif" type="checkbox" checked={form.use_llm_classification}
              onChange={(e) => set("use_llm_classification", e.target.checked)}
              className="h-4 w-4 rounded border-input" />
            <Label htmlFor="llm-classif" className="cursor-pointer">
              Utiliser le LLM pour la classification
            </Label>
          </div>
          {error && <p className="text-sm text-red-600">{error}</p>}
          {success && <p className="text-sm text-green-600">Sauvegardé ✓</p>}
          <Button type="submit" disabled={saving}>{saving ? "Sauvegarde…" : "Sauvegarder"}</Button>
        </form>
      </CardContent>
    </Card>
  );
}
```

- [ ] **Étape 2 — Créer `scheduler-section.tsx`**

```tsx
// frontend/components/settings/scheduler-section.tsx
"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

export interface SchedulerData {
  cron_schedule: string;
  timezone: string;
  enabled: boolean;
  max_concurrent_runs: number;
  run_on_startup: boolean;
}

interface Props { initialData: SchedulerData; }

export function SchedulerSection({ initialData }: Props) {
  const [form, setForm] = useState<SchedulerData>(initialData);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState(false);

  function set<K extends keyof SchedulerData>(key: K, value: SchedulerData[K]) {
    setForm((prev) => ({ ...prev, [key]: value }));
    setSuccess(false);
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true);
    setError("");
    setSuccess(false);
    try {
      const res = await fetch("/api/proxy/settings/scheduler", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(form),
      });
      if (!res.ok) {
        const data = await res.json();
        setError(data.detail ?? "Erreur lors de la sauvegarde");
      } else {
        setSuccess(true);
      }
    } catch {
      setError("Erreur réseau.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Card>
      <CardHeader><CardTitle>Planificateur</CardTitle></CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1">
              <Label>Planning cron (5 champs)</Label>
              <Input value={form.cron_schedule}
                onChange={(e) => set("cron_schedule", e.target.value)}
                placeholder="0 7 * * 1-5" />
              <p className="text-xs text-slate-400">ex : &quot;0 7 * * 1-5&quot; = Lun–Ven à 7h00</p>
            </div>
            <div className="space-y-1">
              <Label>Fuseau horaire</Label>
              <Input value={form.timezone}
                onChange={(e) => set("timezone", e.target.value)}
                placeholder="Africa/Ouagadougou" />
            </div>
            <div className="space-y-1">
              <Label>Runs max simultanés</Label>
              <Input type="number" value={form.max_concurrent_runs} min={1}
                onChange={(e) => set("max_concurrent_runs", Number(e.target.value))} />
            </div>
          </div>
          <div className="flex gap-6">
            <div className="flex items-center gap-2">
              <input id="sched-enabled" type="checkbox" checked={form.enabled}
                onChange={(e) => set("enabled", e.target.checked)}
                className="h-4 w-4 rounded border-input" />
              <Label htmlFor="sched-enabled" className="cursor-pointer">Planificateur actif</Label>
            </div>
            <div className="flex items-center gap-2">
              <input id="sched-startup" type="checkbox" checked={form.run_on_startup}
                onChange={(e) => set("run_on_startup", e.target.checked)}
                className="h-4 w-4 rounded border-input" />
              <Label htmlFor="sched-startup" className="cursor-pointer">Exécuter au démarrage</Label>
            </div>
          </div>
          <p className="text-xs text-amber-600">
            ⚠ Les modifications de planning cron prennent effet au prochain redémarrage du service worker.
          </p>
          {error && <p className="text-sm text-red-600">{error}</p>}
          {success && <p className="text-sm text-green-600">Sauvegardé ✓</p>}
          <Button type="submit" disabled={saving}>{saving ? "Sauvegarde…" : "Sauvegarder"}</Button>
        </form>
      </CardContent>
    </Card>
  );
}
```

- [ ] **Étape 3 — Créer `llm-section.tsx`**

```tsx
// frontend/components/settings/llm-section.tsx
"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

const LLM_PROVIDERS = ["groq", "openai", "ollama"];

export interface LLMData {
  provider: string;
  groq_model: string;
  openai_model: string;
  ollama_model: string;
  ollama_base_url: string;
  temperature: number;
  max_tokens: number;
  timeout: number;
}

interface Props { initialData: LLMData; }

export function LLMSection({ initialData }: Props) {
  const [form, setForm] = useState<LLMData>(initialData);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState(false);

  function set<K extends keyof LLMData>(key: K, value: LLMData[K]) {
    setForm((prev) => ({ ...prev, [key]: value }));
    setSuccess(false);
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true); setError(""); setSuccess(false);
    try {
      const res = await fetch("/api/proxy/settings/llm", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(form),
      });
      if (!res.ok) { const d = await res.json(); setError(d.detail ?? "Erreur"); }
      else setSuccess(true);
    } catch { setError("Erreur réseau."); }
    finally { setSaving(false); }
  }

  return (
    <Card>
      <CardHeader><CardTitle>Modèle LLM</CardTitle></CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-1">
            <Label>Fournisseur actif</Label>
            <select value={form.provider} onChange={(e) => set("provider", e.target.value)}
              className="w-full border border-input rounded-md px-3 py-2 text-sm bg-background">
              {LLM_PROVIDERS.map((p) => <option key={p} value={p}>{p}</option>)}
            </select>
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1">
              <Label>Modèle Groq</Label>
              <Input value={form.groq_model} onChange={(e) => set("groq_model", e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label>Modèle OpenAI</Label>
              <Input value={form.openai_model} onChange={(e) => set("openai_model", e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label>Modèle Ollama</Label>
              <Input value={form.ollama_model} onChange={(e) => set("ollama_model", e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label>URL Ollama</Label>
              <Input value={form.ollama_base_url} onChange={(e) => set("ollama_base_url", e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label>Température (0–2)</Label>
              <Input type="number" value={form.temperature} min={0} max={2} step={0.05}
                onChange={(e) => set("temperature", Number(e.target.value))} />
            </div>
            <div className="space-y-1">
              <Label>Tokens max</Label>
              <Input type="number" value={form.max_tokens} min={100}
                onChange={(e) => set("max_tokens", Number(e.target.value))} />
            </div>
            <div className="space-y-1">
              <Label>Timeout requête (s)</Label>
              <Input type="number" value={form.timeout} min={10}
                onChange={(e) => set("timeout", Number(e.target.value))} />
            </div>
          </div>
          {error && <p className="text-sm text-red-600">{error}</p>}
          {success && <p className="text-sm text-green-600">Sauvegardé ✓</p>}
          <Button type="submit" disabled={saving}>{saving ? "Sauvegarde…" : "Sauvegarder"}</Button>
        </form>
      </CardContent>
    </Card>
  );
}
```

- [ ] **Étape 4 — Créer `email-section.tsx`**

```tsx
// frontend/components/settings/email-section.tsx
"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

export interface EmailData {
  from_address: string;
  from_name: string;
  to_address: string;
  reply_to: string | null;
  subject_prefix: string;
  signature: string;
}

interface Props { initialData: EmailData; }

export function EmailSection({ initialData }: Props) {
  const [form, setForm] = useState<EmailData>(initialData);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState(false);

  function set<K extends keyof EmailData>(key: K, value: EmailData[K]) {
    setForm((prev) => ({ ...prev, [key]: value }));
    setSuccess(false);
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true); setError(""); setSuccess(false);
    try {
      const res = await fetch("/api/proxy/settings/email", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(form),
      });
      if (!res.ok) { const d = await res.json(); setError(d.detail ?? "Erreur"); }
      else setSuccess(true);
    } catch { setError("Erreur réseau."); }
    finally { setSaving(false); }
  }

  return (
    <Card>
      <CardHeader><CardTitle>Email</CardTitle></CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1">
              <Label>Adresse expéditeur</Label>
              <Input type="email" value={form.from_address}
                onChange={(e) => set("from_address", e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label>Nom expéditeur</Label>
              <Input value={form.from_name} onChange={(e) => set("from_name", e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label>Adresse destinataire</Label>
              <Input type="email" value={form.to_address}
                onChange={(e) => set("to_address", e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label>Reply-To (optionnel)</Label>
              <Input type="email" value={form.reply_to ?? ""}
                onChange={(e) => set("reply_to", e.target.value || null)} />
            </div>
            <div className="space-y-1 col-span-2">
              <Label>Préfixe du sujet</Label>
              <Input value={form.subject_prefix}
                onChange={(e) => set("subject_prefix", e.target.value)} />
            </div>
            <div className="space-y-1 col-span-2">
              <Label>Signature</Label>
              <Input value={form.signature} onChange={(e) => set("signature", e.target.value)} />
            </div>
          </div>
          {error && <p className="text-sm text-red-600">{error}</p>}
          {success && <p className="text-sm text-green-600">Sauvegardé ✓</p>}
          <Button type="submit" disabled={saving}>{saving ? "Sauvegarde…" : "Sauvegarder"}</Button>
        </form>
      </CardContent>
    </Card>
  );
}
```

- [ ] **Étape 5 — Créer `rag-section.tsx`**

```tsx
// frontend/components/settings/rag-section.tsx
"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

export interface RAGData {
  enabled: boolean;
  chunk_size: number;
  chunk_overlap: number;
  top_k_results: number;
  embedding_model: string;
  vector_search_query: string;
}

interface Props { initialData: RAGData; }

export function RAGSection({ initialData }: Props) {
  const [form, setForm] = useState<RAGData>(initialData);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState(false);

  function set<K extends keyof RAGData>(key: K, value: RAGData[K]) {
    setForm((prev) => ({ ...prev, [key]: value }));
    setSuccess(false);
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true); setError(""); setSuccess(false);
    try {
      const res = await fetch("/api/proxy/settings/rag", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(form),
      });
      if (!res.ok) { const d = await res.json(); setError(d.detail ?? "Erreur"); }
      else setSuccess(true);
    } catch { setError("Erreur réseau."); }
    finally { setSaving(false); }
  }

  return (
    <Card>
      <CardHeader><CardTitle>RAG (Retrieval-Augmented Generation)</CardTitle></CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="flex items-center gap-2">
            <input id="rag-enabled" type="checkbox" checked={form.enabled}
              onChange={(e) => set("enabled", e.target.checked)}
              className="h-4 w-4 rounded border-input" />
            <Label htmlFor="rag-enabled" className="cursor-pointer">RAG activé</Label>
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1">
              <Label>Taille des chunks (caractères)</Label>
              <Input type="number" value={form.chunk_size} min={64}
                onChange={(e) => set("chunk_size", Number(e.target.value))} />
            </div>
            <div className="space-y-1">
              <Label>Chevauchement des chunks</Label>
              <Input type="number" value={form.chunk_overlap} min={0}
                onChange={(e) => set("chunk_overlap", Number(e.target.value))} />
            </div>
            <div className="space-y-1">
              <Label>Résultats à récupérer (top-k)</Label>
              <Input type="number" value={form.top_k_results} min={1} max={100}
                onChange={(e) => set("top_k_results", Number(e.target.value))} />
            </div>
            <div className="space-y-1">
              <Label>Modèle d&apos;embedding</Label>
              <Input value={form.embedding_model}
                onChange={(e) => set("embedding_model", e.target.value)} />
            </div>
            <div className="space-y-1 col-span-2">
              <Label>Requête de recherche vectorielle</Label>
              <Input value={form.vector_search_query}
                onChange={(e) => set("vector_search_query", e.target.value)} />
            </div>
          </div>
          {error && <p className="text-sm text-red-600">{error}</p>}
          {success && <p className="text-sm text-green-600">Sauvegardé ✓</p>}
          <Button type="submit" disabled={saving}>{saving ? "Sauvegarde…" : "Sauvegarder"}</Button>
        </form>
      </CardContent>
    </Card>
  );
}
```

- [ ] **Étape 6 — Créer `classification-section.tsx`**

```tsx
// frontend/components/settings/classification-section.tsx
"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

export interface ClassificationData {
  relevant_keywords: Record<string, string[]>;
}

const CATEGORY_LABELS: Record<string, string> = {
  it_services: "Services IT",
  it_hardware: "Matériels informatiques",
  it_consulting: "Conseil IT",
};

interface Props { initialData: ClassificationData; }

export function ClassificationSection({ initialData }: Props) {
  const [form, setForm] = useState<ClassificationData>(initialData);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState(false);

  function setKeywords(category: string, text: string) {
    const keywords = text.split("\n").map((k) => k.trim()).filter(Boolean);
    setForm((prev) => ({
      relevant_keywords: { ...prev.relevant_keywords, [category]: keywords },
    }));
    setSuccess(false);
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true); setError(""); setSuccess(false);
    try {
      const res = await fetch("/api/proxy/settings/classification", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(form),
      });
      if (!res.ok) { const d = await res.json(); setError(d.detail ?? "Erreur"); }
      else setSuccess(true);
    } catch { setError("Erreur réseau."); }
    finally { setSaving(false); }
  }

  return (
    <Card>
      <CardHeader><CardTitle>Mots-clés de classification</CardTitle></CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-6">
          <p className="text-sm text-slate-500">Un mot-clé ou expression par ligne.</p>
          {Object.entries(form.relevant_keywords).map(([cat, keywords]) => (
            <div key={cat} className="space-y-1">
              <Label>{CATEGORY_LABELS[cat] ?? cat}</Label>
              <textarea
                className="w-full h-40 font-mono text-sm p-2 border border-input rounded-md resize-y focus:outline-none focus:ring-2 focus:ring-ring bg-background"
                value={keywords.join("\n")}
                onChange={(e) => setKeywords(cat, e.target.value)}
                spellCheck={false}
              />
              <p className="text-xs text-slate-400">{keywords.length} mots-clés</p>
            </div>
          ))}
          {error && <p className="text-sm text-red-600">{error}</p>}
          {success && <p className="text-sm text-green-600">Sauvegardé ✓</p>}
          <Button type="submit" disabled={saving}>{saving ? "Sauvegarde…" : "Sauvegarder"}</Button>
        </form>
      </CardContent>
    </Card>
  );
}
```

- [ ] **Étape 7 — Créer `prompts-section.tsx`**

```tsx
// frontend/components/settings/prompts-section.tsx
"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { PromptEditorDialog } from "./prompt-editor-dialog";

interface PromptPair { system: string; user_template: string; }

export interface PromptsData {
  extraction: PromptPair;
  classification: PromptPair;
  summarization: PromptPair;
  deduplication: PromptPair;
}

const PROMPT_LABELS: Record<keyof PromptsData, string> = {
  extraction: "Extraction",
  classification: "Classification",
  summarization: "Résumé",
  deduplication: "Déduplication",
};

interface Props { initialData: PromptsData; }

export function PromptsSection({ initialData }: Props) {
  const [form, setForm] = useState<PromptsData>(initialData);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState(false);

  function setPromptField(key: keyof PromptsData, field: "system" | "user_template", value: string) {
    setForm((prev) => ({
      ...prev,
      [key]: { ...prev[key], [field]: value },
    }));
    setSuccess(false);
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true); setError(""); setSuccess(false);
    try {
      const res = await fetch("/api/proxy/settings/prompts", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(form),
      });
      if (!res.ok) { const d = await res.json(); setError(d.detail ?? "Erreur"); }
      else setSuccess(true);
    } catch { setError("Erreur réseau."); }
    finally { setSaving(false); }
  }

  return (
    <Card>
      <CardHeader><CardTitle>Prompts LLM</CardTitle></CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-6">
          {(Object.keys(form) as Array<keyof PromptsData>).map((key) => (
            <div key={key} className="space-y-2 border rounded-lg p-4">
              <h3 className="font-medium text-sm">{PROMPT_LABELS[key]}</h3>
              <div className="flex items-center justify-between">
                <Label className="text-slate-500 text-xs">Prompt système</Label>
                <PromptEditorDialog
                  title={`${PROMPT_LABELS[key]} — Système`}
                  value={form[key].system}
                  onChange={(v) => setPromptField(key, "system", v)}
                />
              </div>
              <p className="text-xs text-slate-400 font-mono truncate bg-slate-50 p-1 rounded">
                {form[key].system.slice(0, 120)}…
              </p>
              <div className="flex items-center justify-between">
                <Label className="text-slate-500 text-xs">Template utilisateur</Label>
                <PromptEditorDialog
                  title={`${PROMPT_LABELS[key]} — Template utilisateur`}
                  value={form[key].user_template}
                  onChange={(v) => setPromptField(key, "user_template", v)}
                />
              </div>
              <p className="text-xs text-slate-400 font-mono truncate bg-slate-50 p-1 rounded">
                {form[key].user_template.slice(0, 120)}…
              </p>
            </div>
          ))}
          {error && <p className="text-sm text-red-600">{error}</p>}
          {success && <p className="text-sm text-green-600">Sauvegardé ✓</p>}
          <Button type="submit" disabled={saving}>{saving ? "Sauvegarde…" : "Sauvegarder"}</Button>
        </form>
      </CardContent>
    </Card>
  );
}
```

- [ ] **Étape 8 — Vérifier TypeScript**

```bash
cd /home/yulcom/web/tender-ai/frontend && npx tsc --noEmit 2>&1 | head -30
```

Attendu : aucune erreur

- [ ] **Étape 9 — Commit**

```bash
git add frontend/components/settings/
git commit -m "feat(frontend): add all settings section form components"
```

---

## Task 10 : Page settings (page.tsx + settings-client.tsx)

**Files:**
- Create: `frontend/app/(dashboard)/settings/settings-client.tsx`
- Modify: `frontend/app/(dashboard)/settings/page.tsx`

- [ ] **Étape 1 — Créer `settings-client.tsx`**

```tsx
// frontend/app/(dashboard)/settings/settings-client.tsx
"use client";

import { useState } from "react";
import { PipelineSection, type PipelineData } from "@/components/settings/pipeline-section";
import { SchedulerSection, type SchedulerData } from "@/components/settings/scheduler-section";
import { LLMSection, type LLMData } from "@/components/settings/llm-section";
import { EmailSection, type EmailData } from "@/components/settings/email-section";
import { RAGSection, type RAGData } from "@/components/settings/rag-section";
import { ClassificationSection, type ClassificationData } from "@/components/settings/classification-section";
import { PromptsSection, type PromptsData } from "@/components/settings/prompts-section";
import { ReadonlySection } from "@/components/settings/readonly-section";

const TABS = [
  "Pipeline", "Planificateur", "LLM", "Email",
  "RAG", "Classification", "Prompts", "Infrastructure",
] as const;
type Tab = typeof TABS[number];

interface Props {
  sections: Record<string, Record<string, unknown>>;
  readonly: Record<string, Record<string, string>>;
}

export function SettingsClient({ sections, readonly }: Props) {
  const [active, setActive] = useState<Tab>("Pipeline");

  return (
    <div className="space-y-6">
      <div className="flex gap-1 border-b overflow-x-auto">
        {TABS.map((tab) => (
          <button
            key={tab}
            onClick={() => setActive(tab)}
            className={`px-4 py-2 text-sm whitespace-nowrap border-b-2 transition-colors ${
              active === tab
                ? "border-slate-900 text-slate-900 font-medium"
                : "border-transparent text-slate-500 hover:text-slate-700"
            }`}
          >
            {tab}
          </button>
        ))}
      </div>

      {active === "Pipeline" && sections.pipeline && (
        <PipelineSection initialData={sections.pipeline as unknown as PipelineData} />
      )}
      {active === "Planificateur" && sections.scheduler && (
        <SchedulerSection initialData={sections.scheduler as unknown as SchedulerData} />
      )}
      {active === "LLM" && sections.llm && (
        <LLMSection initialData={sections.llm as unknown as LLMData} />
      )}
      {active === "Email" && sections.email && (
        <EmailSection initialData={sections.email as unknown as EmailData} />
      )}
      {active === "RAG" && sections.rag && (
        <RAGSection initialData={sections.rag as unknown as RAGData} />
      )}
      {active === "Classification" && sections.classification && (
        <ClassificationSection initialData={sections.classification as unknown as ClassificationData} />
      )}
      {active === "Prompts" && sections.prompts && (
        <PromptsSection initialData={sections.prompts as unknown as PromptsData} />
      )}
      {active === "Infrastructure" && (
        <div className="space-y-4">
          <ReadonlySection
            title="Base de données"
            fields={[{ label: "URL", value: readonly.database?.url ?? "***" }]}
          />
          <ReadonlySection
            title="Stockage MinIO"
            fields={[
              { label: "Endpoint", value: readonly.minio?.endpoint ?? "***" },
              { label: "Bucket", value: readonly.minio?.bucket_name ?? "***" },
              { label: "Credentials", value: "***" },
            ]}
          />
          <ReadonlySection
            title="SMTP"
            fields={[
              { label: "Hôte", value: readonly.smtp?.host ?? "***" },
              { label: "Port", value: readonly.smtp?.port ?? "***" },
              { label: "Credentials", value: "***" },
            ]}
          />
          <ReadonlySection
            title="Sécurité"
            fields={[
              { label: "Admin username", value: readonly.security?.admin_username ?? "***" },
              { label: "JWT secret", value: "***" },
              { label: "Admin password", value: "***" },
            ]}
          />
        </div>
      )}

      {!sections.pipeline && active !== "Infrastructure" && (
        <div className="text-center py-12 text-slate-400">
          <p>Aucune configuration en base de données.</p>
          <p className="text-sm mt-1">
            Lancez le seeding via l&apos;API : <code>POST /api/v1/admin/settings/seed</code>
          </p>
        </div>
      )}
    </div>
  );
}
```

- [ ] **Étape 2 — Remplacer `page.tsx`**

```tsx
// frontend/app/(dashboard)/settings/page.tsx
import { cookies } from "next/headers";
import { SettingsClient } from "./settings-client";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "";

export default async function SettingsPage() {
  const token = (await cookies()).get("auth_token")?.value ?? "";
  const res = await fetch(`${API_URL}/api/v1/admin/settings`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  }).catch(() => null);

  const body = res?.ok ? await res.json() : { sections: {}, readonly: {} };

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Paramètres</h1>
      <SettingsClient sections={body.sections ?? {}} readonly={body.readonly ?? {}} />
    </div>
  );
}
```

- [ ] **Étape 3 — Vérifier que TypeScript compile sans erreur**

```bash
cd /home/yulcom/web/tender-ai/frontend && npx tsc --noEmit 2>&1 | head -30
```

Attendu : aucune erreur

- [ ] **Étape 4 — Lancer le build Next.js**

```bash
cd /home/yulcom/web/tender-ai/frontend && npm run build 2>&1 | tail -20
```

Attendu : build réussi, aucune erreur rouge

- [ ] **Étape 5 — Appliquer la migration en base locale**

```bash
cd /home/yulcom/web/tender-ai && make migrate
```

Attendu : `Running upgrade 0001 -> 0002, add_app_settings`

- [ ] **Étape 6 — Vérifier les tests backend une dernière fois**

```bash
poetry run pytest tests/test_settings_store.py tests/api/test_settings_endpoints.py -v --no-cov
```

Attendu : tous PASSED

- [ ] **Étape 7 — Commit final**

```bash
git add frontend/app/\(dashboard\)/settings/
git commit -m "feat(frontend): settings management page with tabs and section forms"
```

- [ ] **Étape 8 — Mettre à jour IMPROVEMENTS.md**

Dans `IMPROVEMENTS.md`, changer le status des items #2 et #3 de `planned` en `done` :

```markdown
| 2 | [Database-persisted configuration](#2-database-persisted-configuration) | `done` | |
| 3 | [Settings management module (admin dashboard)](#3-settings-management-module-admin-dashboard) | `done` | |
```

```bash
git add IMPROVEMENTS.md
git commit -m "docs: mark settings management improvements as done"
```
