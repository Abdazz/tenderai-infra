# TenderAI — Handoff: Chantier 4 phase 2 (apply the fixes)

**Written:** 2026-09-02, end of session. **Purpose:** paste into a fresh Claude Code session to continue immediately — this session is too long to keep going in.

## Where things stand

Chantier 4 (pipeline quality audit) **diagnostic phase is complete, reviewed, and pushed**:
- Report: `docs/audits/2026-09-01-pipeline-quality-audit-report.md` in `/home/yulcom/web/tender-ai` (monorepo, branch `staging`, commit `82045e3`, pushed to `origin/staging`).
- 29 findings, every one independently code-reviewed (several through fix-and-re-review loops), plus a whole-branch final review and one closing fix wave — all clean, no open findings.
- Headline: **the pipeline has an availability problem, not a relevance problem** — both BF and CA currently sit at **0 notices in the database**. Every one of the 29 findings is labeled `bug logique` (trivially fixable) except one open architectural question (The Commonwealth, needs a live Tavily key to resolve). The separately-tracked "Scrapling spike" should **not** proceed now — two of its three justifications are directly falsified by this audit's own evidence.
- **The user has now reviewed this report and asked to apply the fixes.** That's this handoff's job.

## What "apply the fixes" means — scope

The report's own `### (d) Si l'on ne pouvait corriger que 3 choses` section (report lines ~116-135) names the three highest-leverage fixes, with reasoning for why these three over the rest of the 29. **Start there.** In priority order:

1. **`persist_notices` transaction isolation + real date parsing** (findings #1 and #11). One file (`tenderai-backend/src/tenderai/agents/nodes/persist_notices.py`) currently does one `db.commit()` after the whole loop with no per-item isolation, and assigns a raw, unparsed date string directly into a `DateTime` column. A single malformed date (already recurred in production 4 times since 2026-08-29, most recently the routine 07:00 run on 09-01) crashes the whole transaction and destroys every other source's collected notices for that run. Fix: per-item try/except with individual commits or savepoints, and parse dates into real `date` objects before insert — don't just catch the crash, the silent-corruption corollary (a date like `29-09-2026` for day ≤ 12 would silently get misread by Postgres as MM-DD without erroring at all) needs fixing too. **This unblocks everything else in BF — nothing else matters until this lands.**

2. **CA deployment gaps** (findings #2 and #3). `playwright` is not installed in the `staging_api` image (`ModuleNotFoundError`), and `TAVILY_API_KEY` is unset in the container environment. Fixing these two — a Dockerfile/poetry line and an env var — flips 6 of CA's 7 enabled sources from 0% to something, and unblocks 4 of the 9 currently-disabled CA sources for reactivation (all `tavily_extract`). This is infra/deployment work, likely touching `tenderai-infra` (env vars, secrets) as well as `tenderai-backend`'s Dockerfile.

3. **UNGM and UEMOA pagination bugs** (findings #7 and #6). UNGM: `fetch_ungm.py:28` hardcodes `PageIndex: 0`, never loops — needs a `for` loop over pages. UEMOA: the `patterns` DB column has `max_pages: 1` and no `pagination_url` — needs updating to match Enabel's already-working config on the identical code path (pure DB config change, no code). Near-zero-cost, recovers ~40 UNGM + ~184 UEMOA notices/day.

**Beyond the top 3**, the report's findings table (`### (b)`, report lines 61-92) has the full prioritized list of all 29 — read it before planning further work. Notable ones not in the top 3 but flagged as high-value: #12 (no alerting when collection dies — this is *why* BF stayed broken 3+ weeks and CA never worked, unnoticed; cheap to add: alert on `notices_persisted == 0` while `unique_items > 0`), #8/#9 (`unique_items: 0` anomaly, unresolved, needs investigation not just a fix — do this once #1 is fixed, since the symptom becomes directly observable then), #5 (Le Devoir's dead Groq Vision model id — trivial one-line fix, already live-proven by swapping to `qwen/qwen3.8-27b` during the audit), #10 (Enabel missing `pdf_selector`, causes false-dedup), #13 (dedup similarity threshold too aggressive, destroying real distinct notices).

## How to proceed — process

This project's established workflow (see `/home/yulcom/web/tenderai/CLAUDE.md` and `tenderai-backend/CLAUDE.md`) uses the `superpowers` skill chain for new work: **`brainstorming` → `writing-plans` → `subagent-driven-development`** (or `executing-plans`). Given the scope (multiple independent code fixes across `tenderai-backend`, possibly `tenderai-infra`), **use brainstorming first** to scope this properly with the user — likely as an architectural or bounded plan, not ad hoc edits. Probable decomposition: the user may want fix #1 done as its own tightly-scoped plan first (it's the most consequential and most isolated), then a second plan bundling #2+#3, then subsequent smaller plans for the rest — don't assume; ask.

**Git workflow (mandatory, unchanged):** all repos need a `staging` branch, work lands there first, `main` only after separate explicit user confirmation (never assumed). This chantier's own diagnostic work was committed directly to `tender-ai`'s `staging` and pushed — same pattern holds for the fix work, but this time it's on `tenderai-backend`'s (and possibly `tenderai-infra`'s) `staging`, not the monorepo.

**Repos:**
- `tenderai-backend` — `/home/yulcom/web/tenderai/tenderai-backend`, branch `staging`, latest commit `567e4e6`. This is where findings #1, #5, #6 (partial — DB config, not code), #7, #10, #11, #12, #13 get fixed.
- `tenderai-infra` — `/home/yulcom/web/tenderai/tenderai-infra`. Likely needed for finding #2's env-var/Dockerfile work and for deploying whatever gets fixed to staging for verification.
- `tender-ai` (this monorepo) — `/home/yulcom/web/tender-ai`, docs-only now, holds the audit report and `PROJECT_STATUS.md`. Update `PROJECT_STATUS.md`'s Chantier 4 section as fix work lands (it currently says diagnostic-phase-complete, phase 2 not started).

**Staging server access:** SSH `tender-ai@195.35.48.198` with `~/.ssh/id_ed25519` (not the `admin@195.35.48.19` that was tried and failed in an earlier session). Staging URL: `https://stagingtenderai.yulcom.net`. Deploy via `tenderai-infra`'s `deploy.yml` GitHub Actions workflow.

**Verification pattern established this session** (worth reusing for fix verification): trigger a real `run-once` on staging via `docker exec staging_api python -m tenderai.cli run-once --country-code <BF|CA> --company-code yulcom --triggered-by <label> --test`, capture node logs (`docker exec staging_api tar -C /app/logs -cf - nodes`) and query the `notices`/`runs` tables directly — this is how the audit proved every finding, and it's the natural way to prove each fix actually works before calling it done.

## Standing constraints (carry forward, unchanged)

- No production deploy without separate explicit authorization (never given).
- Never type passwords/credentials into forms even when handed them directly — ask the user.
- Don't pause for per-action confirmation on pushing to staging / triggering deploys (standing instruction from prior sessions) — but DO get sign-off on the fix plan itself before implementing (this is new code-change work, unlike the read-only audit).
- TenderAI is multi-tenant AND multi-country — never frame it as Burkina-Faso-specific (this was explicitly corrected this session, both root `CLAUDE.md` files were fixed).

## First message to send in the new session

Something like: *"Continue chantier 4 phase 2 — apply the fixes from the audit report. Read `docs/SESSION_HANDOFF_2026-09-02-chantier4-phase2.md` in the tender-ai monorepo for full context, then read the audit report's §(b) and §(d), and let's brainstorm the fix plan starting with finding #1 (persist_notices transaction isolation)."*
