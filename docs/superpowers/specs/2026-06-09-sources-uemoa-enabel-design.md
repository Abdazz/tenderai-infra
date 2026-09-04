# Design : Intégration sources UEMOA et Enabel + parsers html-tender / crawl4ai

**Date :** 2026-06-09
**Statut :** Approuvé

---

## Contexte

Ajout de deux nouvelles sources de marchés publics pour le Burkina Faso :
- **UEMOA** (`uemoa.int`) — appels d'offres régionaux zone Afrique de l'Ouest
- **Enabel** (`enabel.be`) — marchés publics coopération belge, filtrés Burkina Faso ouverts

Simultanément, introduction de deux nouveaux `parser_type` génériques et maintenables :
- `html-tender` — extraction config-driven (sélecteurs CSS dans `settings.yaml`)
- `crawl4ai` — extraction LLM-based sans sélecteurs (Crawl4AI + Pydantic schema)

Le switching entre les deux se fait en changeant le champ `parser` dans `settings.yaml` puis `seed-sources --force` — aucun code à modifier.

---

## Flux de données

```
settings.yaml
    ↓  seed-sources CLI (corrigé pour inclure patterns)
DB: sources.patterns (JSON)
    ↓  load_sources_node
state.sources[].patterns
    ↓  fetch_listings_node
fetch_html_tender.py  ←→  patterns["card_selector", "title_selector", ...]
fetch_crawl4ai.py     ←→  patterns["ssl_verify", "max_pages", ...]
    ↓
parse_extract.py  →  handler commun "html-tender" / "crawl4ai"
    ↓
classify → deduplicate → report → email
```

---

## Parser type : `html-tender`

**Fichier :** `src/tenderai_bf/agents/nodes/fetch_html_tender.py`

**Paramètres `patterns` (tous optionnels sauf `card_selector`) :**

| Paramètre | Type | Description | Défaut |
|---|---|---|---|
| `card_selector` | str | Sélecteur CSS du bloc par tender | requis |
| `title_selector` | str | Titre dans le bloc | `"h1,h2,h3,p"` |
| `deadline_selector` | str | Deadline | `"time"` |
| `deadline_attribute` | str | Attribut HTML de la date | `None` (texte) |
| `deadline_text_prefix` | str | Le fetcher parcourt tous les `deadline_selector` et retient celui dont le texte contient ce préfixe, puis extrait la valeur après le `:` | `None` |
| `pdf_selector` | str | Lien PDF | `None` |
| `entity` | str | Valeur fixe pour l'entité | `""` |
| `location` | str | Valeur fixe pour la localisation | `""` |
| `ssl_verify` | bool | Vérification SSL | `true` |
| `max_pages` | int | Nombre de pages à crawler | `1` |
| `pagination_url` | str | Template URL `{page}` | `None` |

**Comportement :**
1. Fetch page 1 via httpx (`verify=ssl_verify`)
2. Extraire les cards via `card_selector` (selectolax)
3. Pour chaque card : extraire titre, deadline, PDF/URL, référence
4. Si `max_pages > 1` : itérer pages 2..N via `pagination_url`
5. Retourner liste de dicts au format standard

---

## Parser type : `crawl4ai`

**Fichier :** `src/tenderai_bf/agents/nodes/fetch_crawl4ai.py`

**Paramètres `patterns` :**

| Paramètre | Type | Description | Défaut |
|---|---|---|---|
| `ssl_verify` | bool | Vérification SSL | `true` |
| `max_pages` | int | Nombre de pages | `1` |
| `pagination_url` | str | Template URL `{page}` | `None` |

Tous les autres paramètres (`card_selector`, `title_selector`, etc.) sont ignorés — le LLM extrait sémantiquement.

**Schéma Pydantic partagé :**

```python
class TenderItem(BaseModel):
    title: str
    reference: Optional[str] = None
    deadline: Optional[str] = None
    entity: Optional[str] = None
    country: Optional[str] = None
    description: Optional[str] = None
    document_url: Optional[str] = None
```

**Comportement :**
1. `AsyncWebCrawler` avec `LLMExtractionStrategy(schema=TenderItem)`
2. Provider LLM = `settings.langchain.llm_provider` (Groq/OpenAI/Ollama existant)
3. Même logique de pagination que `html-tender`
4. Retourne le même format de dicts standards

**Dépendance optionnelle :** si `crawl4ai` n'est pas installé et que le parser est sélectionné, le fetcher logue une erreur claire et retourne `status: "failed"` (même pattern que `fetch_playwright.py`).

---

## Format de sortie commun

Les deux fetchers retournent une liste de dicts avec ces champs standards :

```python
{
    "url": str,           # URL du PDF (UEMOA) ou de la page listing (Enabel)
    "title": str,
    "reference": str,
    "entity": str,
    "deadline": str,      # format DD-MM-YYYY ou ISO
    "location": str,
    "description": str,
    "source": str,        # nom de la source
    "type": "appel_offres",
}
```

`parse_extract.py` traite les deux parser types via un handler commun (comme UNGM).

---

## Configuration `settings.yaml`

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

**Pour switcher vers crawl4ai :** changer `parser: "html-tender"` → `parser: "crawl4ai"` + `seed-sources --force`.

---

## Correction `seed_sources` CLI

Le `INSERT` et `UPDATE` doivent inclure `patterns` :

```python
import json
patterns = source.get("patterns")
# Passer comme string JSON — SQLAlchemy + psycopg2 gère la conversion JSONB
patterns_json = json.dumps(patterns) if patterns else None
```

```sql
INSERT INTO sources (..., patterns) VALUES (..., :patterns)
UPDATE sources SET ..., patterns=:patterns WHERE name=:name
```

Note : passer `patterns_json` (string) comme valeur `:patterns`.

---

## Fichiers à créer/modifier

| Fichier | Action |
|---|---|
| `agents/nodes/fetch_html_tender.py` | Créer |
| `agents/nodes/fetch_crawl4ai.py` | Créer |
| `agents/nodes/fetch_listings.py` | Modifier — +2 dispatch cases |
| `agents/nodes/parse_extract.py` | Modifier — +1 handler commun |
| `cli.py` | Modifier — `seed_sources` persiste `patterns` |
| `settings.yaml` | Modifier — +UEMOA, +Enabel |
| `pyproject.toml` | Modifier — `crawl4ai` optionnel |

---

## Dépendance crawl4ai

```toml
[tool.poetry.extras]
full = ["crawl4ai", "playwright", ...]
```

```bash
poetry add crawl4ai --optional
# Les browsers Playwright sont déjà installés via playwright
```

---

## Tests à écrire

- `tests/nodes/test_fetch_html_tender.py` — mock HTTP, vérifie extraction depuis HTML fixé
- `tests/nodes/test_fetch_crawl4ai.py` — mock `AsyncWebCrawler`, vérifie format de sortie
- Tests d'intégration marqués `@pytest.mark.integration`
