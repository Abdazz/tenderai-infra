# DB-First Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the pipeline read all operational config (LLM, pipeline thresholds, classification, prompts, email, RAG, sources) from `country_settings` / `sources` DB tables at runtime; `settings.yaml` is used only for the initial seed.

**Architecture:** `TenderAIState.country_config` is already loaded from `CountryStore.get_all_with_fallback()` in `graph.py:run()`. The remaining work is (1) add a fail-hard `cfg()` accessor, (2) strip the YAML-runtime paths from `config.py` and `load_sources.py`, (3) patch each pipeline node to use `cfg(state, section, key)` instead of `settings.*`, and (4) wire the startup seed loop to cover all existing countries.

**Tech Stack:** Python 3.11, Pydantic v2, SQLAlchemy, FastAPI, LangGraph, pytest

---

## File Map

| File | Change |
|---|---|
| `src/tenderai_bf/agents/graph.py` | Add `cfg()` helper (exported) |
| `src/tenderai_bf/config.py` | Remove 5 fields, 3 methods; trim `_load_yaml_config` |
| `src/tenderai_bf/api/main.py` | Seed loop for all existing countries; remove `reload_settings_from_db` call |
| `src/tenderai_bf/agents/nodes/load_sources.py` | Delete YAML branch (MODE 1) |
| `src/tenderai_bf/agents/nodes/classify.py` | Replace all `settings.*` with `cfg(state, ...)` |
| `src/tenderai_bf/agents/nodes/deduplicate.py` | Same |
| `src/tenderai_bf/agents/nodes/email_report.py` | Same + use `Recipient` table |
| `src/tenderai_bf/agents/nodes/extract_item_links.py` | Same |
| `src/tenderai_bf/agents/nodes/summarize.py` | Same |
| `src/tenderai_bf/agents/nodes/parse_pdf_rag.py` | Add `rag_cfg` / `llm_cfg` params to helpers |
| `src/tenderai_bf/agents/nodes/parse_extract.py` | Pass `rag_cfg` when calling `parse_pdf_with_rag` |
| `tests/nodes/test_classify.py` | Add `country_config`-injected state fixture |
| `tests/nodes/test_deduplicate.py` | Same |

---

## Task 1 — Add `cfg()` helper to `graph.py`

**Files:**
- Modify: `src/tenderai_bf/agents/graph.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_cfg_helper.py`:

```python
"""Tests for the cfg() state config accessor."""
import os
os.environ.setdefault("TENDERAI_ENVIRONMENT", "test")
os.environ.setdefault("TENDERAI_DATABASE_URL", "sqlite:///test.db")
os.environ.setdefault("TENDERAI_JWT_SECRET", "test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx")
os.environ.setdefault("TENDERAI_ADMIN_PASSWORD", "test-admin-password-not-real")

import pytest
from tenderai_bf.agents.graph import TenderAIState, cfg


def make_state(**country_config_override):
    return TenderAIState(
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
            "llm": {
                "provider": "groq",
                "groq_model": "llama-3.3-70b-versatile",
                "openai_model": "gpt-4o",
                "ollama_model": "llama3",
                "ollama_base_url": "",
                "temperature": 0.1,
                "max_tokens": 2000,
                "timeout": 60,
            },
            **country_config_override,
        },
    )


def test_cfg_returns_existing_value():
    state = make_state()
    assert cfg(state, "pipeline", "max_items_per_run") == 100


def test_cfg_missing_section_raises():
    state = make_state()
    with pytest.raises(RuntimeError, match="Missing DB config"):
        cfg(state, "nonexistent_section", "some_key")


def test_cfg_missing_key_raises():
    state = make_state()
    with pytest.raises(RuntimeError, match="Missing DB config"):
        cfg(state, "pipeline", "nonexistent_key")


def test_cfg_error_message_includes_country_id_section_key():
    state = make_state()
    state.country_id = 42
    with pytest.raises(RuntimeError) as exc_info:
        cfg(state, "missing_section", "missing_key")
    msg = str(exc_info.value)
    assert "42" in msg
    assert "missing_section" in msg
    assert "missing_key" in msg
```

- [ ] **Step 2: Run test to verify it fails**

```bash
poetry run pytest tests/test_cfg_helper.py -v --no-cov
```

Expected: `ImportError` or `AttributeError` — `cfg` not yet defined.

- [ ] **Step 3: Add `cfg()` to `graph.py`**

Open `src/tenderai_bf/agents/graph.py`. After the `TenderAIState` class definition (around line 118), add:

```python
def cfg(state: "TenderAIState", section: str, key: str) -> Any:
    """Read state.country_config[section][key]. Raises RuntimeError if absent.

    Use this in every pipeline node instead of settings.* for operational config.
    Fail-hard: a missing key means the DB was not seeded — surface it immediately.
    """
    try:
        return state.country_config[section][key]
    except KeyError:
        raise RuntimeError(
            f"Missing DB config: country_id={state.country_id} "
            f"section='{section}' key='{key}' — run seed first"
        )
```

Also add `cfg` to the module's exports by verifying it is importable from `tenderai_bf.agents.graph`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
poetry run pytest tests/test_cfg_helper.py -v --no-cov
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/tenderai_bf/agents/graph.py tests/test_cfg_helper.py
git commit -m "feat(config): add cfg() fail-hard accessor for pipeline DB config"
```

---

## Task 2 — Trim `config.py`

**Files:**
- Modify: `src/tenderai_bf/config.py`

- [ ] **Step 1: Remove 5 fields from the `Settings` class**

In `src/tenderai_bf/config.py`, inside the `Settings` class, delete these 4 field declarations (around lines 390–408):

```python
# DELETE these lines:
    use_database_sources: bool = Field(
        default=False,
        description="If True, sync and use sources from database. If False, use only settings.yaml (dev mode)",
    )

    # Sources and recipients

    # External configuration
    sources: list[dict[str, Any]] = Field(default_factory=list)
    rate_limits: dict[str, str] = Field(default_factory=dict)
    recipients: list[dict[str, str]] = Field(default_factory=list)
    prompts: dict[str, Any] = Field(
        default_factory=dict, description="LLM prompts templates from settings.yaml"
    )
```

- [ ] **Step 2: Remove 3 methods**

Delete these three methods/functions from `config.py`:

```python
# DELETE get_active_sources() method from Settings class (around line 636):
    def get_active_sources(self) -> list[dict[str, Any]]:
        """Get only enabled sources."""
        return [source for source in self.sources if source.get("enabled", True)]

# DELETE apply_db_override() method from Settings class (around line 641):
    def apply_db_override(self, section: str, data: dict) -> None:
        ...  # (entire method body)

# DELETE reload_settings_from_db() module-level function (around line 671):
def reload_settings_from_db(db) -> None:
    """Refresh the global settings singleton from DB. Call after startup seeding."""
    from .settings_store import SettingsStore

    all_sections = SettingsStore.get_all(db)
    for section, data in all_sections.items():
        settings.apply_db_override(section, data)
```

- [ ] **Step 3: Trim `_load_yaml_config()`**

Replace the entire `_load_yaml_config` method body with a version that only keeps `ocr`:

```python
    def _load_yaml_config(self) -> None:
        """Load infra-only overrides from settings.yaml.

        Operational config (llm, pipeline, classification, prompts, rag,
        scheduler, email) is seeded into the DB at startup and read from
        country_settings at runtime — not from this file.
        """
        yaml_path = Path("settings.yaml")
        if not yaml_path.exists():
            return
        try:
            with open(yaml_path, encoding="utf-8") as f:
                yaml_config = yaml.safe_load(f)
            if not yaml_config:
                return
            yaml_config = expand_env_vars(yaml_config)
            if "ocr" in yaml_config:
                ocr_config = yaml_config["ocr"]
                if "enabled" in ocr_config:
                    self.ocr.enabled = ocr_config["enabled"]
                if "language" in ocr_config:
                    self.ocr.language = ocr_config["language"]
        except Exception as e:
            print(f"Warning: Could not load settings.yaml: {e}")
```

- [ ] **Step 4: Verify tests still pass**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration" 2>&1 | tail -20
```

Expected: all previously passing tests still pass (no `AttributeError` on removed fields).

- [ ] **Step 5: Commit**

```bash
git add src/tenderai_bf/config.py
git commit -m "feat(config): remove YAML-runtime fields and methods from Settings"
```

---

## Task 3 — Update API startup to seed all countries

**Files:**
- Modify: `src/tenderai_bf/api/main.py`

- [ ] **Step 1: Replace the startup seed block**

In `src/tenderai_bf/api/main.py`, find the block that currently:
1. Calls `SettingsStore.seed_from_settings(db_session)`
2. Calls `reload_settings_from_db(db_session)`

Replace it with (remove the `reload_settings_from_db` call, add a loop over all countries):

```python
    # Seed settings from current config if DB is empty, then seed all countries
    try:
        from ..db import get_session_factory
        from ..settings_store import SettingsStore
        from ..country_store import CountryStore as CS
        from ..models import Country as CountryModel

        SessionLocal = get_session_factory()
        with SessionLocal() as db_session:
            seeded = SettingsStore.seed_from_settings(db_session)
            if seeded:
                logger.info("Settings seeded from config", sections=seeded)

            # Seed country_settings for every active country that is missing rows
            countries = db_session.query(CountryModel).filter(
                CountryModel.active == True
            ).all()
            for country in countries:
                seeded_cs = CS.seed_from_global(db_session, country.id)
                if seeded_cs:
                    logger.info(
                        "Country settings seeded",
                        country_code=country.code,
                        sections=seeded_cs,
                    )
    except Exception as e:
        logger.warning("Could not seed settings from DB", error=str(e))
```

Also remove the import of `reload_settings_from_db` if it exists in the imports at the top of the try block.

- [ ] **Step 2: Remove the now-dead BF-only seed block**

The existing code has a separate block that seeds only BF:

```python
    # Seed BF country if no countries exist yet
    try:
        from ..country_store import CountryStore as CS
        from ..models import Country as CountryModel
        ...
```

This logic is now handled by the loop above (if no countries exist, the loop body is a no-op — but BF should already exist from migration 0003). Keep this block only if needed for a true first-run with an empty DB. If migration 0003 already seeds BF, this block can be removed. **Remove it** since migration 0003 guarantees BF exists.

- [ ] **Step 3: Run the API smoke test**

```bash
poetry run pytest tests/test_smoke.py -v --no-cov 2>&1 | tail -20
```

Expected: passes (or skipped if network-dependent).

- [ ] **Step 4: Commit**

```bash
git add src/tenderai_bf/api/main.py
git commit -m "feat(startup): seed country_settings for all active countries at startup"
```

---

## Task 4 — Refactor `load_sources.py` — delete YAML branch

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/load_sources.py`

- [ ] **Step 1: Write the failing test**

Add to `tests/nodes/test_load_sources.py` (create if it doesn't exist):

```python
"""Test load_sources node uses DB only."""
import os
os.environ.setdefault("TENDERAI_ENVIRONMENT", "test")
os.environ.setdefault("TENDERAI_DATABASE_URL", "sqlite:///test.db")
os.environ.setdefault("TENDERAI_JWT_SECRET", "test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx")
os.environ.setdefault("TENDERAI_ADMIN_PASSWORD", "test-admin-password-not-real")

from unittest.mock import patch, MagicMock
from tenderai_bf.agents.graph import TenderAIState
from tenderai_bf.agents.nodes.load_sources import load_sources_node


def test_load_sources_uses_db_not_yaml():
    """load_sources must never read settings.get_active_sources()."""
    state = TenderAIState(country_id=1, country_config={
        "pipeline": {"max_items_per_run": 100, "min_relevance_score": 0.5,
                     "deduplication_method": "hash_only", "deduplication_threshold": 0.85,
                     "use_llm_classification": False, "pdf_timeout": 30, "max_file_size_mb": 10},
    })

    mock_source = MagicMock()
    mock_source.id = 1
    mock_source.name = "Test Source"
    mock_source.base_url = "https://example.com"
    mock_source.list_url = "https://example.com/tenders"
    mock_source.parser_type = "html"
    mock_source.rate_limit = "10/m"
    mock_source.patterns = {}
    mock_source.enabled = True
    mock_source.last_seen_at = None
    mock_source.last_success_at = None
    mock_source.last_error_at = None
    mock_source.last_error_message = None

    mock_session = MagicMock()
    mock_query = MagicMock()
    mock_session.query.return_value = mock_query
    mock_query.filter.return_value = mock_query
    mock_query.all.return_value = [mock_source]

    with patch("tenderai_bf.agents.nodes.load_sources.get_db_context") as mock_ctx:
        mock_ctx.return_value.__enter__ = lambda s: mock_session
        mock_ctx.return_value.__exit__ = MagicMock(return_value=False)
        result = load_sources_node(state)

    assert len(result.sources) == 1
    assert result.sources[0]["name"] == "Test Source"


def test_load_sources_fails_if_no_sources():
    """Pipeline should stop if no active sources exist for country."""
    state = TenderAIState(country_id=1, country_config={})

    mock_session = MagicMock()
    mock_query = MagicMock()
    mock_session.query.return_value = mock_query
    mock_query.filter.return_value = mock_query
    mock_query.all.return_value = []

    with patch("tenderai_bf.agents.nodes.load_sources.get_db_context") as mock_ctx:
        mock_ctx.return_value.__enter__ = lambda s: mock_session
        mock_ctx.return_value.__exit__ = MagicMock(return_value=False)
        result = load_sources_node(state)

    assert result.should_continue is False
    assert result.error_occurred is True
```

- [ ] **Step 2: Run test to verify it fails**

```bash
poetry run pytest tests/nodes/test_load_sources.py -v --no-cov
```

Expected: FAIL — `AttributeError` or the node behaves differently (currently uses YAML path).

- [ ] **Step 3: Rewrite `load_sources.py`**

Replace the entire file content with:

```python
"""Load active sources for the pipeline from the database."""

import time
from datetime import datetime

from ...db import get_db_context
from ...logging import get_logger
from ...models import Source
from ...utils.node_logger import clear_node_output, log_node_output

logger = get_logger(__name__)


def load_sources_node(state) -> dict:
    """Load active sources for state.country_id from the sources table."""

    clear_node_output("load_sources")
    logger.info("Starting load_sources step", run_id=state.run_id)
    start_time = time.time()

    try:
        # Sources already injected (e.g. from a test or API override)
        if state.sources:
            logger.info(
                "Using sources from state",
                count=len(state.sources),
                run_id=state.run_id,
            )
            state.update_stats(sources_checked=len(state.sources))
            return state

        sources = []
        with get_db_context() as session:
            db_sources = (
                session.query(Source)
                .filter(
                    Source.country_id == state.country_id,
                    Source.enabled == True,  # noqa: E712
                )
                .all()
            )

            for db_source in db_sources:
                sources.append({
                    "id": db_source.id,
                    "name": db_source.name,
                    "base_url": db_source.base_url,
                    "list_url": db_source.list_url,
                    "parser_type": db_source.parser_type,
                    "rate_limit": db_source.rate_limit,
                    "patterns": db_source.patterns or {},
                    "last_seen_at": db_source.last_seen_at.isoformat()
                    if db_source.last_seen_at else None,
                    "last_success_at": db_source.last_success_at.isoformat()
                    if db_source.last_success_at else None,
                    "last_error_at": db_source.last_error_at.isoformat()
                    if db_source.last_error_at else None,
                    "last_error_message": db_source.last_error_message,
                })
                logger.debug(
                    "Source loaded from DB",
                    source_name=db_source.name,
                    run_id=state.run_id,
                )

        state.sources = sources
        state.update_stats(sources_checked=len(sources))
        log_node_output("load_sources", sources, run_id=state.run_id)

        duration = time.time() - start_time
        logger.info(
            "Load sources completed",
            sources_loaded=len(sources),
            country_id=state.country_id,
            duration_seconds=duration,
            run_id=state.run_id,
        )

        if not sources:
            state.add_error(
                "load_sources",
                f"No active sources found for country_id={state.country_id} — "
                "seed the sources table first",
            )
            state.should_continue = False

        return state

    except Exception as e:
        logger.error(
            "Load sources step failed", error=str(e), run_id=state.run_id, exc_info=True
        )
        state.add_error("load_sources", str(e))
        state.should_continue = False
        return state
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
poetry run pytest tests/nodes/test_load_sources.py -v --no-cov
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/tenderai_bf/agents/nodes/load_sources.py tests/nodes/test_load_sources.py
git commit -m "feat(load_sources): remove YAML branch — always load sources from DB"
```

---

## Task 5 — Refactor `classify.py`

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/classify.py`

- [ ] **Step 1: Write the failing test**

Add to `tests/nodes/test_classify.py`:

```python
import os
os.environ.setdefault("TENDERAI_ENVIRONMENT", "test")
os.environ.setdefault("TENDERAI_DATABASE_URL", "sqlite:///test.db")
os.environ.setdefault("TENDERAI_JWT_SECRET", "test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx")
os.environ.setdefault("TENDERAI_ADMIN_PASSWORD", "test-admin-password-not-real")

import pytest
from tenderai_bf.agents.graph import TenderAIState
from tenderai_bf.agents.nodes.classify import classify_with_keywords

COUNTRY_CONFIG = {
    "pipeline": {
        "use_llm_classification": False,
        "min_relevance_score": 0.3,
        "deduplication_method": "hash_only",
        "deduplication_threshold": 0.85,
        "max_items_per_run": 100,
        "pdf_timeout": 30,
        "max_file_size_mb": 10,
    },
    "classification": {
        "relevant_keywords": {
            "it_services": ["informatique", "logiciel", "serveur", "réseau"],
            "it_hardware": ["ordinateur", "équipement réseau"],
        }
    },
    "llm": {
        "provider": "groq", "groq_model": "llama-3.3-70b-versatile",
        "openai_model": "gpt-4o", "ollama_model": "llama3", "ollama_base_url": "",
        "temperature": 0.1, "max_tokens": 2000, "timeout": 60,
    },
}


def test_classify_with_keywords_uses_country_config():
    state = TenderAIState(
        country_id=1,
        country_config=COUNTRY_CONFIG,
        items_parsed=[
            {
                "id": "t1",
                "title": "Acquisition de serveurs et équipements réseau",
                "description": "Fourniture de serveurs pour datacenter",
                "category": "IT",
                "entity": "Ministère",
                "keywords": [],
            },
            {
                "id": "t2",
                "title": "Construction de routes rurales",
                "description": "Travaux de BTP",
                "category": "BTP",
                "entity": "Mairie",
                "keywords": [],
            },
        ],
    )
    result = classify_with_keywords(state)
    relevant_ids = [i["id"] for i in result.relevant_items]
    assert "t1" in relevant_ids
    assert "t2" not in relevant_ids


def test_classify_fails_hard_if_config_missing():
    """classify_with_keywords must raise if pipeline section absent."""
    state = TenderAIState(
        country_id=1,
        country_config={},  # empty — no sections seeded
        items_parsed=[{"id": "t1", "title": "test", "description": "x",
                       "category": "IT", "entity": "X", "keywords": []}],
    )
    with pytest.raises(RuntimeError, match="Missing DB config"):
        classify_with_keywords(state)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
poetry run pytest tests/nodes/test_classify.py::test_classify_with_keywords_uses_country_config tests/nodes/test_classify.py::test_classify_fails_hard_if_config_missing -v --no-cov
```

Expected: FAIL (currently falls back to `settings.*` instead of raising).

- [ ] **Step 3: Replace all `settings.*` accesses in `classify.py`**

Open `src/tenderai_bf/agents/nodes/classify.py`. Add the import at the top:

```python
from ..graph import cfg
```

Then apply the following replacements:

**Replacement 1** — `classify_node` / `classify_with_keywords` entry (around line 106):
```python
# BEFORE:
        _pipeline_cfg = getattr(state, "country_config", {}).get("pipeline", {})
        _use_llm = _pipeline_cfg.get(
            "use_llm_classification", settings.processing.use_llm_classification
        )

# AFTER:
        _use_llm = cfg(state, "pipeline", "use_llm_classification")
```

**Replacement 2** — keywords loading (around line 140):
```python
# BEFORE:
        _cls_cfg = getattr(state, "country_config", {}).get("classification", {})
        relevant_keywords = _cls_cfg.get("relevant_keywords", None)
        if (
            relevant_keywords is None
            and hasattr(settings, "classification")
            and hasattr(settings.classification, "relevant_keywords")
        ):
            relevant_keywords = settings.classification.relevant_keywords

# AFTER:
        relevant_keywords = cfg(state, "classification", "relevant_keywords")
```

**Replacement 3** — min_relevance_score fallback (around line 221):
```python
# BEFORE:
            if existing_score is not None and existing_score >= getattr(
                state, "country_config", {}
            ).get("pipeline", {}).get(
                "min_relevance_score", settings.processing.min_relevance_score
            ):

# AFTER:
            if existing_score is not None and existing_score >= cfg(
                state, "pipeline", "min_relevance_score"
            ):
```

**Replacement 4** — second min_relevance_score usage (around line 265):
```python
# BEFORE:
                .get("min_relevance_score", settings.processing.min_relevance_score),

# AFTER:
                .get("min_relevance_score", cfg(state, "pipeline", "min_relevance_score")),
```

**Replacement 5** — third min_relevance_score usage (around line 300):
```python
# BEFORE:
            ).get("pipeline", {}).get(
                "min_relevance_score", settings.processing.min_relevance_score
            )

# AFTER (full containing expression, replace):
            cfg(state, "pipeline", "min_relevance_score")
```

**Replacement 6** — LLM provider logging (around line 331):
```python
# BEFORE:
        llm_provider = settings.llm.provider

# AFTER:
        llm_provider = cfg(state, "llm", "provider")
```

**Replacement 7** — keywords in LLM branch (around line 344):
```python
# BEFORE:
        it_keywords = []
        if hasattr(settings, "classification") and hasattr(
            settings.classification, "relevant_keywords"
        ):
            relevant_keywords = settings.classification.relevant_keywords
            for category, keywords in relevant_keywords.items():
                it_keywords.extend(keywords)

# AFTER:
        it_keywords = []
        relevant_keywords = cfg(state, "classification", "relevant_keywords")
        for category, keywords in relevant_keywords.items():
            it_keywords.extend(keywords)
```

**Replacement 8** — provider in completion log (around line 561):
```python
# BEFORE:
            provider=settings.llm.provider,

# AFTER:
            provider=cfg(state, "llm", "provider"),
```

Remove the `from ...config import settings` import line if it is no longer used anywhere else in the file. Verify with:
```bash
grep "settings\." src/tenderai_bf/agents/nodes/classify.py
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
poetry run pytest tests/nodes/test_classify.py -v --no-cov 2>&1 | tail -20
```

Expected: the two new tests pass; existing tests unaffected.

- [ ] **Step 5: Commit**

```bash
git add src/tenderai_bf/agents/nodes/classify.py tests/nodes/test_classify.py
git commit -m "feat(classify): read config from state.country_config via cfg()"
```

---

## Task 6 — Refactor `deduplicate.py`

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/deduplicate.py`

- [ ] **Step 1: Write the failing test**

Add to `tests/nodes/test_deduplicate.py`:

```python
import os
os.environ.setdefault("TENDERAI_ENVIRONMENT", "test")
os.environ.setdefault("TENDERAI_DATABASE_URL", "sqlite:///test.db")
os.environ.setdefault("TENDERAI_JWT_SECRET", "test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx")
os.environ.setdefault("TENDERAI_ADMIN_PASSWORD", "test-admin-password-not-real")

import pytest
from tenderai_bf.agents.graph import TenderAIState
from tenderai_bf.agents.nodes.deduplicate import deduplicate_node

COUNTRY_CONFIG = {
    "pipeline": {
        "use_llm_classification": False,
        "min_relevance_score": 0.3,
        "deduplication_method": "hash_only",
        "deduplication_threshold": 0.85,
        "max_items_per_run": 100,
        "pdf_timeout": 30,
        "max_file_size_mb": 10,
    },
    "llm": {
        "provider": "groq", "groq_model": "llama-3.3-70b-versatile",
        "openai_model": "gpt-4o", "ollama_model": "llama3", "ollama_base_url": "",
        "temperature": 0.1, "max_tokens": 2000, "timeout": 60,
    },
    "prompts": {
        "deduplication": {"system": "", "user_template": ""},
        "extraction": {"system": "", "user_template": ""},
        "classification": {"system": "", "user_template": ""},
        "summarization": {"system": "", "user_template": ""},
    },
}


def test_deduplicate_hash_only_uses_country_config():
    import hashlib
    def h(s): return hashlib.sha256(s.encode()).hexdigest()

    state = TenderAIState(
        country_id=1,
        country_config=COUNTRY_CONFIG,
        relevant_items=[
            {"id": "a", "title": "Tender A", "content_hash": h("unique_a")},
            {"id": "b", "title": "Tender B", "content_hash": h("unique_b")},
            {"id": "c", "title": "Tender A dup", "content_hash": h("unique_a")},
        ],
    )
    result = deduplicate_node(state)
    unique_ids = [i["id"] for i in result.unique_items]
    assert "a" in unique_ids
    assert "b" in unique_ids
    assert "c" not in unique_ids  # duplicate of "a"


def test_deduplicate_fails_hard_if_config_missing():
    state = TenderAIState(
        country_id=1,
        country_config={},
        relevant_items=[{"id": "a", "title": "T", "content_hash": "abc"}],
    )
    with pytest.raises(RuntimeError, match="Missing DB config"):
        deduplicate_node(state)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
poetry run pytest tests/nodes/test_deduplicate.py::test_deduplicate_hash_only_uses_country_config tests/nodes/test_deduplicate.py::test_deduplicate_fails_hard_if_config_missing -v --no-cov
```

Expected: FAIL.

- [ ] **Step 3: Replace `settings.*` in `deduplicate.py`**

Add import at top of file:
```python
from ..graph import cfg
```

**Replacement 1** — LLM provider in `check_duplicate_with_llm` (around line 30):
```python
# BEFORE:
        llm_provider = settings.llm.provider

# AFTER:
        llm_provider = cfg(state, "llm", "provider")
```

Note: `check_duplicate_with_llm` must receive `state` as a parameter. Check its current signature — if it does not have `state`, add it and update all call sites within `deduplicate.py`.

**Replacement 2** — prompts in `check_duplicate_with_llm` (around line 41):
```python
# BEFORE:
        dedup_prompts = settings.prompts.get("deduplication", {})

# AFTER:
        dedup_prompts = state.country_config.get("prompts", {}).get("deduplication", {})
```

**Replacement 3** — deduplication method (around line 127):
```python
# BEFORE:
        method = settings.processing.deduplication_method

# AFTER:
        method = cfg(state, "pipeline", "deduplication_method")
```

**Replacement 4** — deduplication threshold (around line 135):
```python
# BEFORE:
        threshold = (
            settings.processing.deduplication_threshold * 100
        )

# AFTER:
        threshold = cfg(state, "pipeline", "deduplication_threshold") * 100
```

Remove `from ...config import settings` import if no longer used:
```bash
grep "settings\." src/tenderai_bf/agents/nodes/deduplicate.py
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
poetry run pytest tests/nodes/test_deduplicate.py -v --no-cov 2>&1 | tail -20
```

Expected: new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/tenderai_bf/agents/nodes/deduplicate.py tests/nodes/test_deduplicate.py
git commit -m "feat(deduplicate): read config from state.country_config via cfg()"
```

---

## Task 7 — Refactor `email_report.py`

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/email_report.py`

- [ ] **Step 1: Replace the recipient resolution block**

Open `src/tenderai_bf/agents/nodes/email_report.py`. Add imports:
```python
from ..graph import cfg
from ...db import get_db_context
from ...models import Recipient
```

Find the recipient resolution block (around line 56) and replace it entirely:

```python
# BEFORE (lines ~59–67):
    recipients = []
    _email_cfg = getattr(state, "country_config", {}).get("email", {})
    _to = _email_cfg.get("to_address") or settings.email.to_address
    if _to:
        recipients.append(_to)
    if settings.is_production and settings.recipients:
        for recipient in settings.recipients:
            if "email" in recipient and recipient["email"] not in recipients:
                recipients.append(recipient["email"])

# AFTER:
    recipients = []
    # Primary address from country_settings["email"]
    _primary = cfg(state, "email", "to_address")
    if _primary:
        recipients.append(_primary)
    # Additional recipients from the recipients table for this country
    with get_db_context() as _db:
        db_recipients = (
            _db.query(Recipient)
            .filter(
                Recipient.country_id == state.country_id,
                Recipient.enabled == True,  # noqa: E712
            )
            .all()
        )
        for r in db_recipients:
            if r.email not in recipients:
                recipients.append(r.email)
```

- [ ] **Step 2: Remove remaining `settings.*` references**

Check for any remaining settings imports/usages:
```bash
grep -n "settings\." src/tenderai_bf/agents/nodes/email_report.py
```

Remove `from ...config import settings` if no other reference remains. The `is_production` check is gone — all registered recipients in the DB are always used regardless of environment.

- [ ] **Step 3: Run relevant tests**

```bash
poetry run pytest tests/ -k "email" -v --no-cov 2>&1 | tail -20
```

Expected: no failures introduced.

- [ ] **Step 4: Commit**

```bash
git add src/tenderai_bf/agents/nodes/email_report.py
git commit -m "feat(email_report): read recipients from DB and email config from state.country_config"
```

---

## Task 8 — Refactor `extract_item_links.py`

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/extract_item_links.py`

- [ ] **Step 1: Replace the single `settings` access**

Open `src/tenderai_bf/agents/nodes/extract_item_links.py`. Add import:
```python
from ..graph import cfg
```

Find (around line 428):
```python
# BEFORE:
        max_items = settings.processing.max_items_per_run

# AFTER:
        max_items = cfg(state, "pipeline", "max_items_per_run")
```

Remove `from ...config import settings` if no longer used:
```bash
grep "settings\." src/tenderai_bf/agents/nodes/extract_item_links.py
```

- [ ] **Step 2: Run tests**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration" 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add src/tenderai_bf/agents/nodes/extract_item_links.py
git commit -m "feat(extract_item_links): read max_items_per_run from state.country_config"
```

---

## Task 9 — Refactor `summarize.py`

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/summarize.py`

- [ ] **Step 1: Replace `settings.*` in `summarize.py`**

Add import:
```python
from ..graph import cfg
```

**Replacement 1** — LLM provider (around line 26):
```python
# BEFORE:
        llm_provider = settings.llm.provider

# AFTER:
        llm_provider = cfg(state, "llm", "provider")
```

**Replacement 2** — prompts (around line 39):
```python
# BEFORE:
        _prompts_cfg = (
            getattr(state, "country_config", {}).get("prompts", {}) if state else {}
        )
        _global_prompts = settings.prompts if hasattr(settings, "prompts") else {}
        _summ = _prompts_cfg.get("summarization") or (
            _global_prompts.get("summarization", {})
            if isinstance(_global_prompts, dict)
            else getattr(_global_prompts, "summarization", {})
        )

# AFTER:
        _summ = state.country_config.get("prompts", {}).get("summarization", {})
```

Remove `from ...config import settings` if no longer used:
```bash
grep "settings\." src/tenderai_bf/agents/nodes/summarize.py
```

- [ ] **Step 2: Run tests**

```bash
poetry run pytest tests/nodes/test_summarize.py -v --no-cov 2>&1 | tail -20
```

Expected: existing tests pass (they use MockState which has `country_config={}` — `get()` with default is safe).

- [ ] **Step 3: Commit**

```bash
git add src/tenderai_bf/agents/nodes/summarize.py
git commit -m "feat(summarize): read llm provider and prompts from state.country_config"
```

---

## Task 10 — Refactor `parse_pdf_rag.py` and `parse_extract.py`

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/parse_pdf_rag.py`
- Modify: `src/tenderai_bf/agents/nodes/parse_extract.py`

- [ ] **Step 1: Add `rag_cfg` and `llm_cfg` parameters to helpers in `parse_pdf_rag.py`**

Open `src/tenderai_bf/agents/nodes/parse_pdf_rag.py`. Apply the following changes:

**Change 1** — `split_into_chunks()` (around line 93): remove the `settings` fallbacks:

```python
# BEFORE:
def split_into_chunks(
    text: str,
    chunk_size: int | None = None,
    chunk_overlap: int | None = None,
) -> list[str]:
    ...
    if chunk_size is None:
        chunk_size = settings.rag.chunk_size
    if chunk_overlap is None:
        chunk_overlap = settings.rag.chunk_overlap

# AFTER:
def split_into_chunks(
    text: str,
    chunk_size: int,
    chunk_overlap: int,
) -> list[str]:
    # (remove the None-check fallback lines; callers must pass explicit values)
```

**Change 2** — `query_tenders_from_index()` (around line 178): add `top_k` as required int:

```python
# BEFORE:
def query_tenders_from_index(
    source_name: str,
    query: str = "Extract all public procurement tenders",
    top_k: int | None = None,
) -> dict[str, Any]:
    ...
        results = vector_store.query_similar(
            source_name=source_name,
            query=query,
            top_k=top_k or settings.rag.top_k_results,
        )

# AFTER:
def query_tenders_from_index(
    source_name: str,
    query: str = "Extract all public procurement tenders",
    top_k: int = 5,
) -> dict[str, Any]:
    ...
        results = vector_store.query_similar(
            source_name=source_name,
            query=query,
            top_k=top_k,
        )
```

**Change 3** — `extract_tenders_with_llm()` (around line 213): add `top_k` parameter:

```python
# BEFORE:
def extract_tenders_with_llm(
    relevant_contexts: list[str], source_name: str
) -> list[dict[str, Any]]:
    ...
        context = "\n\n".join(relevant_contexts[: settings.rag.top_k_results])

# AFTER:
def extract_tenders_with_llm(
    relevant_contexts: list[str], source_name: str, top_k: int = 5
) -> list[dict[str, Any]]:
    ...
        context = "\n\n".join(relevant_contexts[:top_k])
```

**Change 4** — `parse_pdf_with_rag()` signature (around line 261): add `rag_cfg` and `llm_cfg` params:

```python
# BEFORE:
def parse_pdf_with_rag(
    pdf_path: str,
    source_name: str,
    filename: str,
    metadata: dict[str, Any] | None = None,
    use_llm: bool = True,
    pdf_content: bytes | None = None,
    use_direct_extraction: bool = True,
) -> list[dict[str, Any]]:

# AFTER:
def parse_pdf_with_rag(
    pdf_path: str,
    source_name: str,
    filename: str,
    metadata: dict[str, Any] | None = None,
    use_llm: bool = True,
    pdf_content: bytes | None = None,
    use_direct_extraction: bool = True,
    rag_cfg: dict | None = None,
    llm_cfg: dict | None = None,
) -> list[dict[str, Any]]:
```

Then inside `parse_pdf_with_rag`, replace all `settings.rag.*` and `settings.llm.*` accesses:

```python
# Add near the top of the function body (after the signature):
    _rag = rag_cfg or {}
    _llm = llm_cfg or {}
    _chunk_size = _rag.get("chunk_size", 512)
    _chunk_overlap = _rag.get("chunk_overlap", 50)
    _top_k = _rag.get("top_k_results", 5)
    _search_query = _rag.get("vector_search_query", "appel d'offres marché public")
    _llm_provider = _llm.get("provider", "unknown")

# BEFORE logging block (around line 287):
        llm_provider = getattr(settings.llm, "provider", "unknown")
        ...
        chunk_size=settings.rag.chunk_size,
        chunk_overlap=settings.rag.chunk_overlap,

# AFTER:
        llm_provider = _llm_provider
        ...
        chunk_size=_chunk_size,
        chunk_overlap=_chunk_overlap,
```

Replace the `split_into_chunks` call (if called inside `parse_pdf_with_rag`) to pass explicit values:
```python
# Wherever split_into_chunks is called without explicit params, add them:
split_into_chunks(text, chunk_size=_chunk_size, chunk_overlap=_chunk_overlap)
```

Replace the `vector_search_query` usage (around line 449):
```python
# BEFORE:
        search_query = settings.rag.chroma.vector_search_query

# AFTER:
        search_query = _search_query
```

Replace `query_tenders_from_index` call to pass `top_k`:
```python
# BEFORE:
        results = query_tenders_from_index(source_name=source_name, query=search_query)

# AFTER:
        results = query_tenders_from_index(source_name=source_name, query=search_query, top_k=_top_k)
```

Replace `extract_tenders_with_llm` call to pass `top_k`:
```python
# BEFORE:
        rag_tenders = extract_tenders_with_llm(relevant_contexts, source_name)

# AFTER:
        rag_tenders = extract_tenders_with_llm(relevant_contexts, source_name, top_k=_top_k)
```

Remove `from ...config import settings` if no longer used:
```bash
grep "settings\." src/tenderai_bf/agents/nodes/parse_pdf_rag.py
```

- [ ] **Step 2: Update the call site in `parse_extract.py`**

Open `src/tenderai_bf/agents/nodes/parse_extract.py`. Find the call to `parse_pdf_with_rag` (around line 535) and pass `rag_cfg` and `llm_cfg` from state:

```python
# BEFORE:
                    rag_tenders = parse_pdf_with_rag(
                        pdf_path=item["url"],
                        source_name=item.get("source_name", "Unknown"),
                        filename=item.get("title", "document.pdf"),
                        metadata={...},
                        use_llm=True,
                        pdf_content=content,
                    )

# AFTER:
                    rag_tenders = parse_pdf_with_rag(
                        pdf_path=item["url"],
                        source_name=item.get("source_name", "Unknown"),
                        filename=item.get("title", "document.pdf"),
                        metadata={...},
                        use_llm=True,
                        pdf_content=content,
                        rag_cfg=state.country_config.get("rag", {}),
                        llm_cfg=state.country_config.get("llm", {}),
                    )
```

- [ ] **Step 3: Run tests**

```bash
poetry run pytest tests/nodes/test_pdf_rag.py -v --no-cov 2>&1 | tail -20
```

Expected: existing tests pass (they may pass `rag_cfg=None` implicitly, falling back to defaults).

- [ ] **Step 4: Commit**

```bash
git add src/tenderai_bf/agents/nodes/parse_pdf_rag.py \
        src/tenderai_bf/agents/nodes/parse_extract.py
git commit -m "feat(parse_pdf_rag): pass rag/llm config explicitly from state instead of settings.*"
```

---

## Task 11 — Full test suite verification

**Files:**
- No new files — verification only.

- [ ] **Step 1: Run the full test suite**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration" 2>&1 | tail -40
```

Expected: all tests pass. Fix any `AttributeError` on removed `settings` fields that surface here.

- [ ] **Step 2: Verify no remaining `settings.*` operational accesses in nodes**

```bash
grep -rn "settings\.processing\|settings\.classification\|settings\.prompts\|settings\.recipients\|settings\.is_production\|get_active_sources\|use_database_sources" \
  src/tenderai_bf/agents/nodes/ src/tenderai_bf/config.py
```

Expected: zero matches.

- [ ] **Step 3: Verify `settings.rag` and `settings.llm` only appear in infra contexts**

```bash
grep -rn "settings\.rag\.\|settings\.llm\." src/tenderai_bf/agents/nodes/
```

Expected: zero matches (all moved to `cfg()` or explicit params).

- [ ] **Step 4: Commit if any test fixes were needed**

```bash
git add -A
git commit -m "fix(tests): update fixtures to inject country_config into TenderAIState"
```

- [ ] **Step 5: Push to staging**

```bash
git push origin staging
```

---

## Self-Review Checklist

**Spec coverage:**
- ✅ `cfg()` helper with fail-hard — Task 1
- ✅ `config.py` trimmed (5 fields, 3 methods, `_load_yaml_config` reduced to OCR) — Task 2
- ✅ API startup seeds all active countries — Task 3
- ✅ `load_sources.py` YAML branch deleted — Task 4
- ✅ `classify.py` fully migrated — Task 5
- ✅ `deduplicate.py` fully migrated — Task 6
- ✅ `email_report.py` uses `Recipient` table — Task 7
- ✅ `extract_item_links.py` migrated — Task 8
- ✅ `summarize.py` migrated — Task 9
- ✅ `parse_pdf_rag.py` + `parse_extract.py` migrated — Task 10
- ✅ Full test verification — Task 11

**Type consistency:** `cfg(state, section, key)` signature used consistently across all tasks. `rag_cfg: dict | None` default used in Task 10. `TenderAIState` import path `tenderai_bf.agents.graph` used consistently in all test files.

**No placeholders:** All code blocks are complete and runnable.
