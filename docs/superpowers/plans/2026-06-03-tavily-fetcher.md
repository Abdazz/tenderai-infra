# Tavily Fetcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Intégrer Tavily comme fetcher générique pour les nouvelles sources web de type `tavily_search` et `tavily_extract`, en court-circuitant `extract_item_links` et `fetch_items` pour injecter les résultats directement dans `parse_extract`.

**Architecture:** Les résultats Tavily transitent via `items_raw` avec un marqueur `parser_type` (`"tavily_search"` ou `"tavily_extract"`). `extract_item_links` reconnaît ces types et décompresse les résultats en `discovered_links` taggés `source: "tavily"`. `fetch_items` les passe en direct sans HTTP. `parse_extract` les normalise en Notice partiel. Pattern identique à UNGM.

**Tech Stack:** Python 3.11+, httpx (déjà utilisé partout), pydantic-settings, pytest + unittest.mock

---

## Fichiers touchés

| Action | Fichier |
|---|---|
| Créer | `src/tenderai_bf/agents/nodes/fetch_tavily.py` |
| Créer | `tests/nodes/test_fetch_tavily.py` |
| Modifier | `src/tenderai_bf/config.py` |
| Modifier | `src/tenderai_bf/agents/nodes/fetch_listings.py` |
| Modifier | `src/tenderai_bf/agents/nodes/extract_item_links.py` |
| Modifier | `src/tenderai_bf/agents/nodes/fetch_items.py` |
| Modifier | `src/tenderai_bf/agents/nodes/parse_extract.py` |
| Modifier | `tests/nodes/test_extraction.py` (extension) |

---

## Task 1 : TavilySettings dans config.py

**Files:**
- Modify: `src/tenderai_bf/config.py`

- [ ] **Step 1 : Écrire le test**

```python
# tests/test_utils.py — ajouter à la fin du fichier existant
def test_tavily_settings_defaults():
    from tenderai_bf.config import settings
    assert hasattr(settings, "tavily")
    assert settings.tavily.max_results == 10
    assert settings.tavily.search_depth == "basic"

def test_tavily_settings_api_key_from_env(monkeypatch):
    monkeypatch.setenv("TAVILY_API_KEY", "tvly-test-key")
    from importlib import reload
    import tenderai_bf.config as cfg_module
    reload(cfg_module)
    from tenderai_bf.config import TavilySettings
    s = TavilySettings()
    assert s.api_key.get_secret_value() == "tvly-test-key"
```

- [ ] **Step 2 : Lancer le test pour vérifier qu'il échoue**

```bash
poetry run pytest tests/test_utils.py::test_tavily_settings_defaults -v --no-cov
```
Résultat attendu : `FAILED` — `AttributeError: Settings has no attribute 'tavily'`

- [ ] **Step 3 : Ajouter TavilySettings dans config.py**

Insérer après la classe `GoogleSearchSettings` (ligne ~345) et avant `RAGSettings` :

```python
class TavilySettings(BaseSettings):
    """Tavily web search/extract API configuration."""

    api_key: SecretStr = Field(default="", validation_alias="TAVILY_API_KEY")
    max_results: int = Field(default=10)
    search_depth: str = Field(default="basic")  # "basic" | "advanced"

    model_config = SettingsConfigDict(case_sensitive=False)
```

Puis dans la classe `Settings`, après la ligne `google_search: GoogleSearchSettings = Field(...)` :

```python
    tavily: TavilySettings = Field(default_factory=TavilySettings)
```

- [ ] **Step 4 : Lancer le test pour vérifier qu'il passe**

```bash
poetry run pytest tests/test_utils.py::test_tavily_settings_defaults -v --no-cov
```
Résultat attendu : `PASSED`

- [ ] **Step 5 : Commit**

```bash
git add src/tenderai_bf/config.py tests/test_utils.py
git commit -m "feat(config): add TavilySettings with TAVILY_API_KEY"
```

---

## Task 2 : Créer fetch_tavily.py + tests

**Files:**
- Create: `src/tenderai_bf/agents/nodes/fetch_tavily.py`
- Create: `tests/nodes/test_fetch_tavily.py`

- [ ] **Step 1 : Écrire les tests (API mockée)**

Créer `tests/nodes/test_fetch_tavily.py` :

```python
"""Tests for fetch_tavily.py — Tavily API calls are always mocked."""

import asyncio
import json
import os
import sys
from datetime import datetime
from unittest.mock import AsyncMock, MagicMock, patch

os.environ.setdefault("TENDERAI_ENVIRONMENT", "test")
os.environ.setdefault("TENDERAI_DATABASE_URL", "sqlite:///test.db")
os.environ.setdefault("TENDERAI_JWT_SECRET", "test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx")
os.environ.setdefault("TENDERAI_ADMIN_PASSWORD", "test-admin-password-not-real")

sys.path.insert(0, "src")

SOURCE_SEARCH = {
    "name": "Test Tavily Search",
    "base_url": "https://example.com",
    "list_url": "https://example.com/tenders",
    "parser_type": "tavily_search",
    "patterns": {"queries": ["appel d'offres Sénégal informatique"]},
}

SOURCE_EXTRACT = {
    "name": "Test Tavily Extract",
    "base_url": "https://example.com",
    "list_url": "https://example.com/tenders",
    "parser_type": "tavily_extract",
    "patterns": {"include_raw_content": True, "extract_depth": "advanced"},
}

TAVILY_SEARCH_RESPONSE = {
    "query": "appel d'offres Sénégal informatique",
    "results": [
        {
            "title": "Appel d'offres réseau MEFP",
            "url": "https://example.com/tenders/123",
            "content": "Fourniture équipements réseau pour le MEFP...",
            "raw_content": None,
            "score": 0.91,
        },
        {
            "title": "Marché public SIG gouvernement",
            "url": "https://example.com/tenders/124",
            "content": "Développement système SIG...",
            "raw_content": None,
            "score": 0.85,
        },
    ],
    "response_time": 1.2,
}

TAVILY_EXTRACT_RESPONSE = {
    "results": [
        {
            "url": "https://example.com/tenders",
            "raw_content": "Liste des appels d'offres en cours...\n- Réseau MEFP\n- SIG gouvernement",
        }
    ],
    "failed_results": [],
}


def test_tavily_search_success():
    """fetch_tavily_search returns listings with parser_type=tavily_search."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = TAVILY_SEARCH_RESPONSE
    mock_response.raise_for_status = MagicMock()

    with patch("tenderai_bf.agents.nodes.fetch_tavily.settings") as mock_settings:
        mock_settings.tavily.api_key.get_secret_value.return_value = "tvly-test-key"
        mock_settings.tavily.max_results = 10
        mock_settings.tavily.search_depth = "basic"

        with patch("httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_client.__aenter__ = AsyncMock(return_value=mock_client)
            mock_client.__aexit__ = AsyncMock(return_value=False)
            mock_client.post = AsyncMock(return_value=mock_response)
            mock_client_cls.return_value = mock_client

            from tenderai_bf.agents.nodes.fetch_tavily import fetch_tavily_search

            result = asyncio.run(fetch_tavily_search(SOURCE_SEARCH, "run-001"))

    assert result["status"] == "success"
    assert result["parser_type"] == "tavily_search"
    listings = result["listings"]
    assert len(listings) == 2
    assert listings[0]["title"] == "Appel d'offres réseau MEFP"
    assert listings[0]["url"] == "https://example.com/tenders/123"


def test_tavily_extract_success():
    """fetch_tavily_extract returns listings with parser_type=tavily_extract."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = TAVILY_EXTRACT_RESPONSE
    mock_response.raise_for_status = MagicMock()

    with patch("tenderai_bf.agents.nodes.fetch_tavily.settings") as mock_settings:
        mock_settings.tavily.api_key.get_secret_value.return_value = "tvly-test-key"
        mock_settings.tavily.max_results = 10
        mock_settings.tavily.search_depth = "basic"

        with patch("httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_client.__aenter__ = AsyncMock(return_value=mock_client)
            mock_client.__aexit__ = AsyncMock(return_value=False)
            mock_client.post = AsyncMock(return_value=mock_response)
            mock_client_cls.return_value = mock_client

            from tenderai_bf.agents.nodes.fetch_tavily import fetch_tavily_extract

            result = asyncio.run(fetch_tavily_extract(SOURCE_EXTRACT, "run-001"))

    assert result["status"] == "success"
    assert result["parser_type"] == "tavily_extract"
    listings = result["listings"]
    assert len(listings) == 1
    assert listings[0]["url"] == "https://example.com/tenders"
    assert "appel" in listings[0].get("content", "").lower()


def test_tavily_missing_api_key():
    """Returns status=failed cleanly when TAVILY_API_KEY is not set."""
    with patch("tenderai_bf.agents.nodes.fetch_tavily.settings") as mock_settings:
        mock_settings.tavily.api_key.get_secret_value.return_value = ""

        from tenderai_bf.agents.nodes.fetch_tavily import fetch_tavily_search

        result = asyncio.run(fetch_tavily_search(SOURCE_SEARCH, "run-001"))

    assert result["status"] == "failed"
    assert "TAVILY_API_KEY" in result["error"]


def test_tavily_rate_limit_non_fatal():
    """HTTP 429 does not raise — returns status=failed with error message."""
    import httpx

    mock_response = MagicMock()
    mock_response.status_code = 429
    mock_response.raise_for_status.side_effect = httpx.HTTPStatusError(
        "429", request=MagicMock(), response=mock_response
    )

    with patch("tenderai_bf.agents.nodes.fetch_tavily.settings") as mock_settings:
        mock_settings.tavily.api_key.get_secret_value.return_value = "tvly-test-key"
        mock_settings.tavily.max_results = 10
        mock_settings.tavily.search_depth = "basic"

        with patch("httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_client.__aenter__ = AsyncMock(return_value=mock_client)
            mock_client.__aexit__ = AsyncMock(return_value=False)
            mock_client.post = AsyncMock(return_value=mock_response)
            mock_client_cls.return_value = mock_client

            from tenderai_bf.agents.nodes.fetch_tavily import fetch_tavily_search

            result = asyncio.run(fetch_tavily_search(SOURCE_SEARCH, "run-001"))

    assert result["status"] == "failed"
    assert "429" in result["error"]


def test_tavily_empty_results():
    """Empty results list → status=success but listings=[]."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {"query": "...", "results": [], "response_time": 0.5}
    mock_response.raise_for_status = MagicMock()

    with patch("tenderai_bf.agents.nodes.fetch_tavily.settings") as mock_settings:
        mock_settings.tavily.api_key.get_secret_value.return_value = "tvly-test-key"
        mock_settings.tavily.max_results = 10
        mock_settings.tavily.search_depth = "basic"

        with patch("httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_client.__aenter__ = AsyncMock(return_value=mock_client)
            mock_client.__aexit__ = AsyncMock(return_value=False)
            mock_client.post = AsyncMock(return_value=mock_response)
            mock_client_cls.return_value = mock_client

            from tenderai_bf.agents.nodes.fetch_tavily import fetch_tavily_search

            result = asyncio.run(fetch_tavily_search(SOURCE_SEARCH, "run-001"))

    assert result["status"] == "success"
    assert result["listings"] == []
```

- [ ] **Step 2 : Lancer les tests pour vérifier qu'ils échouent**

```bash
poetry run pytest tests/nodes/test_fetch_tavily.py -v --no-cov
```
Résultat attendu : `ERROR` — `ModuleNotFoundError: fetch_tavily`

- [ ] **Step 3 : Créer fetch_tavily.py**

Créer `src/tenderai_bf/agents/nodes/fetch_tavily.py` :

```python
"""Fetch listings using the Tavily web search/extract API.

Supports two parser_type values:
- tavily_search  : POST /search with configured queries (source without stable listing URL)
- tavily_extract : POST /extract with source.list_url (stable URL, content extracted by Tavily)
"""

import json
from datetime import datetime

import httpx

from ...config import settings
from ...logging import get_logger

logger = get_logger(__name__)

TAVILY_SEARCH_URL = "https://api.tavily.com/search"
TAVILY_EXTRACT_URL = "https://api.tavily.com/extract"


async def fetch_tavily_search(source: dict, run_id: str) -> dict:
    """Call Tavily /search for each query configured in source.patterns.queries."""
    source_name = source["name"]
    api_key = settings.tavily.api_key.get_secret_value()

    if not api_key:
        logger.warning("TAVILY_API_KEY not set — skipping", source=source_name, run_id=run_id)
        return {
            "source": source,
            "content": None,
            "url": source["list_url"],
            "status": "failed",
            "error": "TAVILY_API_KEY not set",
            "fetched_at": datetime.utcnow().isoformat(),
            "parser_type": "tavily_search",
        }

    queries = source.get("patterns", {}).get("queries", [])
    if not queries:
        logger.warning("No queries configured for tavily_search source", source=source_name, run_id=run_id)
        return {
            "source": source,
            "content": json.dumps([]),
            "listings": [],
            "url": source["list_url"],
            "status": "success",
            "parser_type": "tavily_search",
            "fetched_at": datetime.utcnow().isoformat(),
        }

    all_results: list[dict] = []
    seen_urls: set[str] = set()

    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0)) as client:
            for query in queries:
                payload = {
                    "api_key": api_key,
                    "query": query,
                    "search_depth": settings.tavily.search_depth,
                    "max_results": settings.tavily.max_results,
                    "include_raw_content": False,
                }
                response = await client.post(TAVILY_SEARCH_URL, json=payload)
                response.raise_for_status()
                data = response.json()

                for item in data.get("results", []):
                    url = item.get("url", "")
                    if url and url not in seen_urls:
                        seen_urls.add(url)
                        all_results.append(item)

                logger.info(
                    "Tavily search query completed",
                    query=query,
                    results=len(data.get("results", [])),
                    run_id=run_id,
                )

    except httpx.HTTPStatusError as e:
        error_msg = f"HTTP {e.response.status_code}"
        logger.error("Tavily search HTTP error", source=source_name, error=error_msg, run_id=run_id)
        return {
            "source": source,
            "content": None,
            "url": source["list_url"],
            "status": "failed",
            "error": error_msg,
            "fetched_at": datetime.utcnow().isoformat(),
            "parser_type": "tavily_search",
        }
    except Exception as e:
        logger.error("Tavily search failed", source=source_name, error=str(e), run_id=run_id)
        return {
            "source": source,
            "content": None,
            "url": source["list_url"],
            "status": "failed",
            "error": str(e),
            "fetched_at": datetime.utcnow().isoformat(),
            "parser_type": "tavily_search",
        }

    logger.info("Tavily search completed", source=source_name, total=len(all_results), run_id=run_id)

    return {
        "source": source,
        "content": json.dumps(all_results, ensure_ascii=False),
        "listings": all_results,
        "url": source["list_url"],
        "status": "success",
        "parser_type": "tavily_search",
        "fetched_at": datetime.utcnow().isoformat(),
    }


async def fetch_tavily_extract(source: dict, run_id: str) -> dict:
    """Call Tavily /extract with source.list_url to get structured page content."""
    source_name = source["name"]
    api_key = settings.tavily.api_key.get_secret_value()

    if not api_key:
        logger.warning("TAVILY_API_KEY not set — skipping", source=source_name, run_id=run_id)
        return {
            "source": source,
            "content": None,
            "url": source["list_url"],
            "status": "failed",
            "error": "TAVILY_API_KEY not set",
            "fetched_at": datetime.utcnow().isoformat(),
            "parser_type": "tavily_extract",
        }

    patterns = source.get("patterns", {})
    payload = {
        "api_key": api_key,
        "urls": [source["list_url"]],
        "include_raw_content": patterns.get("include_raw_content", True),
        "extract_depth": patterns.get("extract_depth", settings.tavily.search_depth),
    }

    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0)) as client:
            response = await client.post(TAVILY_EXTRACT_URL, json=payload)
            response.raise_for_status()
            data = response.json()

    except httpx.HTTPStatusError as e:
        error_msg = f"HTTP {e.response.status_code}"
        logger.error("Tavily extract HTTP error", source=source_name, error=error_msg, run_id=run_id)
        return {
            "source": source,
            "content": None,
            "url": source["list_url"],
            "status": "failed",
            "error": error_msg,
            "fetched_at": datetime.utcnow().isoformat(),
            "parser_type": "tavily_extract",
        }
    except Exception as e:
        logger.error("Tavily extract failed", source=source_name, error=str(e), run_id=run_id)
        return {
            "source": source,
            "content": None,
            "url": source["list_url"],
            "status": "failed",
            "error": str(e),
            "fetched_at": datetime.utcnow().isoformat(),
            "parser_type": "tavily_extract",
        }

    results = data.get("results", [])
    # Normalize: use raw_content as content for each result
    normalized = [
        {
            "url": r.get("url", source["list_url"]),
            "content": r.get("raw_content", ""),
            "title": source_name,
            "score": None,
        }
        for r in results
    ]

    logger.info("Tavily extract completed", source=source_name, results=len(normalized), run_id=run_id)

    return {
        "source": source,
        "content": json.dumps(normalized, ensure_ascii=False),
        "listings": normalized,
        "url": source["list_url"],
        "status": "success",
        "parser_type": "tavily_extract",
        "fetched_at": datetime.utcnow().isoformat(),
    }
```

- [ ] **Step 4 : Lancer les tests pour vérifier qu'ils passent**

```bash
poetry run pytest tests/nodes/test_fetch_tavily.py -v --no-cov
```
Résultat attendu : `5 passed`

- [ ] **Step 5 : Commit**

```bash
git add src/tenderai_bf/agents/nodes/fetch_tavily.py tests/nodes/test_fetch_tavily.py
git commit -m "feat(fetch_tavily): add Tavily search and extract fetcher"
```

---

## Task 3 : Wirer fetch_listings.py

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/fetch_listings.py`

- [ ] **Step 1 : Ajouter l'import et le branchement dans `fetch_single_listing`**

Dans `fetch_single_listing`, trouver le bloc `# Google Custom Search source` (vers ligne 189) et insérer avant lui :

```python
    # Tavily web sources
    if parser_type in ("tavily_search", "tavily_extract"):
        from .fetch_tavily import fetch_tavily_extract, fetch_tavily_search

        if parser_type == "tavily_search":
            return await fetch_tavily_search(source, run_id)
        return await fetch_tavily_extract(source, run_id)
```

- [ ] **Step 2 : Vérifier que les tests existants passent toujours**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Résultat attendu : aucune régression.

- [ ] **Step 3 : Commit**

```bash
git add src/tenderai_bf/agents/nodes/fetch_listings.py
git commit -m "feat(fetch_listings): dispatch tavily_search and tavily_extract parser_types"
```

---

## Task 4 : Wirer extract_item_links.py

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/extract_item_links.py`

- [ ] **Step 1 : Ajouter le branchement Tavily dans la boucle `for item in state.items_raw`**

Trouver le bloc `elif parser_type == "google_search":` (vers ligne 317) et insérer après sa clause `except` :

```python
                elif parser_type in ("tavily_search", "tavily_extract"):
                    import json as _json

                    try:
                        results = (
                            _json.loads(content)
                            if isinstance(content, str)
                            else item.get("listings", [])
                        )
                        for result in results:
                            result["source"] = "tavily"
                            result["parser_type"] = parser_type
                        links = results
                        logger.info(
                            f"Tavily: {len(results)} results extracted",
                            source_name=source_name,
                            run_id=state.run_id,
                        )
                    except Exception as e:
                        logger.error(f"Failed to parse Tavily results: {e}")
                        links = []
```

- [ ] **Step 2 : Vérifier que les tests existants passent toujours**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Résultat attendu : aucune régression.

- [ ] **Step 3 : Commit**

```bash
git add src/tenderai_bf/agents/nodes/extract_item_links.py
git commit -m "feat(extract_item_links): unpack Tavily results into discovered_links"
```

---

## Task 5 : Wirer fetch_items.py

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/fetch_items.py`

- [ ] **Step 1 : Ajouter la détection des items Tavily dans `fetch_items_node`**

Dans `fetch_items_node`, trouver le bloc `for link in state.discovered_links:` (vers ligne 199). Ajouter un nouveau bucket `tavily_items = []` avec les autres déclarations, puis dans la boucle de dispatch, insérer la condition Tavily après la condition UNGM :

```python
        tavily_items = []  # ajouter avec quotidien_pdfs, rag_pdfs, etc.

        # dans la boucle for link in state.discovered_links:
            elif isinstance(link, dict) and link.get("source") == "tavily":
                tavily_items.append(link)
```

Puis ajouter le bloc de traitement après le bloc UNGM (vers ligne 254) :

```python
        # Process Tavily items (fully fetched by Tavily API — pass through)
        for link in tavily_items:
            items.append(
                {
                    "url": link.get("url", ""),
                    "content": link.get("content", link.get("raw_content", "")),
                    "status": "success",
                    "fetched_at": datetime.utcnow().isoformat(),
                    "parser_type": link.get("parser_type", "tavily_search"),
                    "source": "tavily",
                    "title": link.get("title", ""),
                    "score": link.get("score"),
                }
            )
        if tavily_items:
            logger.info(
                "Tavily items passed through (no detail fetch needed)",
                count=len(tavily_items),
                run_id=state.run_id,
            )
```

- [ ] **Step 2 : Vérifier que les tests existants passent toujours**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Résultat attendu : aucune régression.

- [ ] **Step 3 : Commit**

```bash
git add src/tenderai_bf/agents/nodes/fetch_items.py
git commit -m "feat(fetch_items): pass through Tavily items without HTTP fetch"
```

---

## Task 6 : Wirer parse_extract.py + tests

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/parse_extract.py`
- Modify: `tests/nodes/test_extraction.py`

- [ ] **Step 1 : Écrire le test**

Dans `tests/nodes/test_extraction.py`, ajouter :

```python
def test_parse_extract_tavily_search_item():
    """Tavily search item is normalized into a Notice-compatible dict."""
    from unittest.mock import MagicMock

    from tenderai_bf.agents.nodes.parse_extract import parse_extract_node

    state = MagicMock()
    state.error_occurred = False
    state.run_id = "run-test"
    state.country_config = {"rag": {}, "llm": {}}
    state.items_raw = [
        {
            "url": "https://example.com/tenders/123",
            "content": "Fourniture équipements réseau pour le MEFP Sénégal...",
            "status": "success",
            "parser_type": "tavily_search",
            "source": "tavily",
            "title": "Appel d'offres réseau MEFP",
            "score": 0.91,
            "fetched_at": "2026-06-03T10:00:00",
        }
    ]
    state.items_parsed = []
    state.update_stats = MagicMock()

    result = parse_extract_node(state)

    assert len(result.items_parsed) == 1
    item = result.items_parsed[0]
    assert item["title"] == "Appel d'offres réseau MEFP"
    assert item["url"] == "https://example.com/tenders/123"
    assert "réseau" in item["description"]
    assert item["source"] == "tavily"


def test_parse_extract_tavily_extract_item():
    """Tavily extract item (no title) uses source name as title."""
    from unittest.mock import MagicMock

    from tenderai_bf.agents.nodes.parse_extract import parse_extract_node

    state = MagicMock()
    state.error_occurred = False
    state.run_id = "run-test"
    state.country_config = {"rag": {}, "llm": {}}
    state.items_raw = [
        {
            "url": "https://gov.example.com/tenders",
            "content": "Liste des marchés publics en cours...",
            "status": "success",
            "parser_type": "tavily_extract",
            "source": "tavily",
            "title": "Portail marchés Sénégal",
            "score": None,
            "fetched_at": "2026-06-03T10:00:00",
        }
    ]
    state.items_parsed = []
    state.update_stats = MagicMock()

    result = parse_extract_node(state)

    assert len(result.items_parsed) == 1
    item = result.items_parsed[0]
    assert item["source"] == "tavily"
    assert item["url"] == "https://gov.example.com/tenders"
```

- [ ] **Step 2 : Lancer les tests pour vérifier qu'ils échouent**

```bash
poetry run pytest tests/nodes/test_extraction.py::test_parse_extract_tavily_search_item tests/nodes/test_extraction.py::test_parse_extract_tavily_extract_item -v --no-cov
```
Résultat attendu : `FAILED` — les items Tavily tombent dans la branche HTML et échouent.

- [ ] **Step 3 : Ajouter la branche Tavily dans `parse_extract_node`**

Dans `parse_extract.py`, trouver le bloc `# Handle UNGM listings` (vers ligne 562). Insérer une nouvelle branche **avant** `# Handle quotidien PDFs` (vers ligne 589) :

```python
            # Handle Tavily results (search or extract — already structured)
            elif parser_type in ("tavily_search", "tavily_extract"):
                import uuid as _uuid

                content_text = item.get("content") or ""
                if isinstance(content_text, bytes):
                    content_text = content_text.decode("utf-8", errors="replace")

                parsed_items.append(
                    {
                        "id": str(_uuid.uuid4()),
                        "url": item["url"],
                        "content_hash": content_hash,
                        "title": item.get("title", ""),
                        "tender_object": item.get("title", ""),
                        "description": content_text[:2000],
                        "raw_text": content_text,
                        "reference": "",
                        "ref_no": "",
                        "entity": "",
                        "category": "Autre",
                        "source": "tavily",
                        "score": item.get("score"),
                    }
                )
                continue
```

- [ ] **Step 4 : Lancer les tests pour vérifier qu'ils passent**

```bash
poetry run pytest tests/nodes/test_extraction.py::test_parse_extract_tavily_search_item tests/nodes/test_extraction.py::test_parse_extract_tavily_extract_item -v --no-cov
```
Résultat attendu : `2 passed`

- [ ] **Step 5 : Lancer la suite complète pour vérifier l'absence de régression**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Résultat attendu : aucune régression.

- [ ] **Step 6 : Commit**

```bash
git add src/tenderai_bf/agents/nodes/parse_extract.py tests/nodes/test_extraction.py
git commit -m "feat(parse_extract): normalize Tavily search/extract items to Notice partial"
```

---

## Task 7 : Vérification finale

- [ ] **Step 1 : Lancer la suite complète avec couverture**

```bash
poetry run pytest tests/ -v -m "not slow and not integration"
```
Résultat attendu : tous les tests passent, couverture ≥ 80 %.

- [ ] **Step 2 : Lint**

```bash
make lint
```
Résultat attendu : aucune erreur ruff.

- [ ] **Step 3 : Mettre à jour IMPROVEMENTS.md**

Dans `IMPROVEMENTS.md`, changer le statut de l'item #4 :

```markdown
| 4 | [Intégration Tavily comme parser web](#4-intégration-tavily-comme-parser-web) | ✅ `done` | Remplace les fetchers custom pour nouvelles sources |
```

Et dans la section détails, changer `**Status:** \`planned\`` en `**Status:** \`done\``.

- [ ] **Step 4 : Commit final**

```bash
git add IMPROVEMENTS.md
git commit -m "docs: mark Tavily fetcher integration as done"
```
