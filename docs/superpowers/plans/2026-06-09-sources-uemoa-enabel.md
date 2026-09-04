# Sources UEMOA + Enabel : html-tender & crawl4ai Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Intégrer les sources UEMOA et Enabel Burkina Faso via deux nouveaux parser types génériques (`html-tender` config-driven et `crawl4ai` LLM-based) switchables sans modification de code.

**Architecture:** Deux nouveaux fetchers enregistrés dans le dispatcher `fetch_listings.py`. Chaque fetcher retourne une liste de `listings` pré-extraits (pattern UNGM). Les données traversent `extract_item_links → fetch_items → parse_extract` via un handler commun. Toute la config (sélecteurs, pagination, SSL) est dans `settings.yaml → DB sources.patterns`.

**Tech Stack:** Python 3.11, httpx, selectolax, crawl4ai (optionnel), Pydantic, SQLAlchemy text(), pytest + unittest.mock

---

## Fichiers

| Action | Chemin |
|---|---|
| Créer | `src/tenderai_bf/agents/nodes/fetch_html_tender.py` |
| Créer | `src/tenderai_bf/agents/nodes/fetch_crawl4ai.py` |
| Créer | `tests/nodes/test_fetch_html_tender.py` |
| Créer | `tests/nodes/test_fetch_crawl4ai.py` |
| Modifier | `src/tenderai_bf/cli.py` (seed_sources +patterns) |
| Modifier | `src/tenderai_bf/agents/nodes/fetch_listings.py` (+2 dispatch) |
| Modifier | `src/tenderai_bf/agents/nodes/extract_item_links.py` (+2 handlers) |
| Modifier | `src/tenderai_bf/agents/nodes/fetch_items.py` (+routing) |
| Modifier | `src/tenderai_bf/agents/nodes/parse_extract.py` (+1 handler commun) |
| Modifier | `settings.yaml` (+UEMOA, +Enabel) |
| Modifier | `pyproject.toml` (+crawl4ai optional) |
| Modifier | `tests/test_smoke.py` (+vérification seed patterns) |

---

## Task 1 : Corriger `seed_sources` pour persister `patterns`

**Fichiers :**
- Modifier : `src/tenderai_bf/cli.py` (autour des lignes 460–498)
- Test : `tests/test_smoke.py`

- [ ] **Étape 1 : Écrire le test qui échoue**

Ajouter dans `tests/test_smoke.py` :

```python
def test_seed_sources_persists_patterns(tmp_path, monkeypatch):
    """seed_sources doit sauvegarder le champ patterns en DB."""
    import json
    from unittest.mock import MagicMock, call, patch

    yaml_content = """
sources:
  - name: "Test Source Patterns"
    list_url: "https://example.com/tenders"
    parser: "html-tender"
    enabled: true
    patterns:
      card_selector: "div.card"
      title_selector: "h3"
      entity: "TestOrg"
"""
    yaml_file = tmp_path / "settings.yaml"
    yaml_file.write_text(yaml_content)

    captured_inserts = []

    mock_conn = MagicMock()
    def fake_execute(stmt, params=None):
        if params:
            captured_inserts.append(params)
        row = MagicMock()
        row.__iter__ = MagicMock(return_value=iter([]))
        mock_result = MagicMock()
        mock_result.fetchone.return_value = None
        return mock_result
    mock_conn.execute = fake_execute
    mock_conn.__enter__ = MagicMock(return_value=mock_conn)
    mock_conn.__exit__ = MagicMock(return_value=False)

    mock_engine = MagicMock()
    mock_engine.connect.return_value = mock_conn

    with patch("tenderai_bf.cli.Path") as mock_path_cls, \
         patch("tenderai_bf.cli.get_engine", return_value=mock_engine):
        mock_path_cls.return_value = yaml_file
        from click.testing import CliRunner
        from tenderai_bf.cli import main
        runner = CliRunner()
        result = runner.invoke(main, ["seed-sources"])

    insert_params = [p for p in captured_inserts if "card_selector" in str(p.get("patterns", ""))]
    assert len(insert_params) == 1, "patterns should be persisted in INSERT"
    patterns = insert_params[0]["patterns"]
    if isinstance(patterns, str):
        patterns = json.loads(patterns)
    assert patterns["card_selector"] == "div.card"
    assert patterns["entity"] == "TestOrg"
```

- [ ] **Étape 2 : Vérifier que le test échoue**

```bash
cd /home/yulcom/web/tender-ai
poetry run pytest tests/test_smoke.py::test_seed_sources_persists_patterns -v --no-cov
```
Attendu : FAIL (patterns non persistés actuellement)

- [ ] **Étape 3 : Modifier `seed_sources` dans `cli.py`**

Localiser la fonction `seed_sources` (~ligne 407). Ajouter la lecture et sérialisation de `patterns`, puis l'inclure dans INSERT et UPDATE.

Remplacer le bloc `for source in sources:` (lecture des champs) par :

```python
for source in sources:
    name = source.get("name", "").strip()
    list_url = source.get("list_url", "").strip()
    parser_type = source.get("parser", source.get("parser_type", "html"))
    rate_limit = source.get("rate_limit", "10/m")
    enabled = source.get("enabled", True)
    patterns_raw = source.get("patterns")
    patterns_json = json.dumps(patterns_raw) if patterns_raw else None
```

Ajouter `import json` en tête du fichier si absent (vérifier).

Remplacer le UPDATE SQL :
```python
conn.execute(
    text(
        "UPDATE sources SET base_url=:base_url, list_url=:list_url, "
        "parser_type=:parser_type, rate_limit=:rate_limit, enabled=:enabled, "
        "patterns=:patterns, updated_at=NOW() WHERE name=:name"
    ),
    {
        "name": name,
        "base_url": base_url,
        "list_url": list_url,
        "parser_type": parser_type,
        "rate_limit": rate_limit,
        "enabled": enabled,
        "patterns": patterns_json,
    },
)
```

Remplacer le INSERT SQL :
```python
conn.execute(
    text(
        "INSERT INTO sources (name, base_url, list_url, parser_type, "
        "rate_limit, enabled, patterns, created_at, updated_at) "
        "VALUES (:name, :base_url, :list_url, :parser_type, "
        ":rate_limit, :enabled, :patterns, NOW(), NOW())"
    ),
    {
        "name": name,
        "base_url": base_url,
        "list_url": list_url,
        "parser_type": parser_type,
        "rate_limit": rate_limit,
        "enabled": enabled,
        "patterns": patterns_json,
    },
)
```

- [ ] **Étape 4 : Vérifier que le test passe**

```bash
poetry run pytest tests/test_smoke.py::test_seed_sources_persists_patterns -v --no-cov
```
Attendu : PASS

- [ ] **Étape 5 : Commit**

```bash
git add src/tenderai_bf/cli.py tests/test_smoke.py
git commit -m "fix(cli): seed_sources persiste le champ patterns en DB"
```

---

## Task 2 : Créer `fetch_html_tender.py`

**Fichiers :**
- Créer : `src/tenderai_bf/agents/nodes/fetch_html_tender.py`
- Créer : `tests/nodes/test_fetch_html_tender.py`

- [ ] **Étape 1 : Écrire les tests**

Créer `tests/nodes/test_fetch_html_tender.py` :

```python
"""Tests for fetch_html_tender — HTTP calls always mocked."""

import asyncio
import os
import sys
from unittest.mock import AsyncMock, MagicMock, patch

os.environ.setdefault("TENDERAI_ENVIRONMENT", "test")
os.environ.setdefault("TENDERAI_DATABASE_URL", "sqlite:///test.db")
os.environ.setdefault("TENDERAI_JWT_SECRET", "test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx")
os.environ.setdefault("TENDERAI_ADMIN_PASSWORD", "test-admin-password-not-real")
sys.path.insert(0, "src")

UEMOA_HTML = """
<html><body>
<div class="swiper-slide">
  <div class="news-box">
    <div class="new-txt">
      <p class="pb-2">Appel d'offres acquisition matériel informatique CUEMOA</p>
      <small><time datetime="2026-07-15T10:00:00Z">15/07/2026 - 10:00</time></small>
    </div>
    <div class="news-box-f">
      <a href="/sites/default/files/opportunite_affaire/AO_materiel_info.pdf">Télécharger</a>
    </div>
  </div>
</div>
<div class="swiper-slide">
  <div class="news-box">
    <div class="new-txt">
      <p class="pb-2">Fourniture véhicules SUV UEMOA</p>
      <small><time datetime="2026-08-01T10:00:00Z">01/08/2026 - 10:00</time></small>
    </div>
    <div class="news-box-f">
      <a href="/sites/default/files/opportunite_affaire/AO_vehicules.pdf">Télécharger</a>
    </div>
  </div>
</div>
</body></html>
"""

ENABEL_HTML = """
<html><body>
<div class="card--news card--tenders" data-open="false">
  <div class="news__botton">
    <p class="h5"><span>BFA23004-10487 &#8211; Fourniture d'équipements hydromécaniques ONEA Koupéla.</span></p>
    <p><strong>Pays : </strong> Burkina Faso</p>
    <p><strong>Date de clôture : </strong> 30 June 2026 12:00</p>
    <div class="hidden__card">
      <p><strong>Status :</strong> Ouvert</p>
    </div>
  </div>
</div>
</body></html>
"""

SOURCE_UEMOA = {
    "name": "UEMOA - Appels d'offres",
    "list_url": "https://www.uemoa.int/appel-d-offre",
    "parser_type": "html-tender",
    "patterns": {
        "ssl_verify": False,
        "card_selector": "div.swiper-slide div.news-box",
        "title_selector": "div.new-txt p",
        "deadline_selector": "time",
        "deadline_attribute": "datetime",
        "pdf_selector": "a[href*='opportunite_affaire']",
        "entity": "UEMOA",
        "location": "Zone UEMOA",
        "max_pages": 1,
    },
}

SOURCE_ENABEL = {
    "name": "Enabel - Marchés publics Burkina Faso",
    "list_url": "https://www.enabel.be/fr/marches-publics/?in_country=1726&is_status=0",
    "parser_type": "html-tender",
    "patterns": {
        "card_selector": "div.card--news.card--tenders",
        "title_selector": "p.h5 span",
        "deadline_selector": "p",
        "deadline_text_prefix": "Date de clôture",
        "entity": "Enabel",
        "location": "Burkina Faso",
        "max_pages": 1,
    },
}


def _make_mock_response(html: str, status: int = 200):
    resp = MagicMock()
    resp.status_code = status
    resp.text = html
    resp.raise_for_status = MagicMock()
    return resp


def _run(coro):
    return asyncio.get_event_loop().run_until_complete(coro)


def test_uemoa_extracts_two_items():
    """UEMOA source: extrait titre, deadline ISO et URL PDF pour chaque slide."""
    from tenderai_bf.agents.nodes.fetch_html_tender import fetch_html_tender

    mock_resp = _make_mock_response(UEMOA_HTML)
    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)
    mock_client.get = AsyncMock(return_value=mock_resp)

    with patch("tenderai_bf.agents.nodes.fetch_html_tender.httpx.AsyncClient", return_value=mock_client):
        result = _run(fetch_html_tender(SOURCE_UEMOA, "run-test"))

    assert result["status"] == "success"
    assert result["parser_type"] == "html-tender"
    listings = result["listings"]
    assert len(listings) == 2
    assert "matériel informatique" in listings[0]["title"]
    assert listings[0]["deadline"] == "2026-07-15T10:00:00Z"
    assert "AO_materiel_info.pdf" in listings[0]["url"]
    assert listings[0]["entity"] == "UEMOA"
    assert listings[0]["location"] == "Zone UEMOA"


def test_enabel_extracts_reference_and_deadline():
    """Enabel source: extrait référence depuis titre et deadline via deadline_text_prefix."""
    from tenderai_bf.agents.nodes.fetch_html_tender import fetch_html_tender

    mock_resp = _make_mock_response(ENABEL_HTML)
    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)
    mock_client.get = AsyncMock(return_value=mock_resp)

    with patch("tenderai_bf.agents.nodes.fetch_html_tender.httpx.AsyncClient", return_value=mock_client):
        result = _run(fetch_html_tender(SOURCE_ENABEL, "run-test"))

    assert result["status"] == "success"
    listings = result["listings"]
    assert len(listings) == 1
    assert "BFA23004-10487" in listings[0]["reference"]
    assert "30 June 2026" in listings[0]["deadline"]
    assert listings[0]["entity"] == "Enabel"


def test_ssl_verify_false_passed_to_client():
    """ssl_verify=false dans patterns doit être transmis au AsyncClient."""
    from tenderai_bf.agents.nodes.fetch_html_tender import fetch_html_tender

    mock_resp = _make_mock_response(UEMOA_HTML)
    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)
    mock_client.get = AsyncMock(return_value=mock_resp)

    with patch("tenderai_bf.agents.nodes.fetch_html_tender.httpx.AsyncClient", return_value=mock_client) as mock_cls:
        _run(fetch_html_tender(SOURCE_UEMOA, "run-test"))
        call_kwargs = mock_cls.call_args
        assert call_kwargs.kwargs.get("verify") is False


def test_empty_page_returns_failed():
    """Page sans cards → status failed."""
    from tenderai_bf.agents.nodes.fetch_html_tender import fetch_html_tender

    mock_resp = _make_mock_response("<html><body></body></html>")
    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)
    mock_client.get = AsyncMock(return_value=mock_resp)

    with patch("tenderai_bf.agents.nodes.fetch_html_tender.httpx.AsyncClient", return_value=mock_client):
        result = _run(fetch_html_tender(SOURCE_UEMOA, "run-test"))

    assert result["status"] == "failed"
    assert result["listings"] == []
```

- [ ] **Étape 2 : Vérifier que les tests échouent**

```bash
poetry run pytest tests/nodes/test_fetch_html_tender.py -v --no-cov
```
Attendu : ImportError / ModuleNotFoundError (fichier non créé)

- [ ] **Étape 3 : Implémenter `fetch_html_tender.py`**

Créer `src/tenderai_bf/agents/nodes/fetch_html_tender.py` :

```python
"""Config-driven HTML tender fetcher.

Tous les paramètres d'extraction sont lus depuis source["patterns"] :
  card_selector, title_selector, deadline_selector, deadline_attribute,
  deadline_text_prefix, pdf_selector, entity, location,
  ssl_verify, max_pages, pagination_url
"""

import re
from urllib.parse import urljoin

import httpx
from selectolax.parser import HTMLParser

from ...logging import get_logger

logger = get_logger(__name__)

_HEADERS = {
    "User-Agent": "TenderAI-BF/1.0 (+https://yulcom.com/tenderai)",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "fr-FR,fr;q=0.9,en;q=0.8",
}


def _txt(node) -> str:
    if node is None:
        return ""
    return re.sub(r"\s+", " ", node.text(strip=True)).strip()


async def fetch_html_tender(source: dict, run_id: str) -> dict:
    """Fetch tender listings from a config-driven HTML source."""
    source_name = source["name"]
    list_url = source["list_url"]
    patterns = source.get("patterns") or {}

    ssl_verify = patterns.get("ssl_verify", True)
    max_pages = int(patterns.get("max_pages", 1))
    pagination_url = patterns.get("pagination_url")

    urls = [list_url]
    if max_pages > 1 and pagination_url:
        for page in range(2, max_pages + 1):
            urls.append(pagination_url.format(page=page))

    listings: list[dict] = []

    async with httpx.AsyncClient(
        verify=ssl_verify,
        follow_redirects=True,
        timeout=httpx.Timeout(30.0),
        headers=_HEADERS,
    ) as client:
        for url in urls:
            try:
                resp = await client.get(url)
                resp.raise_for_status()
                listings.extend(_extract_cards(resp.text, url, patterns, source_name))
            except Exception as e:
                logger.warning(
                    "html-tender page fetch failed",
                    url=url,
                    error=str(e),
                    run_id=run_id,
                )

    logger.info(
        "html-tender fetch complete",
        source=source_name,
        listings=len(listings),
        run_id=run_id,
    )

    return {
        "source": source,
        "content": None,
        "listings": listings,
        "url": list_url,
        "status": "success" if listings else "failed",
        "parser_type": "html-tender",
        "fetched_at": _now(),
    }


def _extract_cards(html: str, page_url: str, patterns: dict, source_name: str) -> list[dict]:
    """Extraire les blocs tender d'une page HTML selon les patterns configurés."""
    p = HTMLParser(html)

    card_sel = patterns.get("card_selector", "article")
    title_sel = patterns.get("title_selector", "h1,h2,h3,p")
    deadline_sel = patterns.get("deadline_selector", "time")
    deadline_attr = patterns.get("deadline_attribute")
    deadline_prefix = patterns.get("deadline_text_prefix")
    pdf_sel = patterns.get("pdf_selector")
    fixed_entity = patterns.get("entity", "")
    fixed_location = patterns.get("location", "")

    items = []
    for card in p.css(card_sel):
        # --- Titre ---
        title_node = card.css_first(title_sel)
        title = _txt(title_node)
        if not title:
            continue

        # --- Deadline ---
        deadline = ""
        if deadline_prefix:
            for node in card.css(deadline_sel):
                t = _txt(node)
                if deadline_prefix.lower() in t.lower():
                    parts = t.split(":", 1)
                    deadline = parts[1].strip() if len(parts) > 1 else t
                    break
        else:
            d_node = card.css_first(deadline_sel)
            if d_node:
                deadline = d_node.attributes.get(deadline_attr, "") if deadline_attr else _txt(d_node)

        # --- URL / PDF ---
        item_url = page_url
        if pdf_sel:
            pdf_node = card.css_first(pdf_sel)
            if pdf_node:
                href = pdf_node.attributes.get("href", "")
                if href:
                    item_url = urljoin(page_url, href)

        # --- Référence (extraite du titre si présente) ---
        ref_match = re.search(r"\b([A-Z]{2,}\d{4,}[-\d/]*)\b", title)
        reference = ref_match.group(1) if ref_match else ""

        items.append({
            "url": item_url,
            "title": title,
            "tender_object": title,
            "reference": reference,
            "ref_no": reference,
            "entity": fixed_entity,
            "location": fixed_location,
            "deadline": deadline,
            "description": title,
            "category": "Autre",
            "type": "appel_offres",
            "source": source_name,
            "parser_type": "html-tender",
        })

    return items


def _now() -> str:
    from datetime import datetime
    return datetime.utcnow().isoformat()
```

- [ ] **Étape 4 : Vérifier que les tests passent**

```bash
poetry run pytest tests/nodes/test_fetch_html_tender.py -v --no-cov
```
Attendu : 4 PASS

- [ ] **Étape 5 : Commit**

```bash
git add src/tenderai_bf/agents/nodes/fetch_html_tender.py tests/nodes/test_fetch_html_tender.py
git commit -m "feat(fetch): ajouter fetch_html_tender — parser config-driven selectolax"
```

---

## Task 3 : Créer `fetch_crawl4ai.py`

**Fichiers :**
- Créer : `src/tenderai_bf/agents/nodes/fetch_crawl4ai.py`
- Créer : `tests/nodes/test_fetch_crawl4ai.py`

- [ ] **Étape 1 : Écrire les tests**

Créer `tests/nodes/test_fetch_crawl4ai.py` :

```python
"""Tests for fetch_crawl4ai — AsyncWebCrawler always mocked."""

import asyncio
import json
import os
import sys
from unittest.mock import AsyncMock, MagicMock, patch

os.environ.setdefault("TENDERAI_ENVIRONMENT", "test")
os.environ.setdefault("TENDERAI_DATABASE_URL", "sqlite:///test.db")
os.environ.setdefault("TENDERAI_JWT_SECRET", "test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx")
os.environ.setdefault("TENDERAI_ADMIN_PASSWORD", "test-admin-password-not-real")
sys.path.insert(0, "src")

SOURCE = {
    "name": "UEMOA - Appels d'offres",
    "list_url": "https://www.uemoa.int/appel-d-offre",
    "parser_type": "crawl4ai",
    "patterns": {
        "ssl_verify": False,
        "entity": "UEMOA",
        "max_pages": 1,
    },
}

EXTRACTED_ITEMS = [
    {
        "title": "Appel d'offres matériel informatique CUEMOA",
        "reference": "AO-012-2026",
        "deadline": "2026-07-15",
        "entity": "UEMOA",
        "country": "Zone UEMOA",
        "description": "Acquisition matériel informatique",
        "document_url": "https://www.uemoa.int/sites/default/files/opportunite_affaire/AO_info.pdf",
    }
]


def _run(coro):
    return asyncio.get_event_loop().run_until_complete(coro)


def _make_crawler_mock(extracted_content):
    mock_result = MagicMock()
    mock_result.extracted_content = json.dumps(extracted_content)

    mock_crawler = AsyncMock()
    mock_crawler.__aenter__ = AsyncMock(return_value=mock_crawler)
    mock_crawler.__aexit__ = AsyncMock(return_value=False)
    mock_crawler.arun = AsyncMock(return_value=mock_result)
    return mock_crawler


def test_crawl4ai_extracts_listings():
    """crawl4ai fetcher retourne listings avec champs standards."""
    mock_crawler = _make_crawler_mock(EXTRACTED_ITEMS)

    with patch("tenderai_bf.agents.nodes.fetch_crawl4ai.AsyncWebCrawler", return_value=mock_crawler), \
         patch("tenderai_bf.agents.nodes.fetch_crawl4ai.LLMExtractionStrategy"), \
         patch("tenderai_bf.agents.nodes.fetch_crawl4ai._get_llm_config", return_value=("groq/llama-3.3-70b-versatile", "test-key")):
        result = _run(__import__("tenderai_bf.agents.nodes.fetch_crawl4ai", fromlist=["fetch_crawl4ai"]).fetch_crawl4ai(SOURCE, "run-test"))

    assert result["status"] == "success"
    assert result["parser_type"] == "crawl4ai"
    listings = result["listings"]
    assert len(listings) == 1
    assert listings[0]["title"] == "Appel d'offres matériel informatique CUEMOA"
    assert listings[0]["reference"] == "AO-012-2026"
    assert listings[0]["deadline"] == "2026-07-15"
    assert listings[0]["parser_type"] == "crawl4ai"


def test_crawl4ai_not_installed_returns_failed():
    """Si crawl4ai n'est pas installé → status failed avec message clair."""
    with patch.dict("sys.modules", {"crawl4ai": None, "crawl4ai.extraction_strategy": None}):
        import importlib
        import tenderai_bf.agents.nodes.fetch_crawl4ai as mod
        importlib.reload(mod)

        result = _run(mod.fetch_crawl4ai(SOURCE, "run-test"))
        assert result["status"] == "failed"
        assert "crawl4ai" in result["error"].lower()


def test_crawl4ai_empty_extraction_returns_failed():
    """extracted_content vide → status failed."""
    mock_result = MagicMock()
    mock_result.extracted_content = None

    mock_crawler = AsyncMock()
    mock_crawler.__aenter__ = AsyncMock(return_value=mock_crawler)
    mock_crawler.__aexit__ = AsyncMock(return_value=False)
    mock_crawler.arun = AsyncMock(return_value=mock_result)

    with patch("tenderai_bf.agents.nodes.fetch_crawl4ai.AsyncWebCrawler", return_value=mock_crawler), \
         patch("tenderai_bf.agents.nodes.fetch_crawl4ai.LLMExtractionStrategy"), \
         patch("tenderai_bf.agents.nodes.fetch_crawl4ai._get_llm_config", return_value=("groq/llama-3.3-70b-versatile", "test-key")):
        result = _run(__import__("tenderai_bf.agents.nodes.fetch_crawl4ai", fromlist=["fetch_crawl4ai"]).fetch_crawl4ai(SOURCE, "run-test"))

    assert result["status"] == "failed"
```

- [ ] **Étape 2 : Vérifier que les tests échouent**

```bash
poetry run pytest tests/nodes/test_fetch_crawl4ai.py -v --no-cov
```
Attendu : ImportError (fichier non créé)

- [ ] **Étape 3 : Implémenter `fetch_crawl4ai.py`**

Créer `src/tenderai_bf/agents/nodes/fetch_crawl4ai.py` :

```python
"""Crawl4AI-based tender fetcher.

Utilise LLMExtractionStrategy pour extraire les données sans sélecteurs CSS.
Le provider LLM est déterminé depuis settings.llm (Groq/OpenAI/Ollama).

Dépendance optionnelle : poetry install --extras full
"""

import json
from datetime import datetime
from typing import Optional

from pydantic import BaseModel

from ...logging import get_logger

logger = get_logger(__name__)

try:
    from crawl4ai import AsyncWebCrawler
    from crawl4ai.extraction_strategy import LLMExtractionStrategy
    _CRAWL4AI_AVAILABLE = True
except ImportError:
    AsyncWebCrawler = None  # type: ignore
    LLMExtractionStrategy = None  # type: ignore
    _CRAWL4AI_AVAILABLE = False


class TenderItem(BaseModel):
    """Schéma d'extraction LLM partagé html-tender / crawl4ai."""
    title: str
    reference: Optional[str] = None
    deadline: Optional[str] = None
    entity: Optional[str] = None
    country: Optional[str] = None
    description: Optional[str] = None
    document_url: Optional[str] = None


_EXTRACTION_INSTRUCTION = (
    "Extrais tous les appels d'offres ou marchés publics présents sur cette page. "
    "Pour chaque appel d'offres, retourne un objet JSON avec les champs : "
    "title (intitulé complet), reference (numéro de référence si présent), "
    "deadline (date limite de dépôt), entity (organisme émetteur), "
    "country (pays concerné), description (résumé court), "
    "document_url (URL du PDF ou document si présent)."
)


async def fetch_crawl4ai(source: dict, run_id: str) -> dict:
    """Fetch tenders using Crawl4AI LLM extraction strategy."""
    if not _CRAWL4AI_AVAILABLE:
        logger.error(
            "crawl4ai not installed — run: poetry install --extras full && crawl4ai-setup",
            run_id=run_id,
        )
        return _error(source, "crawl4ai not installed — run: poetry install --extras full")

    source_name = source["name"]
    list_url = source["list_url"]
    patterns = source.get("patterns") or {}

    ssl_verify = patterns.get("ssl_verify", True)
    max_pages = int(patterns.get("max_pages", 1))
    pagination_url = patterns.get("pagination_url")

    urls = [list_url]
    if max_pages > 1 and pagination_url:
        for page in range(2, max_pages + 1):
            urls.append(pagination_url.format(page=page))

    provider, api_token = _get_llm_config()
    strategy = LLMExtractionStrategy(
        provider=provider,
        api_token=api_token,
        schema=TenderItem.model_json_schema(),
        extraction_type="schema",
        instruction=_EXTRACTION_INSTRUCTION,
    )

    # BrowserConfig pour SSL permissif si ssl_verify=False
    crawler_kwargs: dict = {}
    if not ssl_verify:
        try:
            from crawl4ai import BrowserConfig
            crawler_kwargs["config"] = BrowserConfig(ignore_https_errors=True)
        except Exception:
            pass  # Version plus ancienne sans BrowserConfig

    listings: list[dict] = []

    async with AsyncWebCrawler(**crawler_kwargs) as crawler:
        for url in urls:
            try:
                result = await crawler.arun(url=url, extraction_strategy=strategy)
                if not result.extracted_content:
                    logger.warning("crawl4ai: aucun contenu extrait", url=url, run_id=run_id)
                    continue

                raw = json.loads(result.extracted_content)
                items = raw if isinstance(raw, list) else [raw]

                for item in items:
                    if not item.get("title"):
                        continue
                    listings.append({
                        "url": item.get("document_url") or url,
                        "title": item.get("title", ""),
                        "tender_object": item.get("title", ""),
                        "reference": item.get("reference", ""),
                        "ref_no": item.get("reference", ""),
                        "entity": item.get("entity") or patterns.get("entity", source_name),
                        "location": item.get("country") or patterns.get("location", ""),
                        "deadline": item.get("deadline", ""),
                        "description": item.get("description", ""),
                        "category": "Autre",
                        "type": "appel_offres",
                        "source": source_name,
                        "parser_type": "crawl4ai",
                    })
            except Exception as e:
                logger.warning("crawl4ai fetch failed", url=url, error=str(e), run_id=run_id)

    logger.info(
        "crawl4ai fetch complete",
        source=source_name,
        listings=len(listings),
        run_id=run_id,
    )

    return {
        "source": source,
        "content": None,
        "listings": listings,
        "url": list_url,
        "status": "success" if listings else "failed",
        "parser_type": "crawl4ai",
        "fetched_at": datetime.utcnow().isoformat(),
    }


def _get_llm_config() -> tuple[str, str]:
    """Retourne (provider_string, api_token) depuis settings.llm."""
    from ...config import settings
    llm = settings.llm
    if llm.provider == "groq":
        return (f"groq/{llm.groq_model}", llm.groq_api_key.get_secret_value())
    if llm.provider == "openai":
        return (f"openai/{llm.openai_model}", llm.openai_api_key.get_secret_value())
    if llm.provider == "ollama":
        return (f"ollama/{llm.ollama_model}", "")
    return (f"openai/{llm.openai_model}", llm.openai_api_key.get_secret_value())


def _error(source: dict, msg: str) -> dict:
    return {
        "source": source,
        "content": None,
        "listings": [],
        "url": source["list_url"],
        "status": "failed",
        "error": msg,
        "parser_type": "crawl4ai",
        "fetched_at": datetime.utcnow().isoformat(),
    }
```

- [ ] **Étape 4 : Vérifier que les tests passent**

```bash
poetry run pytest tests/nodes/test_fetch_crawl4ai.py -v --no-cov
```
Attendu : 3 PASS (le test `not_installed` peut être skippé si crawl4ai est installé — acceptable)

- [ ] **Étape 5 : Commit**

```bash
git add src/tenderai_bf/agents/nodes/fetch_crawl4ai.py tests/nodes/test_fetch_crawl4ai.py
git commit -m "feat(fetch): ajouter fetch_crawl4ai — parser LLM via Crawl4AI"
```

---

## Task 4 : Wiring dans `fetch_listings.py`

**Fichiers :**
- Modifier : `src/tenderai_bf/agents/nodes/fetch_listings.py`

- [ ] **Étape 1 : Ajouter les imports en tête du fichier**

Dans `fetch_listings.py`, après les imports existants, ajouter :

```python
from .fetch_html_tender import fetch_html_tender
from .fetch_crawl4ai import fetch_crawl4ai
```

- [ ] **Étape 2 : Ajouter les deux dispatch cases dans `fetch_single_listing`**

Dans `fetch_single_listing`, juste avant le bloc `# Standard HTML listing source` (vers la ligne ~250), ajouter :

```python
    # html-tender — config-driven CSS extraction
    if parser_type == "html-tender":
        try:
            result = await fetch_html_tender(source, run_id)
            log_source_fetch(
                source_name, list_url,
                result["status"],
                size=len(result.get("listings", [])),
            )
            return result
        except Exception as e:
            logger.error("html-tender fetch failed", source=source_name, error=str(e), run_id=run_id)
            log_source_fetch(source_name, list_url, "failed", error=str(e))
            return {
                "source": source, "content": None, "url": list_url,
                "status": "failed", "error": str(e),
                "fetched_at": datetime.utcnow().isoformat(),
            }

    # crawl4ai — LLM-based extraction
    if parser_type == "crawl4ai":
        try:
            result = await fetch_crawl4ai(source, run_id)
            log_source_fetch(
                source_name, list_url,
                result["status"],
                size=len(result.get("listings", [])),
            )
            return result
        except Exception as e:
            logger.error("crawl4ai fetch failed", source=source_name, error=str(e), run_id=run_id)
            log_source_fetch(source_name, list_url, "failed", error=str(e))
            return {
                "source": source, "content": None, "url": list_url,
                "status": "failed", "error": str(e),
                "fetched_at": datetime.utcnow().isoformat(),
            }
```

- [ ] **Étape 3 : Vérifier que les tests existants passent toujours**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Attendu : aucune régression

- [ ] **Étape 4 : Commit**

```bash
git add src/tenderai_bf/agents/nodes/fetch_listings.py
git commit -m "feat(pipeline): dispatcher fetch_listings supporte html-tender et crawl4ai"
```

---

## Task 5 : Handler dans `extract_item_links.py`

**Fichiers :**
- Modifier : `src/tenderai_bf/agents/nodes/extract_item_links.py`

- [ ] **Étape 1 : Localiser le bloc UNGM**

Trouver dans `extract_item_links.py` le bloc `elif parser_type == "ungm":` (vers ligne ~316).

- [ ] **Étape 2 : Ajouter les deux handlers juste après le bloc UNGM**

```python
                elif parser_type in ("html-tender", "crawl4ai"):
                    import json as _json
                    try:
                        listings = (
                            _json.loads(content)
                            if isinstance(content, str)
                            else item.get("listings", [])
                        )
                        for listing in listings:
                            listing["parser_type"] = parser_type
                        links = listings
                        logger.info(
                            f"{parser_type}: {len(listings)} listings extracted",
                            source_name=source_name,
                            run_id=state.run_id,
                        )
                    except Exception as e:
                        logger.error(f"Failed to parse {parser_type} listings: {e}")
                        links = []
```

- [ ] **Étape 3 : Vérifier que les tests passent**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Attendu : aucune régression

- [ ] **Étape 4 : Commit**

```bash
git add src/tenderai_bf/agents/nodes/extract_item_links.py
git commit -m "feat(pipeline): extract_item_links gère html-tender et crawl4ai"
```

---

## Task 6 : Routing dans `fetch_items.py`

**Fichiers :**
- Modifier : `src/tenderai_bf/agents/nodes/fetch_items.py`

- [ ] **Étape 1 : Ajouter html-tender/crawl4ai dans la liste de séparation**

Trouver le bloc `for link in state.discovered_links:` (vers ligne ~300). Ajouter une liste dédiée et la condition de routing :

Après `ungm_items = []`, ajouter :
```python
        html_tender_items = []
```

Dans la boucle `for link in state.discovered_links:`, ajouter après le cas `ungm` :
```python
            elif isinstance(link, dict) and link.get("parser_type") in ("html-tender", "crawl4ai"):
                html_tender_items.append(link)
```

- [ ] **Étape 2 : Ajouter le pass-through pour html_tender_items**

Juste après le bloc de traitement UNGM (vers ligne ~383), ajouter :

```python
        # html-tender et crawl4ai — données déjà extraites, pas de fetch supplémentaire
        for link in html_tender_items:
            items.append({
                "url": link.get("url", ""),
                "content": link.get("description", ""),
                "status": "success",
                "fetched_at": datetime.utcnow().isoformat(),
                "parser_type": link.get("parser_type", "html-tender"),
                "source": link.get("source", ""),
                "details": link,
            })
        if html_tender_items:
            logger.info(
                "html-tender/crawl4ai items passed through (no detail fetch needed)",
                count=len(html_tender_items),
                run_id=state.run_id,
            )
```

- [ ] **Étape 3 : Vérifier que les tests passent**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Attendu : aucune régression

- [ ] **Étape 4 : Commit**

```bash
git add src/tenderai_bf/agents/nodes/fetch_items.py
git commit -m "feat(pipeline): fetch_items route html-tender et crawl4ai en pass-through"
```

---

## Task 7 : Handler dans `parse_extract.py`

**Fichiers :**
- Modifier : `src/tenderai_bf/agents/nodes/parse_extract.py`

- [ ] **Étape 1 : Trouver le handler UNGM**

Localiser `elif parser_type == "ungm":` (vers ligne ~628).

- [ ] **Étape 2 : Ajouter le handler commun juste après le handler UNGM**

```python
            # html-tender et crawl4ai — champs déjà normalisés dans le fetcher
            elif parser_type in ("html-tender", "crawl4ai"):
                details = item.get("details", {})
                parsed_items.append(
                    {
                        "id": str(uuid.uuid4()),
                        "url": item["url"],
                        "content_hash": content_hash,
                        "title": details.get("title", ""),
                        "tender_object": details.get("tender_object") or details.get("title", ""),
                        "reference": details.get("reference", ""),
                        "ref_no": details.get("ref_no", details.get("reference", "")),
                        "entity": details.get("entity", ""),
                        "category": details.get("category", "Autre"),
                        "description": details.get("description", ""),
                        "deadline": details.get("deadline", ""),
                        "published_at": details.get("published_at", ""),
                        "location": details.get("location", ""),
                        "type": details.get("type", "appel_offres"),
                        "source": details.get("source", parser_type),
                    }
                )
                continue
```

- [ ] **Étape 3 : Vérifier que les tests passent**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Attendu : aucune régression

- [ ] **Étape 4 : Commit**

```bash
git add src/tenderai_bf/agents/nodes/parse_extract.py
git commit -m "feat(pipeline): parse_extract handler commun html-tender et crawl4ai"
```

---

## Task 8 : Config `settings.yaml` + dépendance `pyproject.toml`

**Fichiers :**
- Modifier : `settings.yaml`
- Modifier : `pyproject.toml`

- [ ] **Étape 1 : Ajouter les deux sources dans `settings.yaml`**

À la fin de la liste `sources:` dans `settings.yaml`, ajouter :

```yaml
  - name: "UEMOA - Appels d'offres"
    list_url: "https://www.uemoa.int/appel-d-offre"
    parser: "html-tender"
    rate_limit: "5/m"
    enabled: true
    description: "Appels d'offres régionaux UEMOA (zone Afrique de l'Ouest)"
    patterns:
      ssl_verify: false
      card_selector: "div.swiper-slide div.news-box"
      title_selector: "div.new-txt p"
      deadline_selector: "time"
      deadline_attribute: "datetime"
      pdf_selector: "a[href*='opportunite_affaire']"
      entity: "UEMOA"
      location: "Zone UEMOA"
      max_pages: 1

  - name: "Enabel - Marchés publics Burkina Faso"
    list_url: "https://www.enabel.be/fr/marches-publics/?in_country=1726&is_status=0"
    parser: "html-tender"
    rate_limit: "5/m"
    enabled: true
    description: "Marchés publics Enabel (coopération belge) filtrés Burkina Faso ouverts"
    patterns:
      card_selector: "div.card--news.card--tenders"
      title_selector: "p.h5 span"
      deadline_selector: "p"
      deadline_text_prefix: "Date de clôture"
      entity: "Enabel"
      location: "Burkina Faso"
      max_pages: 3
      pagination_url: "https://www.enabel.be/fr/marches-publics/page/{page}/?in_country=1726&is_status=0"
```

- [ ] **Étape 2 : Ajouter `crawl4ai` comme dépendance optionnelle dans `pyproject.toml`**

Localiser la section `[tool.poetry.dependencies]`. Ajouter après `playwright` :

```toml
crawl4ai = {version = ">=0.4.0", optional = true}
```

Modifier la ligne `full = [...]` pour inclure crawl4ai :

```toml
full = ["spacy", "playwright", "crawl4ai"]
```

- [ ] **Étape 3 : Vérifier la syntaxe pyproject.toml**

```bash
poetry check
```
Attendu : `All set!`

- [ ] **Étape 4 : Commit**

```bash
git add settings.yaml pyproject.toml
git commit -m "feat(config): ajouter sources UEMOA et Enabel, crawl4ai dépendance optionnelle"
```

---

## Task 9 : Smoke test end-to-end + seed DB

- [ ] **Étape 1 : Lancer la suite de tests complète**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Attendu : tous les tests verts, aucune régression

- [ ] **Étape 2 : Vérifier le seed en local (si DB disponible)**

```bash
poetry run tenderai seed-sources --force
```
Attendu :
```
  Updated: UEMOA - Appels d'offres
  Updated: Enabel - Marchés publics Burkina Faso
Done: 0 created, 2 updated, N skipped.
```

Si premier run (sources nouvelles) :
```
  Created: UEMOA - Appels d'offres
  Created: Enabel - Marchés publics Burkina Faso
```

- [ ] **Étape 3 : Vérifier que patterns est bien en DB**

```bash
docker compose exec api python -c "
from tenderai_bf.db import get_db_context
from tenderai_bf.models import Source
with get_db_context() as s:
    src = s.query(Source).filter(Source.name.like('%UEMOA%')).first()
    print('patterns:', src.patterns)
"
```
Attendu : `patterns: {'ssl_verify': False, 'card_selector': 'div.swiper-slide div.news-box', ...}`

- [ ] **Étape 4 : Test d'un run pipeline avec les nouvelles sources (optionnel)**

```bash
docker compose exec api python -m tenderai_bf.cli run-once
```
Observer les logs pour vérifier que UEMOA et Enabel sont bien fetchées.

- [ ] **Étape 5 : Commit final**

```bash
git add .
git commit -m "chore: smoke test sources UEMOA et Enabel validées"
```
