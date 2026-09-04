# Tenderai_bf Package Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the importable Python package `tenderai_bf` → `tenderai` across `tenderai-backend` (source, tests, tooling config, Dockerfiles) and the matching runtime references in `tenderai-infra` (Docker command overrides, logger config), then deploy both jointly to staging and verify live.

**Architecture:** Pure mechanical rename, no compatibility shim. `git mv` the package directory (internal relative imports are unaffected by this alone), then fix the small number of absolute-import call sites and non-Python config/tooling files that spell out the module path as a string. Two repos must change and deploy together because `tenderai-infra/docker-compose.server.yml` hard-codes the module path in live server command overrides.

**Tech Stack:** Python 3.11, Poetry, pytest, ruff, mypy, Alembic, Docker Compose, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-01-tenderai-bf-package-rename-design.md`

## Global Constraints

- Poetry's project display name (`[tool.poetry] name = "tenderai-bf"` in `pyproject.toml`) stays unchanged — only the importable package path changes.
- Do NOT touch: `DatabaseSettings.name`/`DATABASE_URL` defaults in `config.py`, `alembic.ini`'s `sqlalchemy.url`, `docker-compose.yml`'s `POSTGRES_DB`/`DATABASE_URL` defaults, `Makefile`'s `pg_dump -U tenderai tenderai_bf` and `psql -d tenderai_bf` — these are the real Postgres database name, textually identical but semantically unrelated.
- Do NOT touch: MinIO bucket name, GHCR image names/prefixes — out of scope, already handled by the prior infra rename (sous-projet A).
- No new mypy errors versus the current baseline (523 pre-existing errors repo-wide; CI runs mypy with `continue-on-error: true` — the goal is zero *new* errors, not zero total).
- Full test suite must stay green: `pytest tests/ -v --no-cov -m "not slow and not integration"` → 192 passed, 4 deselected (CI's actual gate).
- `ruff check src tests` and `ruff format --check src tests` must stay clean (CI's actual lint scope — `alembic/` and `scripts/` are excluded and pre-existing failures there are not this plan's concern).
- Work happens directly on each repo's already-checked-out `staging` branch (matches this session's established pattern for prior chantier-5 follow-up work — no feature branch/worktree).

---

### Task 1: Rename the package directory and fix absolute-import call sites

**Files:**
- Rename: `tenderai-backend/src/tenderai_bf/` → `tenderai-backend/src/tenderai/` (directory, via `git mv`)
- Modify: `tenderai-backend/src/tenderai/agents/extraction.py` (only `src/` file using absolute imports)
- Modify: `tenderai-backend/src/tenderai/logging.py`
- Modify: `tenderai-backend/src/tenderai/api/main.py`
- Modify: `tenderai-backend/src/tenderai/config.py` (adjacent `app_name` fix)
- Modify: `tenderai-backend/src/tenderai/settings_store.py` (cosmetic header comment)
- Modify: `tenderai-backend/src/tenderai/api/schemas/settings.py` (cosmetic header comment)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: an importable package at `src/tenderai/` with all internal imports resolving. Task 2 depends on this directory already being renamed. Task 3 depends on this package importing cleanly so tests can be collected.

- [ ] **Step 1: Rename the directory with git mv**

```bash
cd /home/yulcom/web/tenderai/tenderai-backend
git mv src/tenderai_bf src/tenderai
```

- [ ] **Step 2: Fix the absolute imports in extraction.py**

In `src/tenderai/agents/extraction.py`, replace:

```python
from tenderai_bf.config import settings
from tenderai_bf.logging import get_logger
from tenderai_bf.schemas import TenderExtraction
from tenderai_bf.utils.llm_utils import get_llm_instance
```

with:

```python
from tenderai.config import settings
from tenderai.logging import get_logger
from tenderai.schemas import TenderExtraction
from tenderai.utils.llm_utils import get_llm_instance
```

- [ ] **Step 3: Rename the logger namespace in logging.py**

In `src/tenderai/logging.py`, there are three occurrences of the literal string `"tenderai_bf"` — one as a dict key in the logging config, two as arguments to `structlog.get_logger(...)`. Replace all three with `"tenderai"`:

```python
            "tenderai_bf": {
                "handlers": _active_handlers,
                "level": settings.monitoring.log_level,
                "propagate": False,
            },
```
→
```python
            "tenderai": {
                "handlers": _active_handlers,
                "level": settings.monitoring.log_level,
                "propagate": False,
            },
```

```python
    logger = structlog.get_logger("tenderai_bf")
```
→
```python
    logger = structlog.get_logger("tenderai")
```

```python
    return structlog.get_logger(name or "tenderai_bf")
```
→
```python
    return structlog.get_logger(name or "tenderai")
```

- [ ] **Step 4: Fix the uvicorn target string in api/main.py**

In `src/tenderai/api/main.py`, replace:

```python
    uvicorn.run(
        "tenderai_bf.api.main:app",
```

with:

```python
    uvicorn.run(
        "tenderai.api.main:app",
```

- [ ] **Step 5: Adjacent fix — app_name default in config.py**

In `src/tenderai/config.py`, replace:

```python
    app_name: str = Field(default="TenderAI BF")
```

with:

```python
    app_name: str = Field(default="TenderAI")
```

Do NOT touch `DatabaseSettings.name` (default `"tenderai_bf"`) or the `DATABASE_URL` default a few lines above `Settings.app_name` — those are the Postgres database name, out of scope per the Global Constraints.

- [ ] **Step 6: Fix cosmetic header comments**

In `src/tenderai/settings_store.py`, replace the first line:

```python
# src/tenderai_bf/settings_store.py
```

with:

```python
# src/tenderai/settings_store.py
```

In `src/tenderai/api/schemas/settings.py`, replace the first line:

```python
# src/tenderai_bf/api/schemas/settings.py
```

with:

```python
# src/tenderai/api/schemas/settings.py
```

- [ ] **Step 7: Verify no stray `tenderai_bf` references remain under src/**

```bash
grep -rn 'tenderai_bf' src/ | grep -v 'src/tenderai/config.py:.*tenderai_bf'
```

Expected: no output. (The one line in `config.py` with the DB name default is filtered out by the grep above — if it still appears, something else changed unexpectedly; investigate before proceeding.)

- [ ] **Step 8: Verify the renamed package imports cleanly**

```bash
poetry run python -c "import tenderai; from tenderai.agents.extraction import logger; from tenderai.api.main import app; print('OK')"
```

Expected: prints `OK` with no traceback. (This runs against the still-stale `pyproject.toml`/editable install from before the rename — Poetry's editable install maps `src/` by path, not by the old package name, so this works even before Task 2 updates `pyproject.toml`.)

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: rename src/tenderai_bf -> src/tenderai (package directory + absolute imports)

Part of the tenderai_bf -> tenderai package rename (sous-projet B).
Renames the package directory via git mv (internal relative imports
unaffected), fixes the one src/ file using absolute imports
(agents/extraction.py), the logger namespace in logging.py, the uvicorn
target string in api/main.py, and the adjacent app_name display-string
fix (TenderAI BF -> TenderAI) left over from the earlier BF-rename.

DatabaseSettings.name and DATABASE_URL defaults in config.py are
untouched -- Postgres database name, not the Python package.

Claude-Session: https://claude.ai/code/session_019UMMgArW6zH3crrqqwygb4"
```

---

### Task 2: Update packaging, tooling, and Docker config

**Files:**
- Modify: `tenderai-backend/pyproject.toml`
- Modify: `tenderai-backend/ruff.toml`
- Modify: `tenderai-backend/Makefile`
- Modify: `tenderai-backend/Dockerfile.api`
- Modify: `tenderai-backend/Dockerfile.worker`
- Modify: `tenderai-backend/docker-compose.yml`
- Modify: `tenderai-backend/alembic/env.py`
- Modify: `tenderai-backend/.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the renamed `src/tenderai/` directory from Task 1.
- Produces: a package that installs, lints, type-checks, and runs its CLI entry points under the new name. Task 3 depends on `ruff.toml`'s `known-first-party` already being updated (otherwise ruff will misclassify `tenderai` imports in the test files it edits).

- [ ] **Step 1: Update pyproject.toml**

Replace:

```toml
packages = [{include = "tenderai_bf", from = "src"}]
```

with:

```toml
packages = [{include = "tenderai", from = "src"}]
```

Replace:

```toml
[tool.poetry.scripts]
tenderai = "tenderai_bf.cli:main"
tenderai-api = "tenderai_bf.api.main:app"
```

with:

```toml
[tool.poetry.scripts]
tenderai = "tenderai.cli:main"
tenderai-api = "tenderai.api.main:app"
```

Replace:

```toml
    "--cov=tenderai_bf",
```

with:

```toml
    "--cov=tenderai",
```

Do NOT touch `name = "tenderai-bf"` under `[tool.poetry]` — that's the Poetry display name, explicitly out of scope per the Global Constraints.

- [ ] **Step 2: Update ruff.toml**

Replace:

```toml
known-first-party = ["tenderai_bf"]
```

with:

```toml
known-first-party = ["tenderai"]
```

- [ ] **Step 3: Update Makefile**

Replace:

```makefile
type-check: ## Run type checking with mypy
	poetry run mypy src/tenderai_bf
```

with:

```makefile
type-check: ## Run type checking with mypy
	poetry run mypy src/tenderai
```

Replace:

```makefile
test-cov: ## Run tests with coverage
	poetry run pytest tests/ --cov=tenderai_bf --cov-report=html --cov-report=term
```

with:

```makefile
test-cov: ## Run tests with coverage
	poetry run pytest tests/ --cov=tenderai --cov-report=html --cov-report=term
```

Replace:

```makefile
run-once: ## Execute pipeline once (defaults to BF/yulcom for local dev)
	poetry run python -m tenderai_bf.cli run-once --country-code BF --company-code yulcom

run-once-docker: ## Execute pipeline once using docker (defaults to BF/yulcom for local dev)
	docker-compose exec api python -m tenderai_bf.cli run-once --country-code BF --company-code yulcom

build-report: ## Generate report only
	poetry run python -m tenderai_bf.cli build-report

test-email: ## Test email configuration
	poetry run python -m tenderai_bf.cli test-email

init-db: ## Initialize database schema
	poetry run python -m tenderai_bf.cli init-db

scheduler: ## Start scheduler daemon
	poetry run python -m tenderai_bf.scheduler.schedule
```

with:

```makefile
run-once: ## Execute pipeline once (defaults to BF/yulcom for local dev)
	poetry run python -m tenderai.cli run-once --country-code BF --company-code yulcom

run-once-docker: ## Execute pipeline once using docker (defaults to BF/yulcom for local dev)
	docker-compose exec api python -m tenderai.cli run-once --country-code BF --company-code yulcom

build-report: ## Generate report only
	poetry run python -m tenderai.cli build-report

test-email: ## Test email configuration
	poetry run python -m tenderai.cli test-email

init-db: ## Initialize database schema
	poetry run python -m tenderai.cli init-db

scheduler: ## Start scheduler daemon
	poetry run python -m tenderai.scheduler.schedule
```

Do NOT touch the `backup` and `shell-db` targets (`pg_dump -U tenderai tenderai_bf`, `psql -U tenderai -d tenderai_bf`) — those reference the Postgres database name, out of scope.

- [ ] **Step 4: Update Dockerfile.api**

Replace:

```dockerfile
CMD ["uvicorn", "tenderai_bf.api.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

with:

```dockerfile
CMD ["uvicorn", "tenderai.api.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

- [ ] **Step 5: Update Dockerfile.worker**

Replace:

```dockerfile
CMD ["python", "-m", "tenderai_bf.cli", "run-scheduler"]
```

with:

```dockerfile
CMD ["python", "-m", "tenderai.cli", "run-scheduler"]
```

- [ ] **Step 6: Update docker-compose.yml**

Replace:

```yaml
    command: ["uvicorn", "tenderai_bf.api.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
```

with:

```yaml
    command: ["uvicorn", "tenderai.api.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
```

Do NOT touch `POSTGRES_DB`/`DATABASE_URL` defaults elsewhere in this file — Postgres database name, out of scope.

- [ ] **Step 7: Update alembic/env.py**

Replace:

```python
from tenderai_bf.models import Base
```

with:

```python
from tenderai.models import Base
```

- [ ] **Step 8: Update .github/workflows/ci.yml**

Replace:

```yaml
        run: poetry run mypy src/tenderai_bf
```

with:

```yaml
        run: poetry run mypy src/tenderai
```

- [ ] **Step 9: Reinstall the package editable and verify the CLI entry points**

```bash
cd /home/yulcom/web/tenderai/tenderai-backend
poetry install --only=main --no-root
poetry run pip install -e .
poetry run tenderai --help
```

Expected: `poetry run tenderai --help` prints the CLI's help text with no import error. This proves `[tool.poetry.scripts]`'s `tenderai = "tenderai.cli:main"` entry point resolves correctly post-rename.

- [ ] **Step 10: Verify lint and mypy**

```bash
poetry run ruff check src tests
poetry run ruff format --check src tests
poetry run mypy src/tenderai 2>&1 | tail -5
```

Expected: `ruff check`/`ruff format --check` report clean (tests/ still has the old `tenderai_bf` imports at this point — Task 3 fixes those; if ruff check on `tests` fails here on import-related errors, that's expected and resolved by Task 3, but `known-first-party` itself should apply with no syntax errors). mypy's error count should not have grown from the pre-rename baseline (523) for reasons unrelated to a genuinely broken import — spot-check any new-looking errors mention `tenderai` module resolution, not unrelated code.

- [ ] **Step 11: Verify no stray `tenderai_bf` references remain in the files this task touched**

```bash
grep -n 'tenderai_bf' pyproject.toml ruff.toml Makefile Dockerfile.api Dockerfile.worker docker-compose.yml alembic/env.py .github/workflows/ci.yml
```

Expected: no output.

- [ ] **Step 12: Commit**

```bash
git add pyproject.toml ruff.toml Makefile Dockerfile.api Dockerfile.worker docker-compose.yml alembic/env.py .github/workflows/ci.yml poetry.lock
git commit -m "refactor: update packaging/tooling/Docker config for tenderai package rename

pyproject.toml (packages, [tool.poetry.scripts], --cov=), ruff.toml
(known-first-party), Makefile (mypy/coverage/CLI invocations, excluding
the pg_dump/psql lines which reference the DB name), both Dockerfiles'
CMD, docker-compose.yml's api service command, alembic/env.py's model
import, and ci.yml's mypy invocation.

Verified: 'poetry run tenderai --help' resolves the renamed CLI entry
point; ruff check/format clean; mypy shows no new errors vs baseline.

Claude-Session: https://claude.ai/code/session_019UMMgArW6zH3crrqqwygb4"
```

---

### Task 3: Update test imports and verify the full suite

**Files:**
- Modify: ~39 files under `tenderai-backend/tests/` (all files matching `grep -rl 'tenderai_bf' tests/`)

**Interfaces:**
- Consumes: the renamed package from Task 1, the updated `ruff.toml`/`pyproject.toml` from Task 2.
- Produces: a fully green test suite proving the rename introduced no functional regression. Task 5 (deploy verification) depends on this having passed.

- [ ] **Step 1: List every test file still referencing the old package name**

```bash
cd /home/yulcom/web/tenderai/tenderai-backend
grep -rl 'tenderai_bf' tests/
```

Expected: a list of ~39 files (all are `.py` files under `tests/` using absolute imports like `from tenderai_bf.config import settings`, `from tenderai_bf import models`, `from tenderai_bf.cli import main`, etc. — tests live outside the package so they always use absolute imports, unlike most of `src/`).

- [ ] **Step 2: Scripted rename across test files**

Every occurrence in these files is a Python import path (verified in Task exploration — no test file references the database name). A whole-word replace is safe here, unlike the `src/`/config files in Tasks 1-2 which needed manual exclusions:

```bash
cd /home/yulcom/web/tenderai/tenderai-backend
grep -rl 'tenderai_bf' tests/ | xargs sed -i 's/\btenderai_bf\b/tenderai/g'
```

- [ ] **Step 3: Verify no stray references remain**

```bash
grep -rn 'tenderai_bf' tests/
```

Expected: no output.

- [ ] **Step 4: Format and lint the changed test files**

```bash
poetry run ruff format tests
poetry run ruff check tests
```

Expected: `ruff check tests` reports clean. If `ruff format` reformats any file (e.g. import sorting now that `tenderai` sorts differently than `tenderai_bf` under `known-first-party`), that's expected — the formatter's changes get included in this task's commit.

- [ ] **Step 5: Run the full test suite exactly as CI does**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```

Expected: `192 passed, 4 deselected` — matching the pre-rename baseline exactly (same test count, same pass/fail split). Any collection error here means an import was missed — re-run Step 1's grep to find it.

- [ ] **Step 6: Run the exhaustive suite once (includes slow/integration tests) to be thorough**

```bash
poetry run pytest tests/ -q
```

Expected: `196 passed` (matches this session's earlier full-suite baseline; this run is slow — historically ~28 minutes — because it includes ML-heavy classification/extraction tests). The `FAIL Required test coverage of 80% not reached` message (if it appears) is expected and pre-existing — CI itself runs with `--no-cov` and doesn't enforce this threshold; Step 5 above is the real gate.

- [ ] **Step 7: Commit**

```bash
git add tests/
git commit -m "refactor: update tests/ imports for tenderai package rename

Scripted whole-word replace across the ~39 test files referencing the old
tenderai_bf import path -- all occurrences here are Python import paths
(tests use absolute imports throughout), so no manual exclusions were
needed unlike src/ and the config files in earlier tasks.

Verified: 192 passed, 4 deselected (poetry run pytest tests/ -v --no-cov
-m 'not slow and not integration', matching CI's actual gate exactly);
196 passed on the full suite including slow/integration tests; ruff
check/format clean.

Claude-Session: https://claude.ai/code/session_019UMMgArW6zH3crrqqwygb4"
```

---

### Task 4: Update tenderai-infra's command overrides and logger config

**Files:**
- Modify: `tenderai-infra/docker-compose.server.yml`
- Modify: `tenderai-infra/settings.yaml`

**Interfaces:**
- Consumes: nothing from Tasks 1-3 directly (different repo), but must not be deployed until the `tenderai-backend` image built from Tasks 1-3's commits exists on GHCR — see Task 5.
- Produces: infra config that matches the renamed backend package. Task 5's joint deploy depends on this being merged before triggering `deploy.yml`.

- [ ] **Step 1: Update docker-compose.server.yml's api service command**

In `tenderai-infra/docker-compose.server.yml`, replace:

```yaml
    command: ["uvicorn", "tenderai_bf.api.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

with:

```yaml
    command: ["uvicorn", "tenderai.api.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

- [ ] **Step 2: Update docker-compose.server.yml's worker service command**

In the same file, replace:

```yaml
    command: ["python", "-m", "tenderai_bf.cli", "run-scheduler"]
```

with:

```yaml
    command: ["python", "-m", "tenderai.cli", "run-scheduler"]
```

- [ ] **Step 3: Update settings.yaml's logger key**

In `tenderai-infra/settings.yaml`, replace:

```yaml
  loggers:
    tenderai_bf:
      level: DEBUG
      handlers: [console, file]
      propagate: false
```

with:

```yaml
  loggers:
    tenderai:
      level: DEBUG
      handlers: [console, file]
      propagate: false
```

- [ ] **Step 4: Verify no stray references remain**

```bash
cd /home/yulcom/web/tenderai/tenderai-infra
grep -n 'tenderai_bf' docker-compose.server.yml settings.yaml
```

Expected: no output.

- [ ] **Step 5: Validate the compose file still parses correctly**

```bash
docker compose -f docker-compose.server.yml config --no-interpolate | grep -A6 'command:'
```

Expected: both `command:` blocks show `tenderai.api.main:app` / `tenderai.cli` (this validates YAML syntax without needing real `.env.staging` secrets — `--no-interpolate` skips variable substitution).

- [ ] **Step 6: Validate settings.yaml still parses as valid YAML**

```bash
python3 -c "import yaml; d = yaml.safe_load(open('settings.yaml')); assert 'tenderai' in d['logging']['loggers']; print('OK')"
```

Expected: prints `OK`.

- [ ] **Step 7: Commit**

```bash
git add docker-compose.server.yml settings.yaml
git commit -m "refactor: update command overrides and logger config for tenderai package rename

docker-compose.server.yml's api/worker command overrides and
settings.yaml's logging.loggers key were left as tenderai_bf by the
2026-08-28 infra rename (sous-projet A) specifically to stay in sync with
the still-unrenamed backend package. Now that tenderai-backend/staging
has been renamed (see that repo's matching commits), sync these too.

Must deploy together with the renamed tenderai-backend image -- deploying
either alone would crash-loop the staging containers (wrong module path
in the startup command).

Claude-Session: https://claude.ai/code/session_019UMMgArW6zH3crrqqwygb4"
```

---

### Task 5: Push, joint deploy, and live verification

**Files:** none (deployment and verification only).

**Interfaces:**
- Consumes: the commits from Tasks 1-4, already on each repo's local `staging` branch.
- Produces: a verified staging deployment running the renamed package.

- [ ] **Step 1: Push tenderai-backend**

```bash
cd /home/yulcom/web/tenderai/tenderai-backend
git push origin staging
```

- [ ] **Step 2: Push tenderai-infra**

```bash
cd /home/yulcom/web/tenderai/tenderai-infra
git push origin staging
```

- [ ] **Step 3: Wait for tenderai-backend's CI to build and push the renamed image**

```bash
gh run list --repo Abdazz/tenderai-backend --workflow=ci.yml --limit 1
```

Poll (re-run the command above, or use `gh run watch <run-id> --repo Abdazz/tenderai-backend`) until this run shows `completed` / `success`. Do not proceed to Step 4 until it does — `deploy.yml` in Step 4 pulls `:staging`-tagged images, which only exist once this CI run has pushed them to GHCR.

- [ ] **Step 4: Trigger the joint deploy**

```bash
gh workflow run deploy.yml --repo Abdazz/tenderai-infra --ref staging -f environment=staging -f image_tag=staging
```

- [ ] **Step 5: Wait for the deploy to complete**

```bash
gh run list --repo Abdazz/tenderai-infra --workflow=deploy.yml --limit 1
```

Poll until `completed` / `success`. If it fails, run `gh run view <run-id> --repo Abdazz/tenderai-infra --log-failed` and check first whether it's the known transient `ssh-keyscan` connectivity issue documented in `docs/PROJECT_STATUS.md` (server stays healthy throughout, confirmed via `curl` — safe to retry with `gh run rerun <run-id> --repo Abdazz/tenderai-infra`) versus a real failure (in which case stop and investigate — most likely cause would be a missed `tenderai_bf` reference; re-run the Task 1-4 verification greps against the merged `staging` branches to find it).

- [ ] **Step 6: Verify /health**

```bash
curl -s https://stagingtenderai.yulcom.net/health
```

Expected: `{"status":"healthy", ...}` with `database` and `storage` both `healthy`.

- [ ] **Step 7: Live CLI smoke test on the server**

This confirms the renamed entry point actually runs server-side, not just at import time (`/health` alone wouldn't catch a broken `python -m tenderai.cli` invocation, since the worker's `run-scheduler` command isn't exercised by `/health`).

```bash
ssh <staging-server> "cd /opt/tenderai-infra-staging && docker compose exec api python -m tenderai.cli --help"
```

Expected: the CLI's help text prints with no import error. (If SSH access from this session isn't set up, ask the user to run this one command and report the output — this is the one step in this plan that may require the user's direct access, per this project's staging-server access pattern.)

- [ ] **Step 8: Confirm the worker container is up and not crash-looping**

```bash
ssh <staging-server> "cd /opt/tenderai-infra-staging && docker compose ps worker"
```

Expected: `worker` shows `Up` / `running`, not `Restarting` (a crash-loop here would mean `run-scheduler`'s renamed module path is broken despite Step 7 passing standalone).

- [ ] **Step 9: Update docs/PROJECT_STATUS.md**

Add a paragraph under the existing "Nettoyage/renommage BF" note recording: sous-projet B complete, commit SHAs on both repos, deploy run IDs, verification results (health + CLI smoke + worker status). Commit this doc update on the monorepo's `staging` branch.

```bash
cd /home/yulcom/web/tender-ai
git add docs/PROJECT_STATUS.md
git commit -m "docs: record tenderai_bf package rename (sous-projet B) complete

Claude-Session: https://claude.ai/code/session_019UMMgArW6zH3crrqqwygb4"
git push origin staging
```

---

## Self-Review Notes

**Spec coverage:** Décision 1 (scope) → Task 1+2 (packages/scripts unchanged, only import path). Décision 2 (exclusions) → explicit "Do NOT touch" call-outs in Tasks 1, 2, 3 with the exact excluded lines named. Décision 3 (app_name) → Task 1 Step 5. Décision 4 (logger sync) → Task 1 Step 3 (backend) + Task 4 Step 3 (infra). Décision 5 (mechanical rename, file inventory) → Tasks 1-3 cover every file in the spec's inventory table. Décision 6 (cross-repo coordination + sequence) → Task 4 + Task 5 Steps 1-4 follow the spec's exact sequence. Décision 7 (rollback) → not a task (rollback is a revert instruction, documented in the spec itself, not a forward-executing step). Décision 8 (staging only) → Task 5 only touches staging infra. Tests section → Task 3 Steps 5-6, Task 2 Step 10.

**Placeholder scan:** No TBD/TODO. Task 5 Steps 7-8 use `<staging-server>` as a placeholder for the actual SSH host — this is intentional, not a plan gap: the real hostname is an operational secret not appropriate to hardcode in a committed plan file, and the step already tells the executor what to do if they lack direct access (ask the user to run the one command).

**Type consistency:** N/A — no function signatures introduced by this plan (pure rename/config work).
