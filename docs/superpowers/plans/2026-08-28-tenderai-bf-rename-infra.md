# tenderai-bf → tenderai infra rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the GHCR image prefix and Docker image names from `tenderai-bf-*` to `tenderai-*` across the 3 split repos, and drop "BF" from the scraper's User-Agent string — with zero functional change, staging-only blast radius, and no application code touched.

**Architecture:** Four sequential config-file edits (2 CI workflow files, 1 docker-compose file, 1 settings value) across three separate git repos, each pushed to its own `staging` branch to trigger CI rebuilds under the new image names, followed by a re-deploy of `tenderai-infra` and a validation pass identical to the one already used for chantier 1 tâche 12.

**Tech Stack:** GitHub Actions, Docker/GHCR (`ghcr.io/abdazz/*`), `gh` CLI, docker-compose.

**Spec:** `docs/superpowers/specs/2026-08-28-tenderai-bf-rename-infra-design.md`

## Global Constraints

- New name is `tenderai` (no country suffix) — GHCR prefix `ghcr.io/abdazz/tenderai`, images `tenderai-api`, `tenderai-worker`, `tenderai-frontend`.
- Postgres database name (`tenderai_bf`) and MinIO bucket name (`tenderai-bf`) are **excluded** — do not touch `DATABASE_NAME`, `MINIO_BUCKET_NAME`, or any `.env*` file in any repo. These are live data identifiers on the staging server.
- The Python package `tenderai_bf` (imports, `pyproject.toml`, CLI entry point, `Makefile`, mypy config, tests, Dockerfile `CMD`) and the `logging.loggers.tenderai_bf` key in `tenderai-infra/settings.yaml` are **excluded** — deferred to a separate future spec (sub-project B). Do not rename them.
- `tenderai-infra/scripts/deploy.sh` is dead code (not invoked by any CI workflow) — leave it untouched.
- Production is unaffected — it still runs the old monorepo's images until tâche 13 (cutover prod) happens, which is separately gated on explicit user confirmation. This plan only touches the staging server.
- Old GHCR packages (`tenderai-bf-api`, `tenderai-bf-worker`, `tenderai-bf-frontend`) are **not deleted** — they become orphaned but stay in place. Never run a package-delete command as part of this plan.
- Local repo clones: `/home/yulcom/web/tenderai/tenderai-backend`, `/home/yulcom/web/tenderai/tenderai-frontend`, `/home/yulcom/web/tenderai/tenderai-infra` — each already checked out on branch `staging`. Before editing, always run `git status` and `git branch --show-current` in the target repo to confirm clean tree + correct branch.
- Every push to a repo's `staging` branch, and every `gh workflow run`/`gh run rerun`, is a real action against the live staging server and GitHub — confirm with the user before pushing/triggering, per this project's standing "explicit confirmation for pushes/deploys" practice used throughout chantier 1.

---

### Task 1: Rename image prefix in `tenderai-backend` CI

**Files:**
- Modify: `tenderai-backend/.github/workflows/ci.yml` (the `env.IMAGE_PREFIX` line, currently around line 10)

**Interfaces:**
- Produces: GHCR images `ghcr.io/abdazz/tenderai-api:staging` and `ghcr.io/abdazz/tenderai-worker:staging`, which Task 3's `docker-compose.server.yml` and Task 4's deploy rely on.

- [ ] **Step 1: Confirm repo state**

```bash
cd /home/yulcom/web/tenderai/tenderai-backend && git status && git branch --show-current
```
Expected: clean tree, branch `staging`.

- [ ] **Step 2: Edit the image prefix**

In `.github/workflows/ci.yml`, change:
```yaml
env:
  REGISTRY: ghcr.io
  IMAGE_PREFIX: ghcr.io/abdazz/tenderai-bf
```
to:
```yaml
env:
  REGISTRY: ghcr.io
  IMAGE_PREFIX: ghcr.io/abdazz/tenderai
```

- [ ] **Step 3: Commit**

```bash
cd /home/yulcom/web/tenderai/tenderai-backend
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
chore(ci): rename GHCR image prefix tenderai-bf -> tenderai

Product pivoted to multi-country in chantier 0; the BF (Burkina
Faso) suffix on image names is stale. Part of sub-project A of the
tenderai-bf naming cleanup (see docs/superpowers/specs/2026-08-28-
tenderai-bf-rename-infra-design.md in the monorepo).
EOF
)"
```

- [ ] **Step 4: Confirm with the user, then push**

Ask the user for explicit confirmation before pushing (this triggers a real CI build/push against GHCR). On yes:
```bash
cd /home/yulcom/web/tenderai/tenderai-backend && git push origin staging
```

- [ ] **Step 5: Watch the triggered CI run to completion**

```bash
sleep 8 && gh run list --repo Abdazz/tenderai-backend --branch staging --limit 3
```
Note the run ID from the row triggered by this push, then:
```bash
until gh run view <RUN_ID> --repo Abdazz/tenderai-backend --json status -q .status | grep -q completed; do sleep 15; done
gh run view <RUN_ID> --repo Abdazz/tenderai-backend
```
Expected: both jobs (`Lint & Test`, `Build & Push Images`) succeed, and the images pushed are `tenderai-api`/`tenderai-worker` (not `tenderai-bf-api`/`tenderai-bf-worker`).

- [ ] **Step 6: Handle a possible GHCR permission_denied on the new package names**

If the run fails with `permission_denied: write_package` on `ghcr.io/abdazz/tenderai-api` or `tenderai-worker` (this can happen because these are brand-new GHCR packages with no ACL yet, same class of issue hit during tâche 12): tell the user this needs the same manual fix used for the `-bf` packages — grant the `tenderai-backend` repo Write access under that package's "Manage Actions access" in the GitHub web UI (no CLI/API path exists for this on a personal account). Wait for the user to confirm they've done it, then:
```bash
gh run rerun <RUN_ID> --repo Abdazz/tenderai-backend
```
Repeat Step 5's wait-and-check until it succeeds.

---

### Task 2: Rename image prefix in `tenderai-frontend` CI

**Files:**
- Modify: `tenderai-frontend/.github/workflows/ci.yml` (the `env.IMAGE_PREFIX` line, currently around line 9)

**Interfaces:**
- Produces: GHCR image `ghcr.io/abdazz/tenderai-frontend:staging`, which Task 3's `docker-compose.server.yml` and Task 4's deploy rely on.

- [ ] **Step 1: Confirm repo state**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend && git status && git branch --show-current
```
Expected: clean tree, branch `staging`.

- [ ] **Step 2: Edit the image prefix**

In `.github/workflows/ci.yml`, change:
```yaml
env:
  REGISTRY: ghcr.io
  IMAGE_PREFIX: ghcr.io/abdazz/tenderai-bf
```
to:
```yaml
env:
  REGISTRY: ghcr.io
  IMAGE_PREFIX: ghcr.io/abdazz/tenderai
```

- [ ] **Step 3: Commit**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
chore(ci): rename GHCR image prefix tenderai-bf -> tenderai

Product pivoted to multi-country in chantier 0; the BF (Burkina
Faso) suffix on image names is stale. Part of sub-project A of the
tenderai-bf naming cleanup (see docs/superpowers/specs/2026-08-28-
tenderai-bf-rename-infra-design.md in the monorepo).
EOF
)"
```

- [ ] **Step 4: Confirm with the user, then push**

Ask the user for explicit confirmation before pushing. On yes:
```bash
cd /home/yulcom/web/tenderai/tenderai-frontend && git push origin staging
```

- [ ] **Step 5: Watch the triggered CI run to completion**

```bash
sleep 8 && gh run list --repo Abdazz/tenderai-frontend --branch staging --limit 3
```
Note the run ID, then:
```bash
until gh run view <RUN_ID> --repo Abdazz/tenderai-frontend --json status -q .status | grep -q completed; do sleep 15; done
gh run view <RUN_ID> --repo Abdazz/tenderai-frontend
```
Expected: both jobs (`Lint & Build`, `Build & Push Image`) succeed, image pushed as `tenderai-frontend` (not `tenderai-bf-frontend`).

- [ ] **Step 6: Handle a possible GHCR permission_denied on the new package name**

Same as Task 1 Step 6, but for `ghcr.io/abdazz/tenderai-frontend`: if `permission_denied: write_package` appears, tell the user to grant `tenderai-frontend` Write access on that package via GitHub's web UI, wait for confirmation, then `gh run rerun <RUN_ID> --repo Abdazz/tenderai-frontend` and repeat Step 5's wait.

---

### Task 3: Rename images and User-Agent in `tenderai-infra`

**Files:**
- Modify: `tenderai-infra/docker-compose.server.yml` (3 `image:` lines, currently lines 45/57/64)
- Modify: `tenderai-infra/settings.yaml` (the `user_agent` line, currently line 69)

**Interfaces:**
- Consumes: the new image names produced by Task 1 (`tenderai-api`, `tenderai-worker`) and Task 2 (`tenderai-frontend`).
- Produces: the `docker-compose.server.yml` state that Task 4's deploy pulls from the server.

- [ ] **Step 1: Confirm repo state**

```bash
cd /home/yulcom/web/tenderai/tenderai-infra && git status && git branch --show-current
```
Expected: clean tree, branch `staging`.

- [ ] **Step 2: Edit the three image references**

In `docker-compose.server.yml`, change:
```yaml
    image: ghcr.io/abdazz/tenderai-bf-api:${IMAGE_TAG}
```
to:
```yaml
    image: ghcr.io/abdazz/tenderai-api:${IMAGE_TAG}
```
Change:
```yaml
    image: ghcr.io/abdazz/tenderai-bf-frontend:${IMAGE_TAG}
```
to:
```yaml
    image: ghcr.io/abdazz/tenderai-frontend:${IMAGE_TAG}
```
Change:
```yaml
    image: ghcr.io/abdazz/tenderai-bf-worker:${IMAGE_TAG}
```
to:
```yaml
    image: ghcr.io/abdazz/tenderai-worker:${IMAGE_TAG}
```

- [ ] **Step 3: Edit the User-Agent string**

In `settings.yaml`, change:
```yaml
  user_agent: "TenderAI-BF/1.0 (+https://github.com/your-org/tenderai-bf)"
```
to:
```yaml
  user_agent: "TenderAI/1.0 (+https://github.com/your-org/tenderai)"
```

- [ ] **Step 4: Commit**

```bash
cd /home/yulcom/web/tenderai/tenderai-infra
git add docker-compose.server.yml settings.yaml
git commit -m "$(cat <<'EOF'
chore: rename tenderai-bf images to tenderai, drop BF from User-Agent

Matches the GHCR prefix rename in tenderai-backend/tenderai-frontend
CI (sub-project A of the tenderai-bf naming cleanup). Database name
and MinIO bucket name are intentionally left unchanged — see
docs/superpowers/specs/2026-08-28-tenderai-bf-rename-infra-design.md
in the monorepo.
EOF
)"
```

- [ ] **Step 5: Confirm with the user, then push**

Ask the user for explicit confirmation before pushing. On yes:
```bash
cd /home/yulcom/web/tenderai/tenderai-infra && git push origin staging
```
No CI build is triggered by this repo for these files — this step only updates what the next deploy will pull.

---

### Task 4: Redeploy staging and validate

**Files:** none (operational task — no file changes)

**Interfaces:**
- Consumes: the new images from Tasks 1-2 and the updated `docker-compose.server.yml` from Task 3. Do not start this task until Tasks 1, 2, and 3 have all completed successfully (their CI runs green, their commits pushed).

- [ ] **Step 1: Confirm with the user, then trigger the staging deploy**

Ask the user for explicit confirmation (this redeploys the live staging server). On yes:
```bash
gh workflow run deploy.yml --repo Abdazz/tenderai-infra --ref staging -f environment=staging -f image_tag=staging
```

- [ ] **Step 2: Watch the deploy run to completion**

```bash
sleep 8 && gh run list --repo Abdazz/tenderai-infra --workflow deploy.yml --limit 3
```
Note the run ID from the row just triggered, then:
```bash
until gh run view <RUN_ID> --repo Abdazz/tenderai-infra --json status -q .status | grep -q completed; do sleep 15; done
gh run view <RUN_ID> --repo Abdazz/tenderai-infra
```
Expected: `Deploy to Staging` job succeeds.

- [ ] **Step 3: Verify the health endpoint**

```bash
curl -s https://stagingtenderai.yulcom.net/health
```
Expected: `{"status":"healthy", ...}` with `database`, `storage`, `email` all healthy/configured — same shape as before this rename (functionality must be unchanged, only image names changed).

- [ ] **Step 4: Browser regression check**

Using the Claude-in-Chrome tools (load them via `ToolSearch` with query `"select:mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__computer,mcp__claude-in-chrome__find,mcp__claude-in-chrome__form_input,mcp__claude-in-chrome__tabs_close_mcp"` if not already loaded), navigate to `https://stagingtenderai.yulcom.net` and confirm nothing broke:
- Dashboard loads, shows healthy status tiles.
- Country selector switches between Burkina Faso and Canada.
- `/countries` page lists both countries.
- `/sources` list changes when the country selector changes.
- `/settings` header shows the currently selected country (e.g. "Pays: Canada").
- `/users` page shows the `admin` user with role `super_admin`.

This is a **regression check**, not new verification — all of this was already confirmed working during chantier 1 tâche 12 (see `docs/PROJECT_STATUS.md`). The only expected difference here is which image names are running underneath; UI/behavior must be identical. Close the browser tab when done.

- [ ] **Step 5: Update the monorepo's PROJECT_STATUS.md**

In `/home/yulcom/web/tender-ai/docs/PROJECT_STATUS.md`, add a note under the "Point non résolu... 'BF'" paragraph (in the tâche 12 subsection of Chantier 1) recording that sub-project A of the rename is complete, with the date, and that sub-project B (Python package rename) remains open. Commit and push (confirm with the user first, per this repo's established practice this session).

```bash
cd /home/yulcom/web/tender-ai
git add docs/PROJECT_STATUS.md
git commit -m "$(cat <<'EOF'
docs: mark tenderai-bf infra rename (sub-project A) complete

GHCR image prefix, docker-compose image names, and the scraper
User-Agent string are renamed tenderai-bf -> tenderai on staging.
Verified via /health and a full browser regression check. Sub-project
B (Python package tenderai_bf rename) remains open, un-scheduled.
EOF
)"
git push origin staging
```
