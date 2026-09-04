# Montée de version LangChain/LangGraph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Monter `langchain` de `^0.2.0` à `^1.3.0` et `langgraph` de `^0.1.0` à `^1.2.0` dans le monorepo TenderAI BF, corriger tous les breaking changes que cette montée entraîne, et vérifier via 3 niveaux (suite de tests, exécution réelle, comparaison structurelle avant/après) qu'aucune régression n'a été introduite.

**Architecture:** Passage direct vers les dernières versions stables (pas de palier intermédiaire). Le périmètre est net : 5 fichiers source ont un import direct LangChain/LangGraph, 1 fichier de test mocke le graphe compilé. Le pipeline utilise `StateGraph` directement (pas les abstractions agent de LangChain), donc aucune réécriture architecturale n'est nécessaire — uniquement des corrections de chemins d'import, une migration d'API LangGraph mineure, et une adoption partielle évaluée de `init_chat_model`.

**Tech Stack:** Python 3.11, Poetry, LangChain 1.3.x, LangGraph 1.2.x, pytest.

**Spec:** `docs/superpowers/specs/2026-08-25-langchain-langgraph-upgrade-design.md`

## Global Constraints

- Toutes les commandes s'exécutent depuis `/home/yulcom/web/tender-ai/.claude/worktrees/repo-split` — un worktree git isolé qui contient sa propre copie complète et identique du code source (`pyproject.toml`, `src/`, `tests/`), jamais modifiée par le chantier 1 (séparation en 3 repos, en pause ailleurs dans ce même worktree — les deux chantiers touchent des fichiers disjoints et cohabitent sans conflit). Ne pas exécuter ces commandes depuis `/home/yulcom/web/tender-ai` directement — les sessions isolées dans ce worktree ne peuvent cibler que leur propre répertoire.
- `langchain-community` est retiré de `pyproject.toml` — confirmé zéro usage direct dans `src/` et `tests/` (`grep -rn "langchain_community" src/ tests/` retourne vide).
- `langchain_core.prompts` et `langchain_text_splitters` remplacent respectivement `langchain.prompts` et `langchain.text_splitter` comme chemins d'import canoniques — indépendamment du fait que les anciens réexports survivent ou non en v1.
- `workflow.set_entry_point("load_sources")` devient `workflow.add_edge(START, "load_sources")` avec `START` importé depuis `langgraph.graph`.
- Aucun test qui passe avant la montée de version ne doit échouer après (les échecs déjà présents avant — dette préexistante hors périmètre — restent tolérés, documentés en Task 1, mais ne doivent pas augmenter en nombre).
- `_AppWrapper` et `_coerce_to_state` (dans `agents/graph.py`) ne sont modifiés/simplifiés que si un test concret confirme que le nouveau comportement de `CompiledStateGraph`/`invoke()` le permet — jamais par anticipation.
- `get_llm_instance()` et `validate_llm_available()` (dans `utils/llm_utils.py`) gardent leur signature publique et leur logique de repli (Groq→OpenAI, vérification de clé API par provider) inchangées — seule l'instanciation interne du chat model peut changer.

---

## File Structure

```
pyproject.toml, poetry.lock                    — Modify: bump versions, retirer langchain-community, ajouter langchain-text-splitters
src/tenderai_bf/agents/graph.py                — Modify: START/add_edge, _AppWrapper (évaluation), _coerce_to_state (évaluation)
src/tenderai_bf/agents/nodes/deduplicate.py    — Modify: import PromptTemplate
src/tenderai_bf/agents/nodes/summarize.py      — Modify: import PromptTemplate
src/tenderai_bf/agents/nodes/parse_pdf_rag.py  — Modify: import RecursiveCharacterTextSplitter
src/tenderai_bf/utils/llm_utils.py             — Modify: init_chat_model (adoption partielle)
tests/test_pipeline_country.py                 — Modify (conditionnel): uniquement si _AppWrapper est retiré et qu'un ajustement de mock s'avère nécessaire
```

---

## Task 1: Baseline — capturer l'état actuel avant tout changement

**Files:**
- Create: `/tmp/langchain-upgrade-baseline/test-results-before.txt` (hors du repo, artefact de référence pour ce plan)

**Interfaces:**
- Produces: un fichier de référence listant les tests qui passent/échouent AVANT la montée de version — consommé par Task 8 pour la comparaison finale.

- [ ] **Step 1: Confirmer l'absence d'usage de `langchain-community`**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
grep -rn "langchain_community" src/ tests/
```
Attendu : aucune sortie (déjà confirmé lors de l'écriture de ce plan — cette étape est une re-vérification avant de retirer la dépendance en Task 2).

- [ ] **Step 2: Capturer la baseline de tests**

```bash
mkdir -p /tmp/langchain-upgrade-baseline
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run pytest tests/ -v --no-cov > /tmp/langchain-upgrade-baseline/test-results-before.txt 2>&1
echo "exit code: $?" >> /tmp/langchain-upgrade-baseline/test-results-before.txt
tail -30 /tmp/langchain-upgrade-baseline/test-results-before.txt
```
Attendu : le fichier contient la liste complète des tests avec leur statut (PASSED/FAILED/ERROR). Noter le nombre exact de passed/failed — c'est la référence pour Task 8. Ne pas s'inquiéter si certains tests échouent déjà à ce stade (dette préexistante) — l'objectif est de documenter l'état de départ, pas de le corriger.

- [ ] **Step 3: Committer le fichier de référence dans le repo pour traçabilité**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
mkdir -p docs/superpowers/artifacts
cp /tmp/langchain-upgrade-baseline/test-results-before.txt docs/superpowers/artifacts/2026-08-25-langchain-upgrade-test-baseline.txt
git add docs/superpowers/artifacts/2026-08-25-langchain-upgrade-test-baseline.txt
git commit -m "docs: capture test baseline before LangChain/LangGraph upgrade"
```

---

## Task 2: Monter les versions dans pyproject.toml et installer

**Files:**
- Modify: `pyproject.toml:16-23`

**Interfaces:**
- Consumes: rien (première modification de code du plan).
- Produces: un environnement Poetry avec `langchain 1.3.x`, `langgraph 1.2.x`, `langchain-text-splitters` installé, `langchain-community` retiré — consommé par toutes les tâches suivantes.

- [ ] **Step 1: Modifier les dépendances dans `pyproject.toml`**

Remplacer les lignes 16-23 :
```toml
# LangChain & LangGraph
langchain = "^0.2.0"
langgraph = "^0.1.0"
langchain-community = "^0.2.0"
langchain-groq = "^0.1.0"
langchain-openai = "^0.1.0"
langchain-ollama = "^0.1.0"
langchain-nvidia-ai-endpoints = "^0.1.7"
```
par :
```toml
# LangChain & LangGraph
langchain = "^1.3.0"
langgraph = "^1.2.0"
langchain-text-splitters = "^1.0.0"
langchain-groq = "^1.1.0"
langchain-openai = "^1.6.0"
langchain-ollama = "^1.1.0"
langchain-nvidia-ai-endpoints = "^1.4.0"
```
(`langchain-community` retiré — zéro usage confirmé en Task 1. Les bornes des packages provider correspondent à leurs dernières versions publiées au moment de l'écriture de ce plan (`langchain-groq 1.1.3`, `langchain-openai 1.6.0`, `langchain-ollama 1.1.0`, `langchain-nvidia-ai-endpoints 1.4.3` — vérifiées via `pip index versions <package>`) ; `poetry lock` à l'étape suivante résoudra les versions exactes compatibles entre elles — si `poetry lock` échoue à trouver une version satisfaisant à la fois ces bornes et la compatibilité avec `langchain ^1.3.0`, ajuster la borne au minimum nécessaire rapporté par l'erreur de résolution de Poetry, pas au-delà.)

- [ ] **Step 2: Relancer la résolution des dépendances**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
poetry lock
```
Attendu : exit code 0, `poetry.lock` mis à jour. Si la résolution échoue avec un conflit de versions, lire le message d'erreur de Poetry (il indique la contrainte en conflit) et ajuster la borne du package concerné dans `pyproject.toml` au minimum nécessaire pour lever le conflit, puis relancer `poetry lock`.

- [ ] **Step 3: Installer l'environnement**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
poetry install --extras "full" --with dev
```
Attendu : exit code 0.

- [ ] **Step 4: Smoke-test des imports de premier niveau**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
poetry run python -c "import langchain; import langgraph; import langchain_text_splitters; import langchain_groq; import langchain_openai; import langchain_ollama; import langchain_nvidia_ai_endpoints; print('langchain', langchain.__version__); print('langgraph', langgraph.__version__)"
```
Attendu : exit code 0, affiche les versions installées (doit commencer par `1.` pour les deux). Aucune `ImportError`.

- [ ] **Step 5: Commit**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
git add pyproject.toml poetry.lock
git commit -m "chore(deps): upgrade langchain to ^1.3.0 and langgraph to ^1.2.0"
```

---

## Task 3: Corriger les imports cassés (PromptTemplate, RecursiveCharacterTextSplitter)

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/deduplicate.py:21`
- Modify: `src/tenderai_bf/agents/nodes/summarize.py:16`
- Modify: `src/tenderai_bf/agents/nodes/parse_pdf_rag.py:11`

**Interfaces:**
- Consumes: environnement avec `langchain 1.3.x` et `langchain-text-splitters` installés (Task 2).
- Produces: les 3 fichiers important `PromptTemplate`/`RecursiveCharacterTextSplitter` depuis leurs chemins canoniques — consommé par Task 8 (vérification).

- [ ] **Step 1: Corriger l'import dans `deduplicate.py`**

Dans `src/tenderai_bf/agents/nodes/deduplicate.py`, à l'intérieur de `check_duplicate_with_llm`, remplacer :
```python
        from langchain.prompts import PromptTemplate
```
par :
```python
        from langchain_core.prompts import PromptTemplate
```

- [ ] **Step 2: Corriger l'import dans `summarize.py`**

Dans `src/tenderai_bf/agents/nodes/summarize.py`, à l'intérieur de `generate_summary_with_llm`, remplacer :
```python
        from langchain.prompts import PromptTemplate
```
par :
```python
        from langchain_core.prompts import PromptTemplate
```

- [ ] **Step 3: Corriger l'import dans `parse_pdf_rag.py`**

Dans `src/tenderai_bf/agents/nodes/parse_pdf_rag.py`, en tête de fichier, remplacer :
```python
from langchain.text_splitter import RecursiveCharacterTextSplitter
```
par :
```python
from langchain_text_splitters import RecursiveCharacterTextSplitter
```

- [ ] **Step 4: Vérifier que les 3 fichiers s'importent sans erreur**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
poetry run python -c "from tenderai_bf.agents.nodes import deduplicate, summarize, parse_pdf_rag; print('ok')"
```
Attendu : exit code 0, affiche `ok`. Aucune `ImportError`/`ModuleNotFoundError`.

- [ ] **Step 5: Lancer les tests dédiés à ces 3 nœuds**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run pytest tests/nodes/test_deduplicate.py tests/nodes/test_summarize.py tests/nodes/test_pdf_rag.py -v --no-cov
```
Attendu : mêmes résultats que la baseline Task 1 pour ces 3 fichiers (aucune régression — ce sont les tests les plus directement ciblés par les changements de cette tâche).

- [ ] **Step 6: Commit**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
git add src/tenderai_bf/agents/nodes/deduplicate.py src/tenderai_bf/agents/nodes/summarize.py src/tenderai_bf/agents/nodes/parse_pdf_rag.py
git commit -m "fix(langchain): update PromptTemplate and RecursiveCharacterTextSplitter import paths for v1"
```

---

## Task 4: Migrer le point d'entrée LangGraph (`set_entry_point` → `START`/`add_edge`)

**Files:**
- Modify: `src/tenderai_bf/agents/graph.py:9`, `:229-245`

**Interfaces:**
- Consumes: `langgraph 1.2.x` installé (Task 2).
- Produces: `TenderAIGraph._build_graph()` utilisant `add_edge(START, ...)` au lieu de `set_entry_point(...)` — comportement de routage identique, consommé par Task 8.

- [ ] **Step 1: Importer `START`**

Dans `src/tenderai_bf/agents/graph.py`, ligne 9, remplacer :
```python
from langgraph.graph import END, StateGraph
```
par :
```python
from langgraph.graph import END, START, StateGraph
```

- [ ] **Step 2: Remplacer `set_entry_point` par `add_edge(START, ...)`**

Dans la méthode `_build_graph`, remplacer :
```python
        # Set entry point
        workflow.set_entry_point("load_sources")
```
par :
```python
        # Set entry point
        workflow.add_edge(START, "load_sources")
```

- [ ] **Step 3: Vérifier que le graphe se compile toujours**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run python -c "
from tenderai_bf.agents.graph import create_pipeline_graph
g = create_pipeline_graph()
assert g.app is not None
assert len(g.graph.nodes) > 0
print('graph compiled ok, nodes:', len(g.graph.nodes))
"
```
Attendu : exit code 0, affiche `graph compiled ok, nodes: 11`.

- [ ] **Step 4: Lancer les tests touchant à la création du graphe**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run pytest tests/test_integration.py -v --no-cov
```
Attendu : `test_pipeline_graph_creation` passe (même résultat qu'en baseline Task 1 — vérifier contre `docs/superpowers/artifacts/2026-08-25-langchain-upgrade-test-baseline.txt` si ce test y était déjà en échec, auquel cas cet état est inchangé, pas une régression).

- [ ] **Step 5: Commit**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
git add src/tenderai_bf/agents/graph.py
git commit -m "fix(langgraph): migrate set_entry_point to add_edge(START, ...)"
```

---

## Task 5: Évaluer et simplifier `_AppWrapper` et `_coerce_to_state`

**Files:**
- Modify (conditionnel): `src/tenderai_bf/agents/graph.py:183-217, 456-470`
- Modify (conditionnel): `tests/test_pipeline_country.py` — uniquement si le test échoue après retrait du wrapper et nécessite un ajustement de mock équivalent (pas de changement d'assertion, seulement de mécanisme de mock si strictement nécessaire)

**Interfaces:**
- Consumes: `langgraph 1.2.x` installé (Task 2), point d'entrée migré (Task 4).
- Produces: soit `_AppWrapper` retiré et `self.app = self.graph.compile()` direct, soit `_AppWrapper` conservé tel quel — décision tranchée par un test concret à l'étape 1, pas par anticipation.

- [ ] **Step 1: Tester si `CompiledStateGraph` accepte l'assignation d'attributs directement, sans wrapper**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run python -c "
from tenderai_bf.agents.graph import TenderAIState
from langgraph.graph import END, START, StateGraph

def noop(state):
    return state

workflow = StateGraph(TenderAIState)
workflow.add_node('noop', noop)
workflow.add_edge(START, 'noop')
workflow.add_edge('noop', END)
compiled = workflow.compile()

try:
    compiled.invoke = lambda *a, **kw: 'mocked'
    print('ATTRIBUTE_ASSIGNMENT: OK')
except Exception as e:
    print('ATTRIBUTE_ASSIGNMENT: FAILED', type(e).__name__, str(e))
"
```
Ce script produit exactement une des deux lignes suivantes : `ATTRIBUTE_ASSIGNMENT: OK` ou `ATTRIBUTE_ASSIGNMENT: FAILED ...`. Le reste de cette tâche se ramifie sur ce résultat.

- [ ] **Step 2a — SI le Step 1 affiche `ATTRIBUTE_ASSIGNMENT: OK`** : retirer `_AppWrapper`

Dans `src/tenderai_bf/agents/graph.py`, supprimer entièrement la classe `_AppWrapper` (lignes 183-207, du commentaire `class _AppWrapper:` jusqu'à la fin de sa méthode `invoke`, juste avant `class TenderAIGraph:`).

Dans `TenderAIGraph.__init__`, remplacer :
```python
    def __init__(self):
        """Initialize the pipeline graph."""
        self.graph = self._build_graph()
        self.app = _AppWrapper(self.graph.compile())
        logger.info("TenderAI pipeline graph initialized")
```
par :
```python
    def __init__(self):
        """Initialize the pipeline graph."""
        self.graph = self._build_graph()
        self.app = self.graph.compile()
        logger.info("TenderAI pipeline graph initialized")
```

- [ ] **Step 2b — SI le Step 1 affiche `ATTRIBUTE_ASSIGNMENT: FAILED`** : ne rien changer

`_AppWrapper` reste nécessaire tel quel. Ne modifier ni `_AppWrapper` ni son usage dans `__init__`. Passer directement au Step 3.

- [ ] **Step 3: Vérifier le test de mock existant**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run pytest tests/test_pipeline_country.py::test_run_sets_country_id_on_state -v --no-cov
```
Attendu : PASSED. Si le Step 2a a été appliqué (wrapper retiré) et que ce test échoue à cause de l'assignation `graph.app.invoke = mock_invoke` (ligne 56 de `tests/test_pipeline_country.py`), **revenir sur le Step 2a** (restaurer `_AppWrapper` tel qu'il était avant modification, via `git checkout -- src/tenderai_bf/agents/graph.py` si aucun autre changement n'a été fait dans ce fichier depuis, sinon annuler manuellement uniquement les lignes touchées au Step 2a) plutôt que de modifier le test — le Step 1 avait donné un faux positif (l'assignation d'attribut sur un graphe minimal synthétique fonctionne, mais pas sur l'objet réel — cas à documenter comme concern dans le rapport de tâche) .

- [ ] **Step 4: Investiguer le type réel retourné par `.invoke()`**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run python -c "
from tenderai_bf.agents.graph import TenderAIState
from langgraph.graph import END, START, StateGraph

def noop(state):
    return state

workflow = StateGraph(TenderAIState)
workflow.add_node('noop', noop)
workflow.add_edge(START, 'noop')
workflow.add_edge('noop', END)
app = workflow.compile()
result = app.invoke(TenderAIState())
print('RETURN_TYPE:', type(result).__name__)
"
```
Attendu : affiche `RETURN_TYPE: TenderAIState` ou `RETURN_TYPE: dict` (ou `AddableValuesDict`/variante). **Ne pas modifier `_coerce_to_state`** quel que soit le résultat — la méthode reste défensive et gère les deux cas (c'est son rôle exact, voir son docstring actuel). Cette étape sert uniquement à documenter le comportement observé dans le rapport de tâche, pas à déclencher une modification de code.

- [ ] **Step 5: Suite de tests complète du fichier**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run pytest tests/test_pipeline_country.py tests/test_integration.py -v --no-cov
```
Attendu : mêmes résultats que la baseline Task 1 pour ces deux fichiers (aucune régression).

- [ ] **Step 6: Commit**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
git add src/tenderai_bf/agents/graph.py
git commit -m "refactor(langgraph): simplify _AppWrapper if CompiledStateGraph allows direct attribute assignment"
```
(Si le Step 2b s'est appliqué — aucun changement de code — ce commit sera vide ; utiliser `git commit --allow-empty -m "chore: confirm _AppWrapper remains required (CompiledStateGraph still refuses attribute assignment)"` à la place, pour documenter la décision dans l'historique même en l'absence de diff.)

---

## Task 6: Adopter partiellement `init_chat_model` dans `llm_utils.py`

**Files:**
- Modify: `src/tenderai_bf/utils/llm_utils.py:98-187`

**Interfaces:**
- Consumes: `langchain 1.3.x` avec `langchain.chat_models.init_chat_model` disponible (Task 2).
- Produces: `get_llm_instance()` et `validate_llm_available()` avec signature et logique de repli inchangées ; `_get_openai_instance`/`_get_ollama_instance` utilisant `init_chat_model` en interne ; `_get_nvidia_instance` migrée ou non selon le support constaté du provider `"nvidia"`.

- [ ] **Step 1: Vérifier si `init_chat_model` supporte le provider `"nvidia"`**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
poetry run python -c "
from langchain.chat_models import init_chat_model
try:
    m = init_chat_model(model='dummy-model', model_provider='nvidia', api_key='dummy', base_url='https://example.com')
    print('NVIDIA_SUPPORTED: OK')
except Exception as e:
    print('NVIDIA_SUPPORTED:', type(e).__name__, str(e)[:200])
"
```
Attendu : soit `NVIDIA_SUPPORTED: OK` (le provider est reconnu — l'instanciation avec des valeurs factices ne lève pas d'erreur de provider inconnu, même si `dummy-model`/`dummy` provoqueraient une erreur d'authentification à l'usage réel), soit une erreur explicite mentionnant que `"nvidia"` n'est pas un provider reconnu (ex: `ValueError` citant la liste des providers supportés). Documenter le résultat exact dans le rapport de tâche — il détermine le Step 4.

- [ ] **Step 2: Remplacer l'instanciation Groq dans `get_llm_instance`**

Dans `src/tenderai_bf/utils/llm_utils.py`, dans le bloc `if provider == "groq":`, remplacer :
```python
            try:
                from langchain_groq import ChatGroq

                llm = ChatGroq(
                    api_key=settings.llm.groq_api_key.get_secret_value(),
                    model_name=settings.llm.groq_model,
                    temperature=temperature,
                    max_tokens=max_tokens,
                )
                logger.debug(
                    "LLM instance created",
                    provider="groq",
                    model=settings.llm.groq_model,
                )
                return llm

            except ImportError:
```
par :
```python
            try:
                from langchain.chat_models import init_chat_model

                llm = init_chat_model(
                    model=settings.llm.groq_model,
                    model_provider="groq",
                    api_key=settings.llm.groq_api_key.get_secret_value(),
                    temperature=temperature,
                    max_tokens=max_tokens,
                )
                logger.debug(
                    "LLM instance created",
                    provider="groq",
                    model=settings.llm.groq_model,
                )
                return llm

            except ImportError:
```
(Le reste du bloc `try`/`except ImportError`/`except Exception` — non montré ici — reste inchangé ; seul le corps du `try` change.)

- [ ] **Step 3: Remplacer l'instanciation OpenAI et Ollama**

Dans `_get_openai_instance`, remplacer :
```python
        from langchain_openai import ChatOpenAI

        llm = ChatOpenAI(
            api_key=settings.llm.openai_api_key.get_secret_value(),
            model_name=settings.llm.openai_model,
            temperature=temperature,
            max_tokens=max_tokens,
        )
```
par :
```python
        from langchain.chat_models import init_chat_model

        llm = init_chat_model(
            model=settings.llm.openai_model,
            model_provider="openai",
            api_key=settings.llm.openai_api_key.get_secret_value(),
            temperature=temperature,
            max_tokens=max_tokens,
        )
```

Dans `_get_ollama_instance`, remplacer :
```python
        from langchain_ollama import ChatOllama

        # Get Ollama configuration from settings
        ollama_base_url = getattr(
            settings.llm, "ollama_base_url", "http://localhost:11434"
        )
        ollama_model = getattr(settings.llm, "ollama_model", "llama3.1")

        llm = ChatOllama(
            base_url=ollama_base_url,
            model=ollama_model,
            temperature=temperature,
            num_predict=max_tokens,  # Ollama uses num_predict instead of max_tokens
        )
```
par :
```python
        from langchain.chat_models import init_chat_model

        # Get Ollama configuration from settings
        ollama_base_url = getattr(
            settings.llm, "ollama_base_url", "http://localhost:11434"
        )
        ollama_model = getattr(settings.llm, "ollama_model", "llama3.1")

        llm = init_chat_model(
            model=ollama_model,
            model_provider="ollama",
            base_url=ollama_base_url,
            temperature=temperature,
            num_predict=max_tokens,  # Ollama uses num_predict instead of max_tokens
        )
```

- [ ] **Step 4a — SI le Step 1 a confirmé `NVIDIA_SUPPORTED: OK`** : migrer `_get_nvidia_instance`

Dans `_get_nvidia_instance`, remplacer :
```python
        from langchain_nvidia_ai_endpoints import ChatNVIDIA

        llm = ChatNVIDIA(
            api_key=settings.llm.nvidia_api_key.get_secret_value(),
            model=settings.llm.nvidia_model,
            base_url=settings.llm.nvidia_base_url,
            temperature=temperature,
            max_tokens=max_tokens,
        )
```
par :
```python
        from langchain.chat_models import init_chat_model

        llm = init_chat_model(
            model=settings.llm.nvidia_model,
            model_provider="nvidia",
            api_key=settings.llm.nvidia_api_key.get_secret_value(),
            base_url=settings.llm.nvidia_base_url,
            temperature=temperature,
            max_tokens=max_tokens,
        )
```

- [ ] **Step 4b — SI le Step 1 a confirmé que `"nvidia"` n'est pas supporté** : ne rien changer dans `_get_nvidia_instance`

`_get_nvidia_instance` garde son instanciation directe `ChatNVIDIA` telle quelle. Documenter ce choix dans le rapport de tâche (adoption partielle assumée, conforme à la spec).

- [ ] **Step 5: Vérifier que le test mockant `get_llm_instance` passe toujours**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run pytest tests/test_pipeline_country.py -v --no-cov -k "summary or llm"
```
Attendu : mêmes résultats que la baseline (ce test mocke `get_llm_instance` entièrement, donc le refactor interne ne devrait rien changer à son résultat).

- [ ] **Step 6: Smoke-test d'instanciation réelle avec le provider configuré par défaut (Groq)**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
poetry run python -c "
import os
os.environ.setdefault('TENDERAI_JWT_SECRET', 'test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx')
os.environ.setdefault('TENDERAI_ADMIN_PASSWORD', 'test-admin-password-not-real')
from tenderai_bf.utils.llm_utils import get_llm_instance
from tenderai_bf.config import settings
if settings.llm.groq_api_key.get_secret_value():
    llm = get_llm_instance(provider='groq')
    print('LLM_INSTANCE:', type(llm).__name__ if llm else None)
else:
    print('LLM_INSTANCE: skipped (no GROQ_API_KEY configured in this environment)')
"
```
Attendu : soit `LLM_INSTANCE: <ClassName>` (pas `None` — confirme que l'instanciation via `init_chat_model` réussit avec de vrais identifiants), soit le message `skipped` si aucune clé Groq n'est configurée dans cet environnement (auquel cas cette vérification est reportée à Task 8, qui utilisera l'environnement de test avec `.env` configuré).

- [ ] **Step 7: Commit**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
git add src/tenderai_bf/utils/llm_utils.py
git commit -m "refactor(llm): adopt init_chat_model for provider instantiation, preserve fallback logic"
```

---

## Task 7: Vérifier `classify.py` (consommateur indirect, aucun changement de code attendu)

**Files:** aucun (vérification uniquement — `classify.py` n'a pas d'import direct LangChain, il consomme uniquement le retour de `get_llm_instance()` via `.invoke(...).content`).

**Interfaces:**
- Consumes: `llm_utils.py` mis à jour (Task 6).

- [ ] **Step 1: Confirmer que le pattern `.invoke().content` reste valide**

`src/tenderai_bf/agents/nodes/classify.py` appelle `llm.invoke(prompt)` puis accède à `response.content` (lignes 255-257 et 744-746). Comme `AIMessage` hérite de `BaseMessage`, `.content` reste accessible sans changement de code. Vérifier via les tests existants plutôt que par lecture seule :

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run pytest tests/nodes/test_classify.py -v --no-cov
```
Attendu : mêmes résultats que la baseline Task 1 pour ce fichier (aucune régression).

- [ ] **Step 2: Aucun commit attendu pour cette tâche** (vérification uniquement, pas de modification de code).

---

## Task 8: Vérification finale — suite complète, exécution réelle, comparaison structurelle

**Files:** aucun (vérification uniquement).

**Interfaces:**
- Consumes: toutes les tâches précédentes complètes.
- Produces: confirmation finale que la montée de version n'a introduit aucune régression — critère de complétion du sous-projet A.

- [ ] **Step 1: Suite de tests complète**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run pytest tests/ -v --no-cov > /tmp/langchain-upgrade-baseline/test-results-after.txt 2>&1
echo "exit code: $?" >> /tmp/langchain-upgrade-baseline/test-results-after.txt
diff <(grep -E "PASSED|FAILED|ERROR" /tmp/langchain-upgrade-baseline/test-results-before.txt | sort) \
     <(grep -E "PASSED|FAILED|ERROR" /tmp/langchain-upgrade-baseline/test-results-after.txt | sort)
```
Attendu : la commande `diff` ne doit montrer aucun test passant en `PASSED` avant et `FAILED`/`ERROR` après (une ligne `<` sans `>` correspondante pour un test qui a un statut PASSED signale une régression — investiguer avant de continuer). Des tests déjà en échec avant qui restent en échec après (mêmes lignes des deux côtés) sont acceptables (dette préexistante documentée en Task 1).

- [ ] **Step 2: Copier le résultat "after" dans le repo pour traçabilité**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
cp /tmp/langchain-upgrade-baseline/test-results-after.txt docs/superpowers/artifacts/2026-08-25-langchain-upgrade-test-after.txt
git add docs/superpowers/artifacts/2026-08-25-langchain-upgrade-test-after.txt
git commit -m "docs: capture test results after LangChain/LangGraph upgrade"
```

- [ ] **Step 3: Construire une stack isolée à partir de CE worktree et exécuter le pipeline en mode test**

**Important** : le stack Docker de développement déjà actif sur cette machine (containers `tenderai-postgres`, `tenderai-minio`, `tenderai-api`, `tenderai-worker`, `tenderai-frontend`, projet `tender-ai`, observé pendant le chantier 1) tourne avec une image construite depuis `/home/yulcom/web/tender-ai` (le checkout principal) — **il ne reflète PAS les changements de code faits dans ce worktree** (Tasks 2-7 ci-dessus). L'utiliser directement testerait l'ancien code, pas la montée de version. Construire à la place une stack isolée depuis ce worktree, sur le même principe d'isolation que celui qui a fonctionné de manière fiable pendant le chantier 1 (nom de projet dédié, noms de containers suffixés, ports dédiés — ne jamais toucher aux containers `tenderai-postgres`/`tenderai-minio`/`tenderai-api`/`tenderai-worker`/`tenderai-frontend` sans suffixe, qui appartiennent au stack live de l'utilisateur).

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
cp .env.example .env
docker-compose -p tenderai-lcupgrade-val up -d --build postgres minio createbuckets api
```
Attendu : build de l'image `api` réussi (peut prendre du temps sur cette machine partagée — voir les leçons du chantier 1 sur la charge mémoire ; ne jamais lancer un second build en parallèle). Suivre avec `docker-compose -p tenderai-lcupgrade-val ps` jusqu'à ce que `api` soit `healthy` (poll avec `sleep 15`+ entre chaque vérification, jamais de boucle serrée). `worker` n'est pas nécessaire ici : `tenderai run-once` s'exécute de façon synchrone via la CLI dans le container `api`, indépendamment du scheduler du worker.

```bash
docker-compose -p tenderai-lcupgrade-val exec -T api alembic upgrade head
docker-compose -p tenderai-lcupgrade-val exec -T api tenderai seed-sources
docker-compose -p tenderai-lcupgrade-val exec -T api tenderai run-once --test --country-code BF
```
(flag confirmé : `--test` — pas `--test-mode` — envoie le rapport uniquement à l'email admin plutôt qu'à tous les destinataires ; voir `src/tenderai_bf/cli.py:39-45`. Adapter `--country-code` au code pays réellement configuré si `BF` n'existe pas après le seed — vérifier via `docker-compose -p tenderai-lcupgrade-val exec -T api tenderai run-once --help` ou la table `countries` si besoin.)

Attendu : la commande `run-once` se termine sans exception non gérée (code de sortie 0), un `Run` est créé en base avec un statut `completed` ou `completed_with_warnings`.

- [ ] **Step 4: Comparaison structurelle du `Run` produit**

```bash
docker-compose -p tenderai-lcupgrade-val exec -T api poetry run python -c "
from tenderai_bf.db import get_db_context
from tenderai_bf.models import Run
with get_db_context() as db:
    run = db.query(Run).order_by(Run.started_at.desc()).first()
    print('status:', run.status)
    print('error_message:', run.error_message)
    print('counts_json keys:', sorted((run.counts_json or {}).keys()))
"
```
Attendu : `status` est `completed` ou `completed_with_warnings` (pas `failed`), `error_message` est `None` ou correspond à un warning non-fatal déjà connu (ex: SMTP), `counts_json keys` liste des clés cohérentes avec `RunStatistics` (mêmes noms de champs qu'avant la montée de version — ce schéma n'a pas été touché par ce plan). Documenter le résultat exact dans le rapport de tâche final.

- [ ] **Step 4bis: Nettoyer la stack isolée**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
docker-compose -p tenderai-lcupgrade-val down -v
docker rmi $(docker images -q "repo-split-*" 2>/dev/null) 2>/dev/null || true
```
Confirmer ensuite que le stack live de l'utilisateur (sans suffixe) est toujours intact :
```bash
docker ps --format "{{.Names}}\t{{.Status}}" | grep -E "^tenderai-(postgres|minio|api|worker|frontend)\s"
```
Attendu : les 5 containers toujours présents, `Up`, avec une durée d'activité ininterrompue (pas de redémarrage récent).

- [ ] **Step 5: Résumé final**

Rédiger un court résumé dans le rapport de tâche : versions finales installées (`langchain`, `langgraph`, packages provider), décisions prises aux points de branchement (Task 5 : `_AppWrapper` retiré ou conservé ; Task 6 : NVIDIA migré ou non vers `init_chat_model`), résultat de la comparaison de tests (0 régression attendu), résultat de l'exécution réelle. Ce résumé constitue la preuve de complétion du sous-projet A.
