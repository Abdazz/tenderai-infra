# Audit qualité et exhaustivité du pipeline de collecte (chantier 4) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a sourced, per-source diagnostic report of recall (missed relevant tenders) and precision (irrelevant tenders surfaced) gaps across every enabled source (5 BF + 7 CA) on staging, plus a light pass on the 9 disabled CA sources, with each gap root-caused against a fixed taxonomy (fetch/parse/classify/dedup/delivery/config) and labeled as a logic bug, an architectural limit, or a technology limit. No fixes are applied in this plan — that is deliberately a separate, later plan gated on user review of this report.

**Architecture:** This is an investigative audit, not a code change — there is no source code being written except the final doc-cleanup task. Each source-level task independently collects a live "ground truth" listing from the real portal (via browser) and cross-references it against a snapshot of that source's actual pipeline run (DB rows + per-node JSON logs), captured once per country by a shared setup task. Findings accumulate as append-only subsections of one shared Markdown report; no two tasks edit the same subsection.

**Tech Stack:** SSH to the staging server, `docker exec staging_api python -m tenderai.cli run-once` to trigger real runs, `docker exec staging_postgres psql` for DB inspection, Chrome browser automation (`mcp__claude-in-chrome__*`) for live ground truth, Markdown for the report.

**Spec:** `docs/superpowers/specs/2026-09-01-pipeline-quality-audit-design.md`

## Global Constraints

- **Staging only.** SSH: `ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198`. The box also runs `prod_api`/`prod_worker`/`prod_postgres` containers — never target those. All commands below target `staging_api` / `staging_postgres`.
- **DB access:** `docker exec staging_postgres psql -U tenderai -d tenderai_bf -c "<query>"` (the database is still named `tenderai_bf` — a deliberately-untouched resource name, not a scope signal; see [[tenderai-not-bf-specific]]).
- **The only company on staging is `id=1`, `slug=yulcom` (YULCOM Technologies), subscribed to both BF and CA.** Every relevance judgment in this audit is made against **its actual configured classification criteria**, not the executor's own judgment of what "sounds relevant." That criteria (`company_settings` row, `company_id=1`, `section='classification'`), captured 2026-09-01, is:
  ```json
  {
    "relevant_keywords": {
      "it_services": ["informatique", "logiciel", "développement", "application", "système d'information", "base de données", "réseau informatique", "réseau local", "cybersécurité", "sécurité informatique", "cloud", "numérique", "digital", "site web", "plateforme", "e-gouvernement", "gestion électronique", "télécommunication", "fibre optique", "wifi", "internet", "système de gestion", "ERP", "CRM", "SIG", "GIS", "vidéoconférence", "intelligence artificielle", "data center", "hébergement", "infogérance"],
      "it_hardware": ["équipement informatique", "matériel informatique", "ordinateur", "ordinateur portable", "serveur", "poste de travail", "imprimante", "scanner", "photocopieur", "disque dur", "disque SSD", "mémoire RAM", "accessoires informatiques", "consommables informatiques", "écran", "moniteur", "clavier", "souris", "routeur", "switch réseau", "switch", "modem", "point d'accès wifi", "onduleur", "groupe électrogène informatique", "webcam", "péri-informatique", "liaison informatique"],
      "it_consulting": ["étude informatique", "audit informatique", "audit de sécurité", "assistance technique informatique", "consultant informatique", "consultant IT", "expertise informatique", "schéma directeur informatique", "formation informatique", "mise en place d'un système", "mise en œuvre d'un système", "déploiement", "intégration de système", "recrutement d'un consultant"]
    },
    "min_relevance_score": 0.7
  }
  ```
  If a task finds this has changed on staging, re-fetch it (`SELECT data FROM company_settings WHERE company_id=1 AND section='classification';`) and use the live value, noting the discrepancy in the report.
- **Root-cause taxonomy** (every finding is tagged with one, plus a logic-bug/architectural-limit/technology-limit label): Fetch (pagination, anti-bot blocking, broken selector, rate limit, stale `list_url`) · Parse (extraction failure) · Classify (criteria too strict/loose, LLM misjudgment) · Dedup (false merge, or true duplicate not merged) · Delivery (cursor/status bug) · Config (source disabled without valid reason, stale config).
- **Report file (shared, append-only):** `docs/audits/2026-09-01-pipeline-quality-audit-report.md` in this repo (`/home/yulcom/web/tender-ai`). Task 1 creates it with the skeleton below. Every later task edits **only its own named section** — never touch another task's section, to avoid clobbering concurrent work. Commit after every task.
- **Node logs are overwritten per run, not run-scoped on disk.** `/app/logs/nodes/<node>.json` inside `staging_api` holds only the *latest* run's output for that node (each entry does carry a `_run_id` field though). Pull them (`docker exec staging_api tar -C /app/logs -cf - nodes | tar -C <local dir> -xf -`) **immediately** after the triggering CLI command returns, before doing anything else, and sanity-check the `_run_id`/`_logged_at` fields inside match the run you just triggered (a scheduled APScheduler run could in principle interleave — if the run_id doesn't match what you captured from the `runs` table, re-trigger and re-capture).
- **Always pass `--test`** on `run-once` (test mode sends the report only to the admin email, not real recipients) — this audit must not spam real recipients.
- **Never trigger a run for any company/country combination other than `yulcom`/`BF` or `yulcom`/`CA`.**
- Use the scratchpad directory for any local snapshot files: `/tmp/claude-1000/-home-yulcom-web-tenderai/7a9c423b-d549-4280-8ade-3a5e7671a5b4/scratchpad/audit/`.

## Report Skeleton (Task 1 writes this verbatim, then every task fills in its own section)

```markdown
# Audit qualité et exhaustivité du pipeline de collecte — Rapport

**Date :** 2026-09-01
**Spec :** docs/superpowers/specs/2026-09-01-pipeline-quality-audit-design.md
**Méthode :** trace de bout en bout avec vérité terrain indépendante (voir spec §2)

## Sommaire exécutif
_(rempli par la tâche de synthèse — ne pas éditer avant)_

## Burkina Faso

### DGCMEF (source id 8, parser_type pdf_rag)
_(rempli par sa propre tâche)_

### Joffres.net (source id 9, parser_type html-listing)
_(rempli par sa propre tâche)_

### UNGM (source id 10, parser_type ungm)
_(rempli par sa propre tâche)_

### UEMOA (source id 11, parser_type html-tender)
_(rempli par sa propre tâche)_

### Enabel (source id 12, parser_type html-tender)
_(rempli par sa propre tâche)_

## Canada

### Achats Canada (source id 13, parser_type playwright)
_(rempli par sa propre tâche)_

### Ville de Montréal (source id 14, parser_type playwright)
_(rempli par sa propre tâche)_

### Le Devoir (source id 15, parser_type ledevoir)
_(rempli par sa propre tâche)_

### Nova Scotia (source id 16, parser_type playwright)
_(rempli par sa propre tâche)_

### UNDP (source id 17, parser_type tavily_extract)
_(rempli par sa propre tâche)_

### The Commonwealth (source id 20, parser_type tavily_extract)
_(rempli par sa propre tâche)_

### Palladium Group (source id 25, parser_type tavily_extract)
_(rempli par sa propre tâche)_

### Sources désactivées (9 sources)
_(rempli par sa propre tâche)_
```

Each per-source section must contain, at minimum: the ground-truth list (title + timestamp collected), the pipeline result (what was fetched/persisted/classified for that source, with counts), a gaps table (`| Titre | Vu par le pipeline ? | Étage où perdu/faux positif | Cause racine | Étiquette (bug/archi/techno) | Sévérité | Preuve |`), and a one-paragraph verdict.

---

### Task 1: BF harvest+delivery run, snapshot capture, report skeleton

**Files:**
- Create: `docs/audits/2026-09-01-pipeline-quality-audit-report.md` (skeleton above)

**Interfaces:**
- Produces: a local snapshot directory `/tmp/claude-.../scratchpad/audit/bf-nodes/` containing the copied `/app/logs/nodes/*.json` files from the triggered BF run, and a recorded `run_id` (harvest) + `run_id` (delivery) for that run, both written into a short "Run snapshot" note at the top of the BF section in the report so Tasks 2-6 can find them.

- [ ] **Step 1: Trigger the BF harvest+delivery run**

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_api python -m tenderai.cli run-once --country-code BF --company-code yulcom --triggered-by audit --test"
```

Wait for it to finish (prints `✅ Harvest completed` / `✅ Delivery completed successfully!` or an error — record any error verbatim in the report, it's a finding on its own).

- [ ] **Step 2: Immediately capture the run IDs**

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT id, run_type, status, counts_json, started_at, finished_at FROM runs WHERE country_id=(SELECT id FROM countries WHERE code='BF') ORDER BY started_at DESC LIMIT 3;\""
```

Note the harvest run's `id` and the delivery run's `id` (they're separate rows, `run_type` distinguishes them).

- [ ] **Step 3: Immediately capture the node logs**

```bash
mkdir -p /tmp/claude-1000/-home-yulcom-web-tenderai/7a9c423b-d549-4280-8ade-3a5e7671a5b4/scratchpad/audit/bf-nodes
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 "docker exec staging_api tar -C /app/logs -cf - nodes" | \
  tar -C /tmp/claude-1000/-home-yulcom-web-tenderai/7a9c423b-d549-4280-8ade-3a5e7671a5b4/scratchpad/audit/bf-nodes -xf -
```

Open `fetch_listings.json` in that directory and confirm the `_run_id` field matches the harvest run id from Step 2. If it doesn't match, another run interleaved — re-run Steps 1-3.

- [ ] **Step 4: Write the report skeleton**

Write the exact Markdown skeleton from the "Report Skeleton" section above to `docs/audits/2026-09-01-pipeline-quality-audit-report.md`. Under the `## Burkina Faso` heading, before the source subsections, add:

```markdown
**Run snapshot (BF) :** harvest run `<id from step 2>`, delivery run `<id from step 2>`, déclenché `<timestamp>`, logs de nœuds capturés dans `bf-nodes/` (scratchpad de session). Critères de pertinence utilisés : voir Contraintes globales du plan.
```

- [ ] **Step 5: Commit**

```bash
cd /home/yulcom/web/tender-ai
git add docs/audits/2026-09-01-pipeline-quality-audit-report.md
git commit -m "docs(audit): create chantier 4 report skeleton, capture BF run snapshot

Claude-Session: https://claude.ai/code/session_01HibCiDKyx7nhNxhSERgGtQ"
```

---

### Task 2: Audit source — DGCMEF (BF, id 8, pdf_rag)

**Files:**
- Modify: `docs/audits/2026-09-01-pipeline-quality-audit-report.md` (only the `### DGCMEF` subsection)

**Interfaces:**
- Consumes: the BF run snapshot from Task 1 (`bf-nodes/` directory, harvest/delivery run IDs recorded in the report's "Run snapshot (BF)" line).

- [ ] **Step 1: Collect live ground truth**

Use the Chrome browser tool to open `https://www.dgcmef.gov.bf/fr/appels-d-offre` right now. List every tender currently shown (title, reference if visible, deadline if visible). Note the exact timestamp you did this.

- [ ] **Step 2: Inspect the fetch-stage snapshot for this source**

```bash
grep -i "dgcmef\|DGCMEF" -A5 /tmp/claude-1000/-home-yulcom-web-tenderai/7a9c423b-d549-4280-8ade-3a5e7671a5b4/scratchpad/audit/bf-nodes/nodes/fetch_listings.json
```

Note whether the fetch succeeded, how many items it returned, and any error. `parser_type` is `pdf_rag` — this source parses PDFs via RAG, so also check `parse_extract.json` (or `parse_pdf_rag.json` if that node logs separately — check both) for extraction failures on this source's items.

- [ ] **Step 3: Query the persisted/classified result**

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=8 ORDER BY n.created_at DESC LIMIT 50;\""
```

- [ ] **Step 4: Cross-reference and root-cause every gap**

For every ground-truth item not appearing in the query result: check whether it appeared in the fetch-stage log (Step 2) — if yes, it was dropped downstream (parse/classify/dedup — narrow it down using the intermediate node logs in the same `bf-nodes/` directory); if no, it's a fetch-stage miss (pagination, blocking, selector — check the actual page structure against what the parser expects, in `src/tenderai/agents/nodes/fetch_listings.py` around the `pdf_rag` branch).

For every notice present with `is_relevant=true` that doesn't obviously match the keyword list in Global Constraints: read its `description`, check whether a keyword genuinely matches (even loosely) — if not, it's a classify false positive.

- [ ] **Step 5: Write the findings and commit**

Fill in the `### DGCMEF` subsection per the report format (ground truth, pipeline result, gaps table, verdict).

```bash
cd /home/yulcom/web/tender-ai
git add docs/audits/2026-09-01-pipeline-quality-audit-report.md
git commit -m "docs(audit): DGCMEF source findings

Claude-Session: https://claude.ai/code/session_01HibCiDKyx7nhNxhSERgGtQ"
```

---

### Task 3: Audit source — Joffres.net (BF, id 9, html-listing)

Same structure as Task 2, targeting the `### Joffres.net` subsection only.

- [ ] **Step 1:** Ground truth from `https://joffres.net/recherche?domaine=Informatique+%26+D%C3%A9veloppement&localisation=&societe=&secteur=&prevision=0%2F1000000000&date_publication=&date_expiration=&statut=` (the exact `list_url` configured in DB — use it verbatim, not a generic search, since a different query string would give different results than what the pipeline actually fetches).
- [ ] **Step 2:** `grep -i "joffres" -A5 .../bf-nodes/nodes/fetch_listings.json` — note this source has a special-cased branch in `fetch_listings.py` (`if parser_type == "html-listing" and "joffres" in source_name.lower()`) — check whether that branch actually ran and check for anti-bot signs (the code comment in `fetch_all_listings` explicitly mentions joffres.net drops connections on non-browser User-Agents — verify the response wasn't silently truncated/blocked).
- [ ] **Step 3:** Query the persisted/classified result:

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=9 ORDER BY n.created_at DESC LIMIT 50;\""
```

- [ ] **Step 4:** Cross-reference and root-cause every gap: for every ground-truth item not appearing in the Step 3 result, check whether it appeared in the fetch-stage log (Step 2) — if yes, it was dropped downstream (parse/classify/dedup — narrow it down using the intermediate node logs in `bf-nodes/nodes/`); if no, it's a fetch-stage miss (pagination, blocking, selector). For every notice present with `is_relevant=true` that doesn't obviously match the keyword list in Global Constraints, read its `description` and check whether a keyword genuinely matches (even loosely) — if not, it's a classify false positive.
- [ ] **Step 5:** Fill in `### Joffres.net`, commit with message `docs(audit): Joffres.net source findings` (same trailer as above).

---

### Task 4: Audit source — UNGM (BF, id 10, ungm)

Same structure as Task 2, targeting the `### UNGM` subsection only.

- [ ] **Step 1:** Ground truth from `https://www.ungm.org/Public/Notice/Search`, filtered to Burkina Faso if the site's own filter allows it (use the site's country filter to match what the pipeline is scoped to — note in the report exactly which filter you applied, since UNGM is a global site).
- [ ] **Step 2:** `grep -i "ungm" -A5 .../bf-nodes/nodes/fetch_listings.json`. UNGM is a common anti-bot target (already flagged in `docs/PROJECT_STATUS.md`'s Scrapling spike writeup) — pay particular attention to blocking/CAPTCHA signs in the raw response.
- [ ] **Step 3:** Query the persisted/classified result:

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=10 ORDER BY n.created_at DESC LIMIT 50;\""
```

- [ ] **Step 4:** Cross-reference and root-cause every gap: for every ground-truth item not appearing in the Step 3 result, check whether it appeared in the fetch-stage log (Step 2) — if yes, it was dropped downstream (parse/classify/dedup — narrow it down using the intermediate node logs in `bf-nodes/nodes/`); if no, it's a fetch-stage miss (pagination, blocking, selector). For every notice present with `is_relevant=true` that doesn't obviously match the keyword list in Global Constraints, read its `description` and check whether a keyword genuinely matches (even loosely) — if not, it's a classify false positive. If this source shows fetch-stage blocking, explicitly label the finding as a **technology limit** (candidate for the Scrapling `StealthyFetcher` spike) rather than a logic bug.
- [ ] **Step 5:** Fill in `### UNGM`, commit with message `docs(audit): UNGM source findings`.

---

### Task 5: Audit source — UEMOA (BF, id 11, html-tender)

Same structure as Task 2, targeting the `### UEMOA` subsection only.

- [ ] **Step 1:** Ground truth from `https://www.uemoa.int/appel-d-offre`.
- [ ] **Step 2:** `grep -i "uemoa" -A5 .../bf-nodes/nodes/fetch_listings.json`. This source's config (`patterns` column) sets `"max_pages": 1` and `"ssl_verify": false` — check whether the live listing has more than one page's worth of items (if so, `max_pages: 1` is a direct, provable fetch-stage cause for missed items) and whether `ssl_verify: false` correlates with any certificate/connection issue visible in the log.
- [ ] **Step 3:** Query the persisted/classified result:

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=11 ORDER BY n.created_at DESC LIMIT 50;\""
```

- [ ] **Step 4:** Cross-reference and root-cause every gap: for every ground-truth item not appearing in the Step 3 result, check whether it appeared in the fetch-stage log (Step 2) — if yes, it was dropped downstream (parse/classify/dedup — narrow it down using the intermediate node logs in `bf-nodes/nodes/`); if no, it's a fetch-stage miss (pagination, blocking, selector — incorporate the `max_pages`/`ssl_verify` check from Step 2 here). For every notice present with `is_relevant=true` that doesn't obviously match the keyword list in Global Constraints, read its `description` and check whether a keyword genuinely matches (even loosely) — if not, it's a classify false positive.
- [ ] **Step 5:** Fill in `### UEMOA`, commit with message `docs(audit): UEMOA source findings`.

---

### Task 6: Audit source — Enabel (BF, id 12, html-tender)

Same structure as Task 2, targeting the `### Enabel` subsection only.

- [ ] **Step 1:** Ground truth from `https://www.enabel.be/fr/marches-publics/?in_country=1726&is_status=0`, and manually page through using the same pagination pattern the source config uses (`https://www.enabel.be/fr/marches-publics/page/{page}/?in_country=1726&is_status=0`) up to at least page 3 (the configured `max_pages`), noting if a page 4+ exists with more items.
- [ ] **Step 2:** `grep -i "enabel" -A5 .../bf-nodes/nodes/fetch_listings.json`. Cross-check the actual number of pages fetched against `max_pages: 3` from config.
- [ ] **Step 3:** Query the persisted/classified result:

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=12 ORDER BY n.created_at DESC LIMIT 50;\""
```

- [ ] **Step 4:** Cross-reference and root-cause every gap: for every ground-truth item not appearing in the Step 3 result, check whether it appeared in the fetch-stage log (Step 2) — if yes, it was dropped downstream (parse/classify/dedup — narrow it down using the intermediate node logs in `bf-nodes/nodes/`); if no, it's a fetch-stage miss (pagination, blocking, selector). For every notice present with `is_relevant=true` that doesn't obviously match the keyword list in Global Constraints, read its `description` and check whether a keyword genuinely matches (even loosely) — if not, it's a classify false positive.
- [ ] **Step 5:** Fill in `### Enabel`, commit with message `docs(audit): Enabel source findings`.

---

### Task 7: CA harvest+delivery run, snapshot capture

Mirrors Task 1's procedure, targeting CA instead of BF.

**Interfaces:**
- Produces: a local snapshot directory `/tmp/claude-.../scratchpad/audit/ca-nodes/` containing the copied `/app/logs/nodes/*.json` files from the triggered CA run, and a recorded `run_id` (harvest) + `run_id` (delivery), both written into a "Run snapshot (CA)" note under `## Canada` in the report so Tasks 8-14 can find them.

- [ ] **Step 1: Trigger the CA harvest+delivery run**

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_api python -m tenderai.cli run-once --country-code CA --company-code yulcom --triggered-by audit --test"
```

Wait for it to finish. Record any error verbatim in the report.

- [ ] **Step 2: Immediately capture the run IDs**

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT id, run_type, status, counts_json, started_at, finished_at FROM runs WHERE country_id=(SELECT id FROM countries WHERE code='CA') ORDER BY started_at DESC LIMIT 3;\""
```

- [ ] **Step 3: Immediately capture the node logs**

```bash
mkdir -p /tmp/claude-1000/-home-yulcom-web-tenderai/7a9c423b-d549-4280-8ade-3a5e7671a5b4/scratchpad/audit/ca-nodes
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 "docker exec staging_api tar -C /app/logs -cf - nodes" | \
  tar -C /tmp/claude-1000/-home-yulcom-web-tenderai/7a9c423b-d549-4280-8ade-3a5e7671a5b4/scratchpad/audit/ca-nodes -xf -
```

Open `fetch_listings.json` in that directory and confirm the `_run_id` field matches the harvest run id from Step 2. If it doesn't match, re-run Steps 1-3.

- [ ] **Step 4: Record the run snapshot in the report**

Under the `## Canada` heading, before the source subsections, add:

```markdown
**Run snapshot (CA) :** harvest run `<id from step 2>`, delivery run `<id from step 2>`, déclenché `<timestamp>`, logs de nœuds capturés dans `ca-nodes/` (scratchpad de session). Critères de pertinence utilisés : voir Contraintes globales du plan.
```

- [ ] **Step 5: Commit**

```bash
cd /home/yulcom/web/tender-ai
git add docs/audits/2026-09-01-pipeline-quality-audit-report.md
git commit -m "docs(audit): capture CA run snapshot

Claude-Session: https://claude.ai/code/session_01HibCiDKyx7nhNxhSERgGtQ"
```

---

### Task 8: Audit source — Achats Canada (CA, id 13, playwright)

Same structure as Task 2, targeting `### Achats Canada`, consuming the CA snapshot from Task 7.

- [ ] **Step 1:** Ground truth from `https://achatscanada.canada.ca/fr/occasions-de-marche?search_filter=&status%5B87%5D=87&category%5B154%5D=154&Appliquer_les_filtres=Appliquer+les+filtres&record_per_page=100&current_tab=t&words=` (the exact configured `list_url`).
- [ ] **Step 2:** `grep -i "achats canada" -A5 .../ca-nodes/nodes/fetch_listings.json`. `parser_type` is `playwright` — check `src/tenderai/agents/nodes/fetch_playwright.py` and note this repo's own docs flag Playwright here as using a bare/hardcoded UA with no stealth (per `docs/PROJECT_STATUS.md`'s Scrapling writeup) — if you see blocking, label it a technology limit.
- [ ] **Step 3:** Query the persisted/classified result:

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=13 ORDER BY n.created_at DESC LIMIT 50;\""
```

- [ ] **Step 4:** Cross-reference and root-cause every gap: for every ground-truth item not appearing in the Step 3 result, check whether it appeared in the fetch-stage log (Step 2) — if yes, it was dropped downstream (parse/classify/dedup — narrow it down using the intermediate node logs in `ca-nodes/nodes/`); if no, it's a fetch-stage miss (pagination, blocking, selector). For every notice present with `is_relevant=true` that doesn't obviously match the keyword list in Global Constraints, read its `description` and check whether a keyword genuinely matches (even loosely) — if not, it's a classify false positive.
- [ ] **Step 5:** Fill in `### Achats Canada`, commit with message `docs(audit): Achats Canada source findings`.

---

### Task 9: Audit source — Ville de Montréal (CA, id 14, playwright)

Same structure as Task 2, targeting `### Ville de Montréal`, consuming the CA snapshot from Task 7.

- [ ] **Step 1:** Ground truth from `https://montreal.ca/avis-dappel-doffres?types=Appel+d%27offres&categories=Services+professionnels`.
- [ ] **Step 2:** `grep -i "montr" -A5 .../ca-nodes/nodes/fetch_listings.json`.
- [ ] **Step 3:** Query the persisted/classified result:

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=14 ORDER BY n.created_at DESC LIMIT 50;\""
```

- [ ] **Step 4:** Cross-reference and root-cause every gap: for every ground-truth item not appearing in the Step 3 result, check whether it appeared in the fetch-stage log (Step 2) — if yes, it was dropped downstream (parse/classify/dedup — narrow it down using the intermediate node logs in `ca-nodes/nodes/`); if no, it's a fetch-stage miss (pagination, blocking, selector). For every notice present with `is_relevant=true` that doesn't obviously match the keyword list in Global Constraints, read its `description` and check whether a keyword genuinely matches (even loosely) — if not, it's a classify false positive.
- [ ] **Step 5:** Fill in `### Ville de Montréal`, commit with message `docs(audit): Ville de Montréal source findings`.

---

### Task 10: Audit source — Le Devoir (CA, id 15, ledevoir)

Same structure as Task 2, targeting `### Le Devoir`, consuming the CA snapshot from Task 7.

- [ ] **Step 1:** Ground truth from `https://www.ledevoir.com/services-et-annonces/avis-publics`. This is a general public-notices page, not procurement-specific — note in the report how many of the currently-listed notices are even tender-shaped, as context for interpreting precision here.
- [ ] **Step 2:** `grep -i "devoir" -A5 .../ca-nodes/nodes/fetch_listings.json`. `parser_type` is the bespoke `ledevoir` branch — check `src/tenderai/agents/nodes/fetch_ledevoir.py` if the log shows unexpected item shapes.
- [ ] **Step 3:** Query the persisted/classified result:

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=15 ORDER BY n.created_at DESC LIMIT 50;\""
```

- [ ] **Step 4:** Cross-reference and root-cause every gap: for every ground-truth item not appearing in the Step 3 result, check whether it appeared in the fetch-stage log (Step 2) — if yes, it was dropped downstream (parse/classify/dedup — narrow it down using the intermediate node logs in `ca-nodes/nodes/`); if no, it's a fetch-stage miss (pagination, blocking, selector). For every notice present with `is_relevant=true` that doesn't obviously match the keyword list in Global Constraints, read its `description` and check whether a keyword genuinely matches (even loosely) — if not, it's a classify false positive.
- [ ] **Step 5:** Fill in `### Le Devoir`, commit with message `docs(audit): Le Devoir source findings`.

---

### Task 11: Audit source — Nova Scotia (CA, id 16, playwright)

Same structure as Task 2, targeting `### Nova Scotia`, consuming the CA snapshot from Task 7.

- [ ] **Step 1:** Ground truth from `https://procurement-portal.novascotia.ca/tenders`.
- [ ] **Step 2:** `grep -i "nova scotia" -A5 .../ca-nodes/nodes/fetch_listings.json`.
- [ ] **Step 3:** Query the persisted/classified result:

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=16 ORDER BY n.created_at DESC LIMIT 50;\""
```

- [ ] **Step 4:** Cross-reference and root-cause every gap: for every ground-truth item not appearing in the Step 3 result, check whether it appeared in the fetch-stage log (Step 2) — if yes, it was dropped downstream (parse/classify/dedup — narrow it down using the intermediate node logs in `ca-nodes/nodes/`); if no, it's a fetch-stage miss (pagination, blocking, selector). For every notice present with `is_relevant=true` that doesn't obviously match the keyword list in Global Constraints, read its `description` and check whether a keyword genuinely matches (even loosely) — if not, it's a classify false positive.
- [ ] **Step 5:** Fill in `### Nova Scotia`, commit with message `docs(audit): Nova Scotia source findings`.

---

### Task 12: Audit source — UNDP (CA, id 17, tavily_extract)

Same structure as Task 2, targeting `### UNDP`, consuming the CA snapshot from Task 7.

- [ ] **Step 1:** Ground truth from `https://procurement-notices.undp.org/index.cfm`.
- [ ] **Step 2:** `grep -i "undp" -A5 .../ca-nodes/nodes/fetch_listings.json`. `parser_type` is `tavily_extract` — this goes through the Tavily API rather than direct scraping; check the log for Tavily-specific errors (rate limit, extraction quality) rather than anti-bot signs. Note: this source and "UNDP Africa" (id 22, disabled) are distinct rows — don't conflate them.
- [ ] **Step 3:** Query the persisted/classified result:

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=17 ORDER BY n.created_at DESC LIMIT 50;\""
```

- [ ] **Step 4:** Cross-reference and root-cause every gap: for every ground-truth item not appearing in the Step 3 result, check whether it appeared in the fetch-stage log (Step 2) — if yes, it was dropped downstream (parse/classify/dedup — narrow it down using the intermediate node logs in `ca-nodes/nodes/`); if no, it's a fetch-stage miss (pagination, blocking, selector). For every notice present with `is_relevant=true` that doesn't obviously match the keyword list in Global Constraints, read its `description` and check whether a keyword genuinely matches (even loosely) — if not, it's a classify false positive.
- [ ] **Step 5:** Fill in `### UNDP`, commit with message `docs(audit): UNDP source findings`.

---

### Task 13: Audit source — The Commonwealth (CA, id 20, tavily_extract)

Same structure as Task 2, targeting `### The Commonwealth`, consuming the CA snapshot from Task 7.

- [ ] **Step 1:** Ground truth from `https://tenders.thecommonwealth.org/aspx/Tenders/Appraisal`.
- [ ] **Step 2:** `grep -i "commonwealth" -A5 .../ca-nodes/nodes/fetch_listings.json`.
- [ ] **Step 3:** Query the persisted/classified result:

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=20 ORDER BY n.created_at DESC LIMIT 50;\""
```

- [ ] **Step 4:** Cross-reference and root-cause every gap: for every ground-truth item not appearing in the Step 3 result, check whether it appeared in the fetch-stage log (Step 2) — if yes, it was dropped downstream (parse/classify/dedup — narrow it down using the intermediate node logs in `ca-nodes/nodes/`); if no, it's a fetch-stage miss (pagination, blocking, selector). For every notice present with `is_relevant=true` that doesn't obviously match the keyword list in Global Constraints, read its `description` and check whether a keyword genuinely matches (even loosely) — if not, it's a classify false positive.
- [ ] **Step 5:** Fill in `### The Commonwealth`, commit with message `docs(audit): The Commonwealth source findings`.

---

### Task 14: Audit source — Palladium Group (CA, id 25, tavily_extract)

Same structure as Task 2, targeting `### Palladium Group`, consuming the CA snapshot from Task 7.

- [ ] **Step 1:** Ground truth from `https://thepalladiumgroup.com/tenders`.
- [ ] **Step 2:** `grep -i "palladium" -A5 .../ca-nodes/nodes/fetch_listings.json`.
- [ ] **Step 3:** Query the persisted/classified result:

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=25 ORDER BY n.created_at DESC LIMIT 50;\""
```

- [ ] **Step 4:** Cross-reference and root-cause every gap: for every ground-truth item not appearing in the Step 3 result, check whether it appeared in the fetch-stage log (Step 2) — if yes, it was dropped downstream (parse/classify/dedup — narrow it down using the intermediate node logs in `ca-nodes/nodes/`); if no, it's a fetch-stage miss (pagination, blocking, selector). For every notice present with `is_relevant=true` that doesn't obviously match the keyword list in Global Constraints, read its `description` and check whether a keyword genuinely matches (even loosely) — if not, it's a classify false positive.
- [ ] **Step 5:** Fill in `### Palladium Group`, commit with message `docs(audit): Palladium Group source findings`.

---

### Task 15: Light pass — the 9 disabled CA sources

**Files:**
- Modify: `docs/audits/2026-09-01-pipeline-quality-audit-report.md` (only the `### Sources désactivées` subsection)

**Interfaces:**
- Consumes: nothing from other tasks (no run is triggered for disabled sources — a disabled source never runs, so there's nothing to trace).

For each of the 9 sources below, no live pipeline trace is done (deliberately — see spec §3). For each: (a) confirm `enabled=false` and check the `patterns`/config column for any note explaining why, (b) do a quick manual check that the `list_url` still resolves and roughly what it shows today (Chrome, 1-2 minutes per source — just confirm the page loads and looks like a live tender listing, not a dead/redirected URL), (c) judge whether disabling still looks justified or is itself a coverage gap worth flagging.

| id | name | list_url |
|---|---|---|
| 18 | Bonfire Hub Canada | https://cmn-mcn.bonfirehub.ca/portal/?tab=openOpportunities |
| 19 | Public Procurement Belgium | https://www.publicprocurement.be/fr/announcement-search?cpv=72000000 |
| 21 | Guinea Tenders | https://www.guineatenders.com/it-services-consulting-software-development-internet-and-support-tenders-9.php |
| 22 | UNDP Africa | https://www.undp.org/africa/procurement |
| 23 | World Bank | https://wbgeprocure-rfxnow.worldbank.org/rfxnow/public/advertisement/index.html |
| 24 | NATO NSPA | https://eportal.nspa.nato.int/eProcurement5G/Opportunities/OpportunitiesList?PreFilter=FBO |
| 26 | BAD (Banque Africaine de Développement) | https://www.afdb.org/en/projects-and-operations/procurement |
| 27 | OMD / WCO | https://www.wcoomd.org/en/about-us/calls_for_tenders.aspx |
| 28 | AFD - DGMarket | https://afd.dgmarket.com/tenders/brandedNoticeList.do |

- [ ] **Step 1: Pull each source's full config**

```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT id, name, enabled, rate_limit, patterns, updated_at FROM sources WHERE id IN (18,19,21,22,23,24,26,27,28) ORDER BY id;\""
```

- [ ] **Step 2: Spot-check each `list_url` live**

For each of the 9, open the URL in Chrome, note in one line whether it still resolves to a real, current tender listing, a dead page, a redirect, or a login wall.

- [ ] **Step 3: Write the findings and commit**

Fill in `### Sources désactivées` with a table: `| Source | Raison de désactivation (si trouvée) | URL toujours valide ? | Verdict (désactivation justifiée / gap de couverture) |`.

```bash
cd /home/yulcom/web/tender-ai
git add docs/audits/2026-09-01-pipeline-quality-audit-report.md
git commit -m "docs(audit): disabled CA sources light pass

Claude-Session: https://claude.ai/code/session_01HibCiDKyx7nhNxhSERgGtQ"
```

---

### Task 16: Synthesis

**Files:**
- Modify: `docs/audits/2026-09-01-pipeline-quality-audit-report.md` (only the `## Sommaire exécutif` section)

**Interfaces:**
- Consumes: every section written by Tasks 2-15 (must run after all of them).

- [ ] **Step 1: Read every source section**

Read the full report file as written by Tasks 2-15.

- [ ] **Step 2: Write the executive summary**

Fill in `## Sommaire exécutif` with: (a) an overall recall/precision verdict per country (is the system actually missing relevant tenders? how often? is it surfacing irrelevant ones? how often?), (b) a table of every finding ranked by severity/impact, with its root-cause category and bug/architectural/technology label, (c) an explicit call-out of which findings, if any, support proceeding with the Scrapling spike (and on which specific sources), and which are unrelated to scraping technology entirely, (d) a short "if I could only fix 3 things" list — not fixed here, just named, for the user's later prioritization.

- [ ] **Step 3: Commit**

```bash
cd /home/yulcom/web/tender-ai
git add docs/audits/2026-09-01-pipeline-quality-audit-report.md
git commit -m "docs(audit): chantier 4 executive summary

Claude-Session: https://claude.ai/code/session_01HibCiDKyx7nhNxhSERgGtQ"
```

---

### Task 17: Doc cleanup and PROJECT_STATUS update

**Files:**
- Modify: `/home/yulcom/web/tenderai/CLAUDE.md:7`
- Modify: `/home/yulcom/web/tender-ai/CLAUDE.md:7`
- Modify: `/home/yulcom/web/tender-ai/docs/PROJECT_STATUS.md` (chantier 4 row/section)

- [ ] **Step 1: Fix `/home/yulcom/web/tenderai/CLAUDE.md`**

Change line 7 from:
```
TenderAI is a multi-agent RFP/tender harvester for Burkina Faso (multi-company/multi-tenant capable). It autonomously scrapes procurement portals, classifies opportunities using AI, deduplicates them, generates French-language DOCX reports, and delivers them via email. Stack: Python 3.11+, LangGraph, FastAPI, Next.js (React frontend), PostgreSQL, MinIO, APScheduler.
```
to:
```
TenderAI is a multi-agent RFP/tender harvester, multi-company/multi-tenant and multi-country. It autonomously scrapes procurement portals, classifies opportunities using AI, deduplicates them, generates French-language DOCX reports, and delivers them via email. Stack: Python 3.11+, LangGraph, FastAPI, Next.js (React frontend), PostgreSQL, MinIO, APScheduler.
```

This directory is not a git repo — just save the file directly, no commit for this one.

- [ ] **Step 2: Fix `/home/yulcom/web/tender-ai/CLAUDE.md`**

Change line 7 from:
```
TenderAI is a multi-agent RFP/tender harvester for Burkina Faso. It autonomously scrapes procurement portals, classifies opportunities using AI, deduplicates them, generates French-language DOCX reports, and delivers them via email. Stack: Python 3.11+, LangGraph, FastAPI, Next.js (React frontend), PostgreSQL, MinIO, APScheduler.
```
to:
```
TenderAI is a multi-agent RFP/tender harvester, multi-company/multi-tenant and multi-country. It autonomously scrapes procurement portals, classifies opportunities using AI, deduplicates them, generates French-language DOCX reports, and delivers them via email. Stack: Python 3.11+, LangGraph, FastAPI, Next.js (React frontend), PostgreSQL, MinIO, APScheduler.
```

- [ ] **Step 3: Update `docs/PROJECT_STATUS.md`**

Update the chantier 4 row (`| 4 | Audit qualité des pipelines | ⬜ Pas commencé | À faire sur \`tenderai-backend\` |`) to reflect completion, and replace the `### Chantier 4 — Audit qualité des pipelines` section body (currently "Pas commencé. Aucun spec/plan écrit à ce jour.") with a short summary pointing at the spec (`docs/superpowers/specs/2026-09-01-pipeline-quality-audit-design.md`), the plan (`docs/superpowers/plans/2026-09-01-pipeline-quality-audit.md`), and the report (`docs/audits/2026-09-01-pipeline-quality-audit-report.md`), plus a one-line pointer to the executive summary's headline finding. Note explicitly that fixes are a separate, not-yet-started follow-up gated on user review.

- [ ] **Step 4: Commit**

```bash
cd /home/yulcom/web/tender-ai
git add CLAUDE.md docs/PROJECT_STATUS.md
git commit -m "docs: close chantier 4 diagnostic phase, fix BF-centric framing in CLAUDE.md

Claude-Session: https://claude.ai/code/session_01HibCiDKyx7nhNxhSERgGtQ"
```

(The `/home/yulcom/web/tenderai/CLAUDE.md` edit from Step 1 is not committed here — that directory isn't a git repo.)
