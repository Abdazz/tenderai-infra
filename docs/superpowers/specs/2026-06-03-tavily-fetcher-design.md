# Design Spec : Intégration Tavily comme parser web générique

**Date :** 2026-06-03  
**Statut :** Approuvé  
**Contexte :** IMPROVEMENTS.md #4

---

## Objectif

Fournir un fetcher générique basé sur Tavily pour toute nouvelle source de type web ajoutée au pipeline TenderAI. Les fetchers existants (`fetch_bceao.py`, `fetch_joffres.py`, `fetch_quotidien.py`, `fetch_ungm.py`) sont conservés intacts. Tavily s'applique uniquement aux nouvelles sources configurées avec `parser_type = "tavily_search"` ou `parser_type = "tavily_extract"`.

---

## Architecture & Composants

### Nouveaux fichiers

| Fichier | Rôle |
|---|---|
| `src/tenderai_bf/agents/nodes/fetch_tavily.py` | Fetcher Tavily — contient `fetch_tavily_search` et `fetch_tavily_extract` |
| `tests/nodes/test_fetch_tavily.py` | Tests unitaires du fetcher (API mockée) |

### Fichiers modifiés

| Fichier | Modification |
|---|---|
| `src/tenderai_bf/config.py` | Ajout `TavilySettings` + rattachement à `Settings.tavily` |
| `src/tenderai_bf/agents/nodes/fetch_listings.py` | Branchement `parser_type in ("tavily_search", "tavily_extract")` |
| `src/tenderai_bf/agents/nodes/fetch_items.py` | Skip des items dont `parser_type` commence par `"tavily"` |
| `src/tenderai_bf/agents/nodes/parse_extract.py` | Branche de normalisation Tavily → Notice partiel |
| `tests/nodes/test_parse_extract.py` | Cas de test pour items Tavily |

### Deux parser_type

| `parser_type` | Endpoint Tavily | Cas d'usage |
|---|---|---|
| `tavily_search` | `POST /search` | Source sans URL de listing stable ; requêtes configurées dans `patterns.queries` |
| `tavily_extract` | `POST /extract` | URL de listing connue et stable ; Tavily extrait le contenu structuré de la page |

---

## Configuration

### `TavilySettings` (config.py)

```python
class TavilySettings(BaseSettings):
    api_key: SecretStr = Field(default="", validation_alias="TAVILY_API_KEY")
    max_results: int = Field(default=10)
    search_depth: str = Field(default="basic")  # "basic" | "advanced"

    model_config = SettingsConfigDict(case_sensitive=False)
```

Rattachement dans `Settings` : `tavily: TavilySettings = Field(default_factory=TavilySettings)`

### Champ `patterns` (JSON existant sur `Source`)

Pas de migration requise. Le champ `patterns` porte la config Tavily spécifique à chaque source.

```json
// tavily_search
{
  "queries": [
    "appel d'offres Sénégal informatique",
    "marché public TIC Sénégal site:finances.gouv.sn"
  ]
}

// tavily_extract
{
  "include_raw_content": true,
  "extract_depth": "advanced"
}
```

---

## Flux de données

### Mode `tavily_search`

```
fetch_listings
  → fetch_tavily_search(source, run_id)
     → POST /search pour chaque query dans patterns["queries"]
     → agrège les résultats, déduplique par URL
  → items_raw += [{ ..., "parser_type": "tavily_search", "source": source }]

extract_item_links  → skip silencieux pour items parser_type "tavily_*"
fetch_items         → skip silencieux pour items parser_type "tavily_*"

parse_extract
  → détecte parser_type in ("tavily_search", "tavily_extract")
  → mappe vers Notice partiel :
       title       ← result["title"]
       source_url  ← result["url"]
       raw_text    ← result["content"] ou result["raw_content"]
       relevance   ← result.get("score")
```

### Mode `tavily_extract`

```
fetch_listings
  → fetch_tavily_extract(source, run_id)
     → POST /extract avec source["list_url"]
     → retourne { url, raw_content, results: [...] }
  → items_raw += [{ ..., "parser_type": "tavily_extract", "source": source }]

→ même court-circuit que tavily_search ensuite
```

---

## Gestion d'erreurs

| Cas | Comportement |
|---|---|
| `TAVILY_API_KEY` absent ou vide | Log warning, retour `status: "failed"` (non-fatal si d'autres sources réussissent) |
| HTTP 429 (quota dépassé) | Warning non-fatal, source marquée `last_error_at`, pipeline continue |
| Réponse vide (liste vide) | Warning, source marquée `last_error_at`, pas de crash |
| Timeout / erreur réseau | Même traitement que les autres fetchers : erreur loggée, `status: "failed"` |

---

## Tests

### `tests/nodes/test_fetch_tavily.py`

- `test_tavily_search_success` — mock POST `/search`, vérifie `items_raw` avec `parser_type == "tavily_search"`
- `test_tavily_extract_success` — mock POST `/extract`, vérifie le résultat structuré
- `test_tavily_missing_api_key` — settings sans clé → retour `status: "failed"` propre, pas d'exception
- `test_tavily_rate_limit` — mock 429 → warning non-fatal, pas d'exception levée
- `test_tavily_empty_results` — Tavily retourne liste vide → warning, pas de crash

### `tests/nodes/test_parse_extract.py` (extension)

- `test_parse_extract_tavily_item` — vérifie que les champs Tavily sont correctement mappés vers un `Notice` partiel (title, source_url, raw_text)

Les tests live (réseau réel) sont marqués `@pytest.mark.integration` et exclus de la CI standard.

---

## Décisions clés

- **Approche A (court-circuit via `items_raw` + flag)** choisie plutôt qu'un nouveau champ sur le state ou un nœud de normalisation dédié — suit le pattern UNGM existant.
- **Pas de migration Alembic** — la config Tavily par source utilise le champ `patterns` (JSON) déjà présent sur `Source`.
- **Fetchers existants inchangés** — Tavily ne remplace rien, il couvre uniquement les nouvelles sources configurées avec `parser_type = "tavily_*"`.
