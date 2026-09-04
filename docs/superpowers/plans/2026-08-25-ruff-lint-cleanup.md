# Correction du lint ruff (sous-projet B, chantier 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ramener `poetry run ruff check src tests` à zéro violation active (150 → 0), en distinguant les corrections de comportement réelles (logging au lieu d'avaler silencieusement une exception, `raise ... from`, renommage) des faux positifs à documenter explicitement via `# noqa` avec justification — sans jamais supprimer un `noqa` qui masquerait un vrai risque.

**Architecture:** Le lint n'a jamais été activé en CI avant ce chantier (confirmé pendant le chantier 1 : l'ancien `ci-cd.yml` ne lançait jamais `ruff check`). Ce plan traite la dette en 5 passes ordonnées par risque croissant : (1) auto-fix mécanique sans risque comportemental, (2) imports E402 intentionnels à documenter, (3) violations de sécurité bandit examinées une par une (mélange de vraies corrections et de faux positifs justifiés), (4) corrections manuelles restantes (renommage, `raise from`, simplification de `if` imbriqués), (5) vérification finale.

**Tech Stack:** ruff (déjà configuré dans `pyproject.toml`), pytest pour la non-régression.

**Spec:** Aucune spec séparée — ce plan est un sous-projet bounded du chantier 2, brainstormé directement en conversation (voir la conversation pour le design validé point par point sur les 19 violations de sécurité).

## Point de sécurité signalé, hors périmètre de ce sous-projet

`fetch_quotidien.py` désactive la vérification SSL (`verify=False`) pour contourner un certificat expiré sur le site DGCMEF (gouvernemental) — un vrai risque MITM, préexistant à ce chantier et non introduit par lui. Ce plan documente ce risque via `noqa` justifié (Task 3, Step 11) plutôt que de le corriger, décision validée explicitement avec l'utilisateur. **Ticket séparé recommandé** pour remplacer `verify=False` par un contexte SSL ciblé (épinglage du certificat ou exception limitée à ce host précis) — hors périmètre d'un chantier de nettoyage de lint.

## Global Constraints

- Toute correction touchant à `try/except` (S110, E722) doit **garder le comportement non-bloquant existant** — ces blocs sont des chemins de best-effort/nettoyage volontairement non-fatals ; on ajoute de la visibilité (`logger.debug(...)`), on ne fait jamais remonter l'exception si le code existant ne le faisait pas.
- Chaque `# noqa` ajouté doit porter une justification en commentaire sur la ligne précédente ou la même ligne — jamais un `noqa` nu sans explication.
- `hashlib.md5(..., usedforsecurity=False)` est le traitement correct pour les 3 usages de MD5 identifiés (génération d'ID non cryptographique) — pas de `noqa`, c'est le mécanisme officiellement supporté par Python 3.9+ pour ce cas exact.
- Aucun renommage de variable ne doit changer une signature publique ou un nom de champ sérialisé (DB, JSON, config) — uniquement des variables locales.
- Après chaque tâche : `poetry run ruff check src tests` doit montrer une diminution du nombre total de violations (jamais une régression), et la suite de tests doit produire les mêmes résultats qu'avant la tâche (comparaison stricte contre la baseline de ce plan, capturée en Task 1).

---

## File Structure

Aucun nouveau fichier — corrections in-place réparties sur ~25 fichiers existants dans `src/tenderai_bf/` et `tests/`. Détail des fichiers touchés par tâche ci-dessous.

---

## Task 1: Baseline et auto-fix mécanique sans risque

**Files:**
- Modify: tous les fichiers listés par `ruff check --fix` pour les règles sûres (voir Step 3) — ruff applique les correctifs automatiquement, pas d'édition manuelle.

**Interfaces:**
- Produces: baseline de tests et de lint avant tout changement — consommée par Task 5 (vérification finale).

- [ ] **Step 1: Capturer le nombre de violations actuel**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run ruff check src tests 2>&1 | tail -3
```
Attendu : `Found 150 errors.` (ou un nombre proche — confirmer le total exact avant de commencer, il sert de référence pour Task 5).

- [ ] **Step 2: Capturer la baseline de tests**

```bash
mkdir -p /tmp/ruff-cleanup-baseline
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run pytest tests/ -v --no-cov > /tmp/ruff-cleanup-baseline/test-results-before.txt 2>&1
echo "exit code: $?" >> /tmp/ruff-cleanup-baseline/test-results-before.txt
grep -E "passed|failed" /tmp/ruff-cleanup-baseline/test-results-before.txt | tail -3
```
Attendu : `101 passed, 18 failed` (même résultat que les baselines des chantiers précédents — aucun service Docker requis dans ce worktree, ces 18 échecs sont connus et environnementaux).

- [ ] **Step 3: Appliquer l'auto-fix sur les règles mécaniques sans risque comportemental**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
poetry run ruff check src tests \
  --select I001,W291,UP017,SIM105,F841,E712,B007,SIM114,F401,UP038,RUF005,RUF013 \
  --fix
```
Attendu : ruff rapporte les corrections appliquées (imports triés, espaces en fin de ligne supprimés, `datetime.UTC` au lieu de l'ancien alias, `contextlib.suppress` au lieu de `try/except/pass` trivial, variables inutilisées supprimées, `cond is True` au lieu de `== True`, variable de boucle inutilisée préfixée `_`, branches `if` combinées, imports inutilisés supprimés, syntaxe `X | Y` modernisée, unpacking par itérable, `Optional` implicite explicité).

- [ ] **Step 4: Vérifier qu'aucun test ne régresse**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run pytest tests/ -v --no-cov 2>&1 | tail -5
```
Attendu : `101 passed, 18 failed` — identique à Step 2. Si un test qui passait avant échoue maintenant, ne pas continuer : identifier quelle correction auto-fix l'a cassé (`git diff` fichier par fichier) et soit corriger l'usage, soit exclure cette règle spécifique de l'auto-fix pour ce fichier via un commit `git checkout -- <fichier>` ciblé avant de continuer.

- [ ] **Step 5: Vérifier le nombre de violations restantes**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run ruff check src tests 2>&1 | tail -3
```
Attendu : le nombre total a diminué (environ 150 → ~110-115, selon le nombre exact de violations couvertes par ces règles).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "style(lint): auto-fix mechanical ruff violations (imports, whitespace, modern syntax)

No behavior change — ruff --fix on rules with zero semantic risk
(import sorting, trailing whitespace, datetime.UTC alias, unused
variables/imports, contextlib.suppress, comparison style)."
```

---

## Task 2: Documenter les imports E402 intentionnels

**Files:**
- Modify: `src/tenderai_bf/__init__.py:22-23`
- Modify: `src/tenderai_bf/db.py:196` (déplacer, pas documenter — voir ci-dessous)
- Modify: `tests/api/test_settings_endpoints.py:14-15`
- Modify: `tests/nodes/test_classify.py:165`
- Modify: `tests/nodes/test_deduplicate.py:172`
- Modify: `tests/nodes/test_load_sources.py:8-10`
- Modify: `tests/test_cfg_helper.py:8-9`
- Modify: `tests/test_country_store.py:12`
- Modify: `tests/test_settings_store.py:12`

**Interfaces:**
- Consumes: aucune dépendance sur Task 1.
- Produces: zéro violation E402 active, avec justification explicite partout où l'ordre est intentionnel.

- [ ] **Step 1: `src/tenderai_bf/__init__.py` — ordre intentionnel (shim bcrypt avant les imports)**

Dans `src/tenderai_bf/__init__.py`, les imports `from .config import settings` et `from .db import get_db, get_engine` (lignes 22-23) doivent rester après le shim de compatibilité bcrypt/passlib (lignes 7-13), car ce shim doit s'exécuter avant que la chaîne d'imports de `.config`/`.db` ne déclenche l'import de `passlib`. Ajouter `# noqa: E402` sur ces deux lignes :

```python
from .config import settings  # noqa: E402 — must run after the bcrypt/passlib compat shim above
from .db import get_db, get_engine  # noqa: E402 — must run after the bcrypt/passlib compat shim above
```

- [ ] **Step 2: `src/tenderai_bf/db.py` — déplacer `import time` en haut du fichier (vraie correction, pas de raison de le garder en bas)**

Vérifier d'abord qu'aucune dépendance d'ordre ne justifie sa position actuelle (ligne 196, après `except Exception as e:` d'une fonction) :
```bash
grep -n "^import\|^from" src/tenderai_bf/db.py
```
Confirmer que `import time` (ligne 196) n'a aucune raison de venir après les imports SQLAlchemy/config/logging (lignes 3-12) — c'est un import stdlib sans dépendance. Le déplacer en haut du fichier, dans le bloc d'imports existant (après `from contextlib import contextmanager`, avant la ligne vide qui précède les imports SQLAlchemy) :

```python
from collections.abc import Generator
from contextlib import contextmanager
import time

from sqlalchemy import create_engine, event, text
```

Supprimer la ligne `import time` originale à la ligne ~196 (garder le commentaire `# Register all ORM models...` et la ligne `from . import models as _models  # noqa: F401, E402` qui suit — cet import-là reste en bas intentionnellement, pour des raisons d'enregistrement SQLAlchemy, et porte déjà son propre noqa, hors périmètre de cette tâche).

- [ ] **Step 3: Fichiers de test — `os.environ.setdefault(...)` doit précéder l'import de `tenderai_bf`**

Pour chacun des fichiers suivants, les imports de modules `tenderai_bf.*` (et `unittest.mock`/`pytest` dans certains cas) sont placés après des appels `os.environ.setdefault(...)` nécessaires pour configurer `TENDERAI_JWT_SECRET`/`TENDERAI_ADMIN_PASSWORD`/etc. avant que `tenderai_bf.config` ne valide ces variables à l'import. Ajouter `# noqa: E402` sur chaque ligne d'import signalée, avec le même commentaire :

- `tests/api/test_settings_endpoints.py` lignes 14-15
- `tests/nodes/test_classify.py` ligne 165
- `tests/nodes/test_deduplicate.py` ligne 172
- `tests/nodes/test_load_sources.py` lignes 8-10
- `tests/test_cfg_helper.py` lignes 8-9
- `tests/test_country_store.py` ligne 12
- `tests/test_settings_store.py` ligne 12

Exemple de traitement (motif identique dans chaque fichier) :
```python
import os
os.environ.setdefault("TENDERAI_JWT_SECRET", "...")
os.environ.setdefault("TENDERAI_ADMIN_PASSWORD", "...")

from unittest.mock import patch, MagicMock  # noqa: E402 — must follow env var setup above
from tenderai_bf.agents.graph import TenderAIState  # noqa: E402 — must follow env var setup above
```

- [ ] **Step 4: Vérifier zéro violation E402 restante**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run ruff check src tests --select E402
```
Attendu : `All checks passed!`

- [ ] **Step 5: Vérifier qu'aucun test ne régresse**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run pytest tests/ -v --no-cov 2>&1 | tail -5
```
Attendu : `101 passed, 18 failed` — identique à la baseline (le déplacement de `import time` dans `db.py` ne doit rien casser, c'est un import stdlib pur).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "style(lint): resolve E402 — document intentional import ordering, move stray import time

__init__.py and test files intentionally import after required setup
(bcrypt shim, env var configuration) — documented with noqa + reason.
db.py's stray 'import time' had no ordering dependency, moved to the
top of the file."
```

---

## Task 3: Violations de sécurité (bandit) — examinées une par une

**Files:**
- Modify: `src/tenderai_bf/agents/nodes/fetch_playwright.py:163,214`
- Modify: `src/tenderai_bf/agents/nodes/parse_quotidien_docling.py:83,244`
- Modify: `src/tenderai_bf/api/routers/countries.py:132`
- Modify: `src/tenderai_bf/api/routers/health.py:169,178`
- Modify: `src/tenderai_bf/email/smtp_client.py:315,394`
- Modify: `tests/api/test_countries_endpoints.py:86`
- Modify: `src/tenderai_bf/agents/nodes/fetch_quotidien.py:38,158`
- Modify: `src/tenderai_bf/agents/nodes/parse_extract.py:417,518`
- Modify: `src/tenderai_bf/agents/nodes/vector_store.py:94`
- Modify: `src/tenderai_bf/api/main.py:163`
- Modify: `src/tenderai_bf/api/routers/admin.py:83`
- Modify: `src/tenderai_bf/email/__init__.py:24`
- Modify: `tests/nodes/run_all_tests.py:50`

**Interfaces:**
- Consumes: aucune dépendance sur Tasks 1-2.
- Produces: zéro violation bandit (`--select S`) active, chaque traitement documenté et justifié individuellement.

### Groupe A — `S110`/`E722` (try/except silencieux) : ajouter un logging de debug, garder le comportement non-bloquant

- [ ] **Step 1: `fetch_playwright.py` — attente de sélecteur non-critique (2 occurrences)**

Ligne 163, dans la boucle de pagination :
```python
        try:
            await page.wait_for_selector(wait_selector, timeout=wait_timeout)
        except Exception:
            pass
```
remplacer par :
```python
        try:
            await page.wait_for_selector(wait_selector, timeout=wait_timeout)
        except Exception as e:
            logger.debug("Selector wait timed out, continuing anyway", selector=wait_selector, error=str(e))
```
Répéter le même traitement pour l'occurrence à la ligne 214 (vérifier le contexte exact avec `sed -n '205,220p' src/tenderai_bf/agents/nodes/fetch_playwright.py` avant d'éditer — le message de log doit refléter le contexte réel de cette seconde occurrence, probablement une attente similaire dans une autre boucle).

- [ ] **Step 2: `parse_quotidien_docling.py` — nettoyage de fichier temp et bare except (2 occurrences)**

Ligne 83 (nettoyage de fichier temporaire) :
```python
            try:
                os.unlink(tmp_path)
            except:
                pass
```
remplacer par :
```python
            try:
                os.unlink(tmp_path)
            except OSError as e:
                logger.debug("Failed to clean up temp file", path=tmp_path, error=str(e))
```
(remplace aussi `E722` bare except par une exception typée — `OSError` couvre `FileNotFoundError`/`PermissionError`, les cas réels d'échec d'`os.unlink`.)

Ligne 244 : lire le contexte (`sed -n '235,250p' src/tenderai_bf/agents/nodes/parse_quotidien_docling.py`) et appliquer le même motif (exception typée pertinente au contexte + `logger.debug`).

- [ ] **Step 3: `countries.py` — reschedule best-effort du scheduler**

Ligne 132 :
```python
        try:
            reschedule_country_job(country_id, country.code, body)
        except Exception:
            pass
```
remplacer par :
```python
        try:
            reschedule_country_job(country_id, country.code, body)
        except Exception as e:
            logger.warning("Failed to reschedule country job after settings update", country_id=country_id, error=str(e))
```
(utiliser `logger.warning` plutôt que `debug` ici — un échec de reschedule après une modification de settings est plus significatif qu'un timeout de sélecteur Playwright ; vérifier que `logger` est bien importé dans ce fichier, sinon ajouter `from ...logging import get_logger` et `logger = get_logger(__name__)` en tête si absent.)

- [ ] **Step 4: `health.py` — métriques best-effort (2 occurrences, lignes 169 et 178)**

Ligne 169 :
```python
    try:
        db_info = get_database_info()
        metrics_output.append(...)
        metrics_output.append(...)
        metrics_output.append(...)
    except:
        pass
```
remplacer par :
```python
    try:
        db_info = get_database_info()
        metrics_output.append(...)
        metrics_output.append(...)
        metrics_output.append(...)
    except Exception as e:
        logger.debug("Failed to collect DB pool metrics", error=str(e))
```
Même traitement pour la ligne 178 (métriques de santé DB) — vérifier que `logger` est déjà importé dans ce fichier (probable, c'est un router FastAPI).

- [ ] **Step 5: `smtp_client.py` — formatage de date best-effort (2 occurrences)**

Ligne 315 :
```python
            try:
                from datetime import datetime as _dt
                if isinstance(deadline, str) and "T" in deadline:
                    deadline = _dt.fromisoformat(deadline).strftime("%d/%m/%Y")
            except Exception:
                pass
```
remplacer par :
```python
            try:
                from datetime import datetime as _dt
                if isinstance(deadline, str) and "T" in deadline:
                    deadline = _dt.fromisoformat(deadline).strftime("%d/%m/%Y")
            except (ValueError, TypeError) as e:
                logger.debug("Failed to reformat deadline date, using raw value", deadline=deadline, error=str(e))
```
Répéter pour l'occurrence à la ligne 394 (lire le contexte avec `sed -n '385,400p' src/tenderai_bf/email/smtp_client.py` avant d'éditer).

- [ ] **Step 6: `tests/api/test_countries_endpoints.py` — ligne 86**

Lire le contexte (`sed -n '75,90p' tests/api/test_countries_endpoints.py`) et appliquer le même motif : remplacer `except Exception: pass` par une capture typée pertinente + un commentaire expliquant pourquoi cette exception est tolérée dans le test (ou `logger`/`print` de debug si le fichier n'utilise pas de logger structuré — cohérent avec le style existant du fichier de test).

- [ ] **Step 7: Vérifier zéro violation S110/E722 restante**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run ruff check src tests --select S110,E722
```
Attendu : `All checks passed!`

### Groupe B — `S324` (MD5 non-cryptographique) : `usedforsecurity=False`

- [ ] **Step 8: `parse_extract.py` — génération de référence courte (2 occurrences)**

Ligne 417 :
```python
                    f"REF-{hashlib.md5(url.encode()).hexdigest()[:8].upper()}",
```
remplacer par :
```python
                    f"REF-{hashlib.md5(url.encode(), usedforsecurity=False).hexdigest()[:8].upper()}",
```
Même traitement ligne 518.

- [ ] **Step 9: `vector_store.py` — génération d'ID de document (1 occurrence)**

Ligne 94 :
```python
                hashlib.md5(f"{source_name}_{doc}_{i}".encode()).hexdigest()
```
remplacer par :
```python
                hashlib.md5(f"{source_name}_{doc}_{i}".encode(), usedforsecurity=False).hexdigest()
```

- [ ] **Step 10: Vérifier zéro violation S324 restante et aucune régression fonctionnelle**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run ruff check src tests --select S324
poetry run pytest tests/nodes/test_extraction.py tests/nodes/test_pdf_rag.py -v --no-cov 2>&1 | tail -10
```
Attendu : `All checks passed!` pour ruff ; les tests touchant `parse_extract`/`vector_store` produisent le même résultat qu'en baseline (`usedforsecurity=False` ne change pas le hash produit, seulement un flag interne OpenSSL — le hexdigest reste identique).

### Groupe C — Faux positifs restants : `noqa` justifié

- [ ] **Step 11: `fetch_quotidien.py` — SSL désactivé pour certificat expiré connu (2 occurrences)**

Lignes 38 et 158, déjà commentées dans le code (`# Disable SSL verification for expired certificates`) — ajouter le noqa à la ligne du `verify=False` :
```python
            verify=False,  # noqa: S501 — DGCMEF site has an expired cert, verified trade-off (see comment above)
```

- [ ] **Step 12: `api/main.py` — bind 0.0.0.0 dans l'entrypoint dev**

Ligne 163, dans le bloc `if __name__ == "__main__":` :
```python
        host="0.0.0.0",  # noqa: S104 — dev-only entrypoint; production runs via uvicorn/Docker with proper network config
```

- [ ] **Step 13: `admin.py` — `token_type="bearer"` (constante OAuth2, pas un mot de passe)**

Ligne 83 :
```python
        token_type="bearer",  # noqa: S106 — OAuth2 token type constant, not a credential
```

- [ ] **Step 14: `email/__init__.py` — comparaison à une valeur placeholder de config non renseignée**

Ligne 24 :
```python
        if not smtp.password or smtp.password == "your-smtp-password":  # noqa: S105 — comparing to the documented placeholder default, not a real credential
```

- [ ] **Step 15: `tests/nodes/run_all_tests.py` — subprocess avec chemin de fichier local fixe**

Ligne 50, dans le lanceur de tests interne :
```python
        result = subprocess.run(  # noqa: S603 — internal test runner, fixed local file path, no untrusted input
            [sys.executable, str(test_path)],
```

- [ ] **Step 16: Vérifier zéro violation S501/S104/S106/S105/S603 restante**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run ruff check src tests --select S501,S104,S106,S105,S603
```
Attendu : `All checks passed!`

- [ ] **Step 17: Vérifier l'ensemble des règles S et qu'aucun test ne régresse**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run ruff check src tests --select S
poetry run pytest tests/ -v --no-cov 2>&1 | tail -5
```
Attendu : `All checks passed!` pour ruff (0 violation S) ; `101 passed, 18 failed` pour les tests (identique à la baseline — tous les changements de ce groupe sont soit des ajouts de logging sur des chemins déjà non-fatals, soit des `noqa` sans changement de comportement).

- [ ] **Step 18: Commit**

```bash
git add -A
git commit -m "fix(lint): resolve bandit security findings — real fixes + justified noqa

19 findings examined individually, not blanket-suppressed:
- 8x S110/E722 (swallowed exceptions in best-effort paths): kept
  non-fatal behavior, added logger.debug/.warning for visibility
- 3x S324 (MD5 for non-crypto ID generation): usedforsecurity=False
- 6x false positives (S501 documented SSL trade-off, S104 dev-only
  bind, S106 OAuth2 constant, S105 config placeholder comparison,
  S603 internal test runner): noqa with inline justification"
```

---

## Task 4: Corrections manuelles restantes (naming, raise-from, if imbriqués, unicode)

**Files:**
- Modify: `src/tenderai_bf/agents/_cfg.py:20`
- Modify: `src/tenderai_bf/api/routers/admin.py:185,219,285`
- Modify: `src/tenderai_bf/api/routers/countries.py:39,125`
- Modify: `src/tenderai_bf/api/routers/reports.py:151,300`
- Modify: `src/tenderai_bf/api/routers/sources.py:210`
- Modify: `src/tenderai_bf/agents/nodes/classify.py:100,172,203`
- Modify: `src/tenderai_bf/agents/nodes/extract_item_links.py:558`
- Modify: `src/tenderai_bf/storage/minio_client.py:449`
- Modify: `src/tenderai_bf/utils/docling_parser.py:162`
- Modify: `src/tenderai_bf/api/main.py:58,61`
- Modify: `src/tenderai_bf/config.py:450,461`
- Modify: `src/tenderai_bf/db.py:99,115`
- Modify: `src/tenderai_bf/scheduler/schedule.py:121`
- Modify: `src/tenderai_bf/schemas.py:249`
- Modify: `tests/api/test_auth.py:13`
- Modify: `tests/api/test_settings_endpoints.py:26`
- Modify: `tests/api/test_users.py:32`
- Modify: `src/tenderai_bf/agents/nodes/classify.py:66`
- Modify: `src/tenderai_bf/agents/nodes/parse_extract.py:54,210,325`
- Modify: `src/tenderai_bf/agents/nodes/parse_quotidien_docling.py:200`
- Modify: `src/tenderai_bf/cli.py:374`
- Modify: `src/tenderai_bf/config.py:91`
- Modify: `src/tenderai_bf/email/smtp_client.py:558,650`
- Modify: `src/tenderai_bf/report/docx_report.py:146,195`
- Modify: `src/tenderai_bf/utils/docling_parser.py:114`

**Interfaces:**
- Consumes: aucune dépendance sur Tasks 1-3.
- Produces: zéro violation `B904`, `E722` (restant hors Task 3), `SIM102`, `N806`, `N805`, `N817`, `RUF001`.

### Groupe A — `B904` (raise sans `from`) : vraie correction, 9 occurrences

- [ ] **Step 1: Ajouter `from err`/`from None` sur chaque `raise` dans un bloc `except`**

Pour chacun des 9 emplacements (`_cfg.py:20`, `admin.py:185,219,285`, `countries.py:39,125`, `reports.py:151,300`, `sources.py:210`), lire le bloc `except` concerné et déterminer si l'exception d'origine doit être chaînée (`from e`, où `e` est le nom de la variable d'exception capturée) ou explicitement supprimée (`from None`, si l'exception d'origine n'apporte rien d'utile au débogage — rare, à ne choisir que si le message de la nouvelle exception contient déjà toute l'information pertinente).

Motif type (le nom de la variable d'exception capturée doit correspondre à celui déjà utilisé dans le `except` — vérifier avec `sed -n '<ligne-10>,<ligne+5>p' <fichier>` avant d'éditer chaque occurrence) :
```python
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
```
devient :
```python
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e)) from e
```

- [ ] **Step 2: Vérifier zéro violation B904 restante**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run ruff check src tests --select B904
```
Attendu : `All checks passed!`

- [ ] **Step 3: Vérifier les tests API (ce sont tous des routers FastAPI)**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run pytest tests/api/ -v --no-cov 2>&1 | tail -10
```
Attendu : mêmes résultats qu'en baseline pour `tests/api/` (`from e` ne change que le traceback chaîné affiché en cas d'erreur, jamais le comportement observable par les tests — le corps de la `HTTPException` reste identique).

### Groupe B — `E722` restants hors Task 3 (1 occurrence)

- [ ] **Step 4: `src/tenderai_bf/utils/pdf.py:314`**

Lire le contexte (`sed -n '305,320p' src/tenderai_bf/utils/pdf.py`) et remplacer le bare `except:` par une exception typée pertinente au contexte (probablement `Exception`, à ajuster selon ce que fait le bloc), en conservant le comportement existant (ajout de `as e` et d'un `logger.debug`/`logger.warning` si le bloc avale silencieusement, sur le même modèle que Task 3 Groupe A).

### Groupe C — `SIM102` (if imbriqués → combinés), 5 occurrences

- [ ] **Step 5: Combiner les `if` imbriqués dans `classify.py` (2×), `extract_item_links.py`, `minio_client.py`, `docling_parser.py`**

Pour chaque emplacement (`classify.py:172,203`, `extract_item_links.py:558`, `minio_client.py:449`, `docling_parser.py:162`), lire le bloc concerné et combiner :
```python
    if condition_a:
        if condition_b:
            do_something()
```
en :
```python
    if condition_a and condition_b:
        do_something()
```
**Attention** : vérifier qu'il n'y a pas de `else` sur le `if` intérieur qui rendrait la fusion incorrecte (dans ce cas, laisser tel quel et ajouter `# noqa: SIM102` avec justification "else clause on inner if prevents flattening"). Lire chaque emplacement individuellement avant de fusionner — ne pas appliquer mécaniquement sans vérifier la structure exacte.

- [ ] **Step 6: Vérifier zéro violation SIM102 restante (ou noqa justifiés) et absence de régression**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run ruff check src tests --select SIM102
poetry run pytest tests/nodes/test_classify.py tests/nodes/test_extraction.py -v --no-cov 2>&1 | tail -10
```
Attendu : `All checks passed!` (ou uniquement des `noqa` documentés) ; tests identiques à la baseline.

### Groupe D — Naming (`N806`, `N805`, `N817`)

- [ ] **Step 7: `N817` — `api/main.py:58`, vrai renommage (import CamelCase en acronyme)**

```python
from ...country_store import CountryStore as CS
```
Remplacer l'alias `CS` par le nom complet `CountryStore` partout où il est utilisé dans ce fichier (`grep -n "\bCS\b" src/tenderai_bf/api/main.py` pour lister tous les usages avant de renommer).

- [ ] **Step 8: `N806` — `SessionLocal`, `TRIVIAL_PASSWORDS`, `TRIVIAL_JWT_SECRETS`, `_EXCLUDE_PREFIXES`, `Session` : `noqa` justifié, pas de renommage**

Ces 10 occurrences (`classify.py:100`, `api/main.py:61`, `config.py:450,461`, `db.py:99,115`, `scheduler/schedule.py:121`, `tests/api/test_auth.py:13`, `tests/api/test_settings_endpoints.py:26`, `tests/api/test_users.py:32`) suivent des conventions établies : `SessionLocal`/`Session` est l'idiome standard SQLAlchemy pour une factory de session (renommer romprait la lisibilité pour quiconque connaît SQLAlchemy) ; `TRIVIAL_PASSWORDS`/`TRIVIAL_JWT_SECRETS`/`_EXCLUDE_PREFIXES` sont des constantes locales à une fonction, nommées en majuscules par convention pour signaler leur nature immuable malgré leur portée locale. Ajouter `# noqa: N806` sur chaque ligne d'assignation avec une justification courte, par exemple :

```python
    SessionLocal = sessionmaker(...)  # noqa: N806 — SQLAlchemy idiom for a session factory
```
```python
    TRIVIAL_PASSWORDS = {...}  # noqa: N806 — module-level-style constant, scoped locally by design
```

- [ ] **Step 9: `N805` — `schemas.py:249`, faux positif Pydantic `@validator`**

```python
    @validator("email")
    def validate_email(cls, v):  # noqa: N805 — Pydantic validator, first arg is `cls` by framework convention
```

- [ ] **Step 10: Vérifier zéro violation N806/N805/N817 restante et absence de régression**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run ruff check src tests --select N806,N805,N817
poetry run pytest tests/ -v --no-cov 2>&1 | tail -5
```
Attendu : `All checks passed!` ; `101 passed, 18 failed` (le renommage `CS`→`CountryStore` est purement syntaxique, aucun changement de comportement).

### Groupe E — `RUF001` (caractères unicode ambigus), 15 occurrences — tous faux positifs

- [ ] **Step 11: Ajouter `noqa` justifié sur chaque occurrence**

Ces 15 occurrences se répartissent en 3 catégories, toutes des faux positifs :

1. **`classify.py:66`** — la ligne normalise justement ces caractères (`text.replace("'", "'")...`) ; la "corriger" casserait la fonction elle-même :
```python
    return text.replace("'", "'").replace("'", "'").replace("ʼ", "'")  # noqa: RUF001 — this line's purpose IS normalizing these exact unicode variants
```

2. **Regex avec tiret cadratin comme alternative valide** (`parse_extract.py:54,210,325`, `parse_quotidien_docling.py:200`) — le tiret cadratin apparaît dans des formats de référence réels (ex: "N°3827-2024" vs "N°3827–2024") :
```python
    ref_pattern = r"N[°o]\s*(\d{4}[-–]\d+[^\\n]{0,100})"  # noqa: RUF001 — en dash is a real alternative in source reference formats
```

3. **Texte d'affichage/branding** (`cli.py:374` emoji ℹ️, `config.py:91` "RFP Watch – Burkina Faso", `smtp_client.py:558,650`, `docx_report.py:146,195`, `docling_parser.py:114`) — typographie française/branding intentionnelle dans des chaînes affichées à l'utilisateur, pas des identifiants de code :
```python
    subject_prefix: str = Field(default="RFP Watch – Burkina Faso")  # noqa: RUF001 — intentional em dash in display text
```

Appliquer le `noqa` avec justification à chacune des 15 lignes listées dans les **Files** de cette tâche.

- [ ] **Step 12: Vérifier zéro violation RUF001 restante**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run ruff check src tests --select RUF001
```
Attendu : `All checks passed!`

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "fix(lint): resolve remaining ruff findings (B904, E722, SIM102, naming, RUF001)

- 9x B904: chain exceptions with 'raise ... from e' in API routers
- 1x E722: type the remaining bare except in utils/pdf.py
- 5x SIM102: flatten nested if statements where safe (else clauses
  checked individually, not blindly merged)
- N817: rename CS import alias to CountryStore (real fix)
- N806/N805: noqa on established idioms (SessionLocal, module-style
  local constants, Pydantic validator's cls-not-self convention)
- RUF001 (15x): noqa on intentional unicode — a normalization
  function's own target characters, valid en-dash regex
  alternatives, and French display-text typography"
```

---

## Task 5: Vérification finale

**Files:** aucun (vérification uniquement).

**Interfaces:**
- Consumes: Tasks 1-4 complètes.
- Produces: confirmation finale — critère de complétion du sous-projet B.

- [ ] **Step 1: `ruff check` complet, zéro violation active**

```bash
cd /home/yulcom/web/tender-ai/.claude/worktrees/repo-split
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run ruff check src tests
```
Attendu : `All checks passed!`

- [ ] **Step 2: `ruff format --check`, confirmer que les corrections n'ont pas cassé le formatage**

```bash
poetry run ruff format --check src tests
```
Attendu : exit code 0 (aucun fichier nécessitant un reformatage). Si des fichiers sont signalés, lancer `poetry run ruff format src tests` et vérifier que le diff résultant ne touche qu'à des détails de style (indentation, guillemets) sans changement sémantique, puis commit séparé.

- [ ] **Step 3: Suite de tests complète, comparaison stricte contre la baseline**

```bash
TENDERAI_JWT_SECRET="test-jwt-secret-not-used-for-real-auth-only-pytest-xxxxxxxx" \
  TENDERAI_ADMIN_PASSWORD="test-admin-password-not-real" \
  poetry run pytest tests/ -v --no-cov > /tmp/ruff-cleanup-baseline/test-results-after.txt 2>&1
echo "exit code: $?" >> /tmp/ruff-cleanup-baseline/test-results-after.txt
diff <(grep -E "PASSED|FAILED|ERROR" /tmp/ruff-cleanup-baseline/test-results-before.txt | sort) \
     <(grep -E "PASSED|FAILED|ERROR" /tmp/ruff-cleanup-baseline/test-results-after.txt | sort)
```
Attendu : `diff` ne montre aucune différence — mêmes tests, mêmes statuts, des deux côtés.

- [ ] **Step 4: Copier les artefacts de test dans le repo pour traçabilité**

```bash
mkdir -p docs/superpowers/artifacts
cp /tmp/ruff-cleanup-baseline/test-results-before.txt docs/superpowers/artifacts/2026-08-25-ruff-cleanup-test-before.txt
cp /tmp/ruff-cleanup-baseline/test-results-after.txt docs/superpowers/artifacts/2026-08-25-ruff-cleanup-test-after.txt
git add docs/superpowers/artifacts/2026-08-25-ruff-cleanup-test-before.txt docs/superpowers/artifacts/2026-08-25-ruff-cleanup-test-after.txt
git commit -m "docs: capture before/after test results for ruff lint cleanup (0 regressions, ruff check clean)"
```

- [ ] **Step 5: Activer `make lint` comme gate réel (déjà configuré, juste vérifier qu'il passe maintenant)**

```bash
make lint
```
Attendu : exit code 0 — `ruff check` et `ruff format --check` passent tous les deux. Ce `Makefile` target était déjà correctement défini (chantier 1) mais échouait systématiquement faute de lint propre ; ce sous-projet le rend enfin utilisable comme gate de CI future (activer la CI elle-même est hors périmètre — cible potentielle pour `tenderai-backend`'s CI dans un chantier ultérieur, déjà noté comme dette dans le ledger du chantier 1).

- [ ] **Step 6: Résumé final**

Rédiger un court résumé : nombre de violations initial (150) → final (0), répartition entre vraies corrections (logging ajouté, `raise from`, renommage, `usedforsecurity=False`, `if` fusionnés, `import time` déplacé) et `noqa` justifiés (imports E402 intentionnels, faux positifs bandit, conventions de nommage établies, typographie unicode intentionnelle). Confirmer 0 régression sur 119 tests. Ce résumé constitue la preuve de complétion du sous-projet B.
