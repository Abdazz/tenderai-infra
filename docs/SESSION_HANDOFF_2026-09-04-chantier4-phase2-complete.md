# TenderAI — Handoff: Chantier 4 phase 2 complete, what's left

**Written:** 2026-09-04, end of session. **Purpose:** paste into a fresh Claude Code session to continue — this session ran long enough to need a clean handoff.

## Where things stand

Chantier 4 phase 2 (apply the audit's fixes) is **done and deployed to staging, verified live** — not just green tests, actual `run-once` executions against staging's real DB, checked with direct SQL queries before/after each batch of fixes. See `docs/PROJECT_STATUS.md`'s "Chantier 4" section for the full list of what got fixed (21 of the 29 original audit findings, plus 4 more bugs found live during verification that weren't in the original audit). Read that section before doing anything else here — this handoff only covers what's still open.

**Headline result:** BF went from 0 notices persisted for 4+ weeks to 57–376 per run depending on source. CA went from 0 notices, ever, on any source, to several hundred spread across 4+ distinct sources. Both verified with real numbers pulled from staging's Postgres, not just log messages.

**Production has not been touched.** Explicit user decision this session: stay on staging for now. Don't deploy to production without asking first — that's unchanged standing policy, not something this session waived.

## What's actually left open

In rough priority order:

1. **`max_items_per_run` is now a dead setting.** The user asked to remove the artificial cap that was causing cross-source starvation in `extract_item_links.py` (one dominant source — usually Achats Canada — filled the whole per-run item budget and silently starved every other source, even ones fetching successfully). That's done and verified (commit `4bdce0b` in `tenderai-backend`). But the setting itself — `country_settings`/`app_settings` in the DB, and a live form field in the frontend's admin Settings page (`tenderai-frontend/components/settings/pipeline-section.tsx`) — is still there and editable, and now does nothing. An admin changing it will see no effect and won't know why. Worth either: (a) removing the field from the DB schema + API + frontend UI entirely, or (b) leaving it but adding a clear "no longer enforced" note in the UI. Nobody has decided which; ask the user before picking.

2. **Constat #8 (BF `unique_items: 0` historical anomaly) — not reproduced, not fixed.** The audit's hypothesis was a counter divergence in `deduplicate.py` between `counts_json`'s `items_parsed` and `state.items_parsed`. Every real run this session (several BF harvests) reported non-zero, internally consistent `unique_items` — the anomaly never showed up. That could mean it's already fixed as a side effect of something else this session touched (persist_notices isolation? date parsing?), or it could mean it just didn't trigger under today's specific conditions. Don't assume it's fixed — if it resurfaces, the audit's original hypothesis (`docs/audits/2026-09-01-pipeline-quality-audit-report.md`, constat #8/#9, Finding BF-2) is still the best lead.

3. **Constat #17 (The Commonwealth AJAX architecture question) — still open.** `TAVILY_API_KEY` is now live on staging (user set it directly, 2026-09-04), and the source fetches with `status: success`. But the portal currently has zero active tenders, so a successful fetch with zero results doesn't actually prove `tavily_extract`/`extract_depth: advanced` executes the site's `LoadProjects` AJAX call — it's equally consistent with the extract call succeeding against an empty static shell. This needs the portal to actually publish a tender before it can be confirmed either way. Not actionable right now; just don't mark it resolved.

4. **Everything else from the audit's #18, #20, #21, #24, #26, #27, #28** is unchanged — latent, measurement-only, or external/intermittent per the audit's own categorization. No known code fix exists for any of them; re-read the audit report's §(b) table if picking one up.

5. **Scrapling spike** — narrower than when the audit was written. Two of the three originally-named stealth targets (UNDP Africa, BAD/AfDB) are now confirmed working through Tavily, not Scrapling — verified live: both fetch and persist successfully post-`TAVILY_API_KEY`. The only remaining plausible justification is Nova Scotia under **sustained** production load (today's tests were one-off runs, not repeated traffic) — and only if that source actually degrades, which hasn't happened yet. Still not worth spiking now.

6. **Cosmetic, explicitly left alone per user request:** the staging deploy directory on the server is named `/home/tender-ai/Staging-TenderAI-Infra` (PascalCase, pre-dates the repo split) instead of matching the `tenderai-infra` naming convention everything else uses. It's the correct repo/branch, deploys correctly — just an inconsistent name. User said leave it.

## Repos and where things landed

- **`tenderai-backend`** (`/home/yulcom/web/tenderai/tenderai-backend`, branch `staging`, HEAD `4bdce0b`) — all 17 phase-2 fix commits here, from `4ef128c` (persist_notices isolation) through `4bdce0b` (cross-source cap removal). Migrations `0017`–`0020` applied on staging.
- **`tenderai-infra`** (`/home/yulcom/web/tenderai`, branch `staging`, HEAD `0fbf565`) — `deploy.yml`'s self-healing `logs/nodes` permission fix, `GROQ_MODEL`/`TAVILY_API_KEY` env template docs.
- **`tenderai-frontend`** — untouched this session except one doc-only commit (`535d491`, repo-layout note).
- **Staging server:** `tender-ai@195.35.48.198`, deploy path `/home/tender-ai/Staging-TenderAI-Infra` (see item 6 above). SSH key `~/.ssh/id_ed25519`. URL `https://stagingtenderai.yulcom.net`.

## Verification pattern used this session (works well, reuse it)

```bash
# Trigger a real run and capture full output
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_api python -m tenderai.cli run-once --country-code <BF|CA> --company-code yulcom --triggered-by <label> --test"

# Check the actual harvest result and per-source breakdown directly
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 "
docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \"
SELECT id, status, counts_json, error_message FROM runs
WHERE run_type='harvest' ORDER BY started_at DESC LIMIT 1;\"
docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \"
SELECT s.name, count(*) FROM notices n JOIN sources s ON n.source_id=s.id
GROUP BY s.name ORDER BY count(*) DESC;\"
"
```

Note: `docker exec staging_api ... run-once` on a full BF harvest (DGCMEF's ~265 LLM chunks) or a full CA harvest (Ville de Montréal's 90+ Playwright pages) can take 5–15 minutes. Launch it detached (`&` + redirect to a file) if running from an interactive SSH session that might get interrupted — it survives the SSH connection dropping, unlike a foregrounded command.

Also: `/app/logs/nodes` permission is now self-healing on every `deploy.yml` run (constat #29 fix) — no more manual `docker exec -u root ... chown` needed after a redeploy, unlike earlier in this session.

## First message to send in the new session

Something like: *"Read `docs/SESSION_HANDOFF_2026-09-04-chantier4-phase2-complete.md` for context on chantier 4's current state. Let's decide what to do about the now-dead `max_items_per_run` setting."* — or whichever of the open items above you want to pick up first.
