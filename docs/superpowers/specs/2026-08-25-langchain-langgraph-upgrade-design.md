# Montée de version LangChain/LangGraph (sous-projet A du chantier 2) — Design

**Date :** 2026-08-25
**Chantier :** 2/4 de la refonte SaaS (modernisation des dépendances). Ce document couvre uniquement le **sous-projet A** : la montée de version LangChain/LangGraph et les breaking changes qu'elle entraîne. Les sous-projets B (correction du lint ruff) et C (couverture de tests 40%→80%) sont hors scope de ce document et feront chacun l'objet de leur propre spec, exécutés dans cet ordre après A.

## Contexte

Le chantier 1 (séparation en 3 repos) est terminé côté automatisable (Tasks 1-10), en attente de la confirmation utilisateur pour les tâches de déploiement (Tasks 11-14). Conformément à l'ordre fixé par l'utilisateur, le chantier 2 (modernisation des dépendances) démarre en parallèle.

`pyproject.toml` épingle `langchain = "^0.2.0"` et `langgraph = "^0.1.0"`. Les dernières versions stables sont `langchain 1.3.16` et `langgraph 1.2.11` — l'écart traverse le passage majeur 0.x→1.0 pour les deux packages.

## Audit de l'empreinte réelle dans le code

Recherche exhaustive des imports directs (`grep -rl "from langchain\|import langchain\|from langgraph\|import langgraph" src/`) : **5 fichiers seulement**, plus 1 fichier de test.

| Fichier | Usage |
|---|---|
| `src/tenderai_bf/agents/graph.py` | `from langgraph.graph import END, StateGraph` — cœur de l'orchestration du pipeline |
| `src/tenderai_bf/agents/nodes/deduplicate.py` | `from langchain.prompts import PromptTemplate` (import différé, dans une fonction) |
| `src/tenderai_bf/agents/nodes/summarize.py` | `from langchain.prompts import PromptTemplate` (import différé) |
| `src/tenderai_bf/agents/nodes/parse_pdf_rag.py` | `from langchain.text_splitter import RecursiveCharacterTextSplitter` |
| `src/tenderai_bf/utils/llm_utils.py` | Factory multi-provider : `ChatGroq`, `ChatOpenAI`, `ChatOllama`, `ChatNVIDIA` (imports différés avec repli en cas d'échec) |
| `tests/test_pipeline_country.py` | Mock de `graph.app.invoke` |

`src/tenderai_bf/agents/nodes/vector_store.py` utilise `chromadb` et `sentence-transformers` **directement**, sans passer par les abstractions LangChain (`VectorStore`/`Embeddings`) — confirmé hors périmètre de ce sous-projet.

`langchain-community` est déclaré dans `pyproject.toml` mais aucun usage direct n'a été trouvé dans `src/` — à investiguer en implémentation (dépendance transitive réellement nécessaire, ou résidu mort à supprimer).

## Décisions validées

### 1. Stratégie de montée de version
Passage direct vers la dernière version stable pour chaque package (pas de montée par paliers intermédiaires). Un seul passage, tous les breaking changes corrigés en une fois.

### 2. Versions cibles
- `langchain` : `^0.2.0` → `^1.3.0`
- `langgraph` : `^0.1.0` → `^1.2.0`
- `langchain-groq`, `langchain-openai`, `langchain-ollama`, `langchain-nvidia-ai-endpoints` : bump vers leurs dernières versions compatibles avec `langchain ^1.3.0`
- Nouvelle dépendance directe : `langchain-text-splitters` (voir Section imports)
- `langchain-community` : décision (garder/retirer) prise en implémentation après investigation de son usage réel

### 3. Chemins d'import cassés par LangChain v1

Confirmé contre la documentation officielle (via context7, doc à jour) : LangChain v1 déplace tout le legacy (chains, retrievers, indexing API, hub) vers un nouveau package `langchain-classic`, et resserre l'espace de noms principal `langchain`.

| Fichier | Import actuel | Nouveau chemin |
|---|---|---|
| `deduplicate.py`, `summarize.py` | `from langchain.prompts import PromptTemplate` | `from langchain_core.prompts import PromptTemplate` |
| `parse_pdf_rag.py` | `from langchain.text_splitter import RecursiveCharacterTextSplitter` | `from langchain_text_splitters import RecursiveCharacterTextSplitter` |

`langchain_core` est le package de primitives stables, non affecté par la purge du legacy — c'est le chemin canonique recommandé indépendamment du fait que l'ancien réexport `langchain.prompts`/`langchain.text_splitter` survive ou non en v1.

### 4. LangGraph — point d'entrée du graphe

`graph.py` utilise actuellement `workflow.set_entry_point("load_sources")` (API historique). Tous les exemples à jour de la documentation LangGraph 1.x utilisent `from langgraph.graph import START` puis `workflow.add_edge(START, "load_sources")`. Migration vers ce pattern — low-risk, aucun changement de comportement attendu.

### 5. LangGraph — coercition de l'état retourné

Le commentaire existant sur `_coerce_to_state` (« Older LangGraph versions return dicts, newer ones may return the Pydantic instance itself ») anticipait déjà cette instabilité inter-versions. Décision : vérifier concrètement ce que retourne `.invoke()` en 1.2.x en implémentation, et conserver la coercition défensive dans tous les cas (coût nul, filet de sécurité qui ne dépend pas de la version exacte).

### 6. `_AppWrapper` — évaluation de suppression

Ce wrapper (`agents/graph.py`) existe uniquement pour contourner le fait que l'ancien `CompiledStateGraph` (basé Pydantic v1) refusait l'assignation d'attributs arbitraires — nécessaire pour que `tests/test_pipeline_country.py` puisse faire `graph.app.invoke = mock_invoke`. Décision : tester en implémentation si `CompiledStateGraph` de LangGraph 1.x accepte nativement l'assignation d'attributs. Si oui, retirer `_AppWrapper` et le remplacer par `self.app = self.graph.compile()` direct — **uniquement après confirmation que le test de mock fonctionne toujours sans le wrapper**. Aucune suppression spéculative si le test échoue.

### 7. Breaking change : type de retour des chat models

Confirmé contre la documentation officielle : en LangChain v1, `.invoke()` sur un chat model retourne `AIMessage` au lieu de `BaseMessage`. Comme `AIMessage` hérite de `BaseMessage`, l'accès à `.content` (utilisé dans `deduplicate.py`, `summarize.py`, potentiellement `classify.py`) doit rester compatible sans changement de code — à vérifier concrètement en implémentation via l'exécution des tests concernés et une exécution réelle du pipeline.

### 8. Factory LLM (`llm_utils.py`) — adoption partielle de `init_chat_model`

Confirmé contre la documentation officielle : `init_chat_model` (`from langchain.chat_models import init_chat_model`) est bien l'API unifiée officielle pour instancier un chat model par provider. Décision : elle ne remplace que l'instanciation brute — toute la logique métier actuelle de `get_llm_instance()` (repli Groq→OpenAI si `fallback=True`, vérification des clés API par provider avant instanciation, gestion `ImportError` avec message clair) **doit être préservée telle quelle**, car c'est un comportement applicatif délibéré et non une limitation de l'ancienne API.

Approche retenue : garder `get_llm_instance()` et `validate_llm_available()` comme points d'entrée publics inchangés dans leur signature et leur logique de repli ; remplacer l'intérieur de `_get_openai_instance()`, `_get_ollama_instance()` par un appel à `init_chat_model(model=..., model_provider="openai"/"ollama", ...)`, et de même pour Groq (intégré dans `get_llm_instance()` directement) — **si et seulement si** `init_chat_model` supporte nativement le provider `"nvidia"` pour `_get_nvidia_instance()` (à vérifier en implémentation contre la liste des providers supportés par la version installée). Si NVIDIA n'est pas supporté par `init_chat_model`, cette fonction reste sur l'instanciation directe `ChatNVIDIA` — adoption partielle assumée plutôt que réécriture uniforme forcée.

### 9. Vérification — suite de tests, exécution réelle, comparaison structurelle avant/après

Les nœuds `classify`, `deduplicate`, `summarize` appellent de vrais LLM — une comparaison avant/après en **texte exact** produirait des faux positifs (non-déterminisme normal des LLM, même à température basse, indépendant de la version des bibliothèques). La vérification porte donc sur la **structure**, pas le contenu textuel généré :

1. **Suite de tests existante** : baseline capturée avant tout changement de code (`make test`, ou `poetry run pytest tests/ -v --no-cov` pour isoler du gate de couverture déjà connu comme hors périmètre). Après la montée de version, aucun test qui passait avant ne doit échouer. Les échecs déjà présents avant la montée de version (dette préexistante, hors périmètre de ce sous-projet) restent tolérés mais ne doivent pas augmenter en nombre.
2. **Exécution réelle du pipeline** : `poetry run tenderai run-once --test-mode` (flag CLI existant — limite l'envoi d'email à l'admin seul, ne touche pas aux vrais destinataires). Vérifie que le pipeline s'exécute de bout en bout sans exception non gérée.
3. **Comparaison structurelle avant/après** : capture du `Run` produit par l'exécution réelle ci-dessus (statut final, clés et types de `counts_json`, absence de nouvelle erreur) — une fois avant la montée de version, une fois après. Le statut final doit rester dans la même classe (`completed` ou `completed_with_warnings`, jamais `failed` si ce n'était pas déjà le cas avant), sans exiger une égalité de texte généré par le LLM.

## Hors scope de ce sous-projet

- Correction des ~100 violations ruff (sous-projet B, spec séparée).
- Écriture de tests pour atteindre 80% de couverture (sous-projet C, spec séparée).
- `vector_store.py` (ChromaDB/sentence-transformers) — confirmé non couplé à LangChain, aucune modification nécessaire.
- Migration vers les abstractions LangChain `create_agent`/`tools`/`messages` — le pipeline utilise `StateGraph` directement avec des fonctions `_node` explicites, pattern plus simple que l'abstraction agent de LangChain ; aucune raison d'introduire cette complexité.
- Réécriture de `TenderAIState` en `TypedDict` ou modernisation de la syntaxe Pydantic (`class Config` → `model_config = ConfigDict(...)`) — tangentiel à la montée LangChain/LangGraph, `BaseModel` reste un type d'état supporté par LangGraph 1.x ; à ne traiter que si l'implémentation révèle un besoin réel (YAGNI).

## Fichiers touchés (aperçu)

```
pyproject.toml, poetry.lock                    — bump versions + langchain-text-splitters
src/tenderai_bf/agents/graph.py                — START/add_edge, _coerce_to_state, _AppWrapper (évaluation)
src/tenderai_bf/agents/nodes/deduplicate.py    — import PromptTemplate
src/tenderai_bf/agents/nodes/summarize.py      — import PromptTemplate
src/tenderai_bf/agents/nodes/parse_pdf_rag.py  — import RecursiveCharacterTextSplitter
src/tenderai_bf/utils/llm_utils.py             — init_chat_model (adoption partielle)
tests/test_pipeline_country.py                 — vérification du mock si _AppWrapper est retiré
```

## Points ouverts pour le plan d'implémentation

- Statut exact de `langchain-community` (garder ou retirer) — investigation à mener en tâche 1 du plan, avant tout autre changement.
- Support de `"nvidia"` comme provider par `init_chat_model` dans la version installée — détermine si `_get_nvidia_instance()` est migrée ou reste sur l'instanciation directe.
- Type exact retourné par `StateGraph(...).compile().invoke()` en LangGraph 1.2.x (dict vs instance Pydantic) — déterminera si `_coerce_to_state` peut être simplifié (mais restera défensif dans tous les cas).
- Nécessité réelle de `_AppWrapper` — déterminée par un test direct de `graph.app.invoke = mock_invoke` sur un `CompiledStateGraph` non wrappé.
