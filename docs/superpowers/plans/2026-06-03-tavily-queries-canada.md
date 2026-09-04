# Tavily Queries Canada — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch the Canada source from `tavily_extract` to `tavily_search` with targeted IT/procurement queries, and expose a queries editor in the source form UI.

**Architecture:** Backend already supports `patterns: dict | None` on the `Source` model. `fetch_tavily_search` reads `source["patterns"]["queries"]` at runtime. The frontend form dialog needs a conditional textarea (shown only for `tavily_search`) that maps to `patterns.queries` on save/load.

**Tech Stack:** FastAPI (PUT `/api/v1/sources/7`), Next.js / React (`source-form-dialog.tsx`), Playwright for verification.

---

### Task 1: Configure Canada source via API

**Files:**
- No code change — one-shot API call

- [ ] **Step 1: PUT source 7 to switch parser and set queries**

```bash
TOKEN=$(curl -s -X POST "http://localhost:8000/api/v1/admin/login" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=NKZwElFt9DR6yShC" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -s -X PUT "http://localhost:8000/api/v1/sources/7" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "parser_type": "tavily_search",
    "patterns": {
      "queries": [
        "appel offres informatique technologies information site:achatscanada.canada.ca",
        "marché public TI génie logiciel Canada gouvernement fédéral",
        "IT services contract procurement Canada federal government buyandsell",
        "technology software engineering tender Canada achatscanada"
      ]
    }
  }' | python3 -m json.tool
```

Expected: JSON response with `"parser_type": "tavily_search"` and `"patterns": {"queries": [...]}`.

- [ ] **Step 2: Verify via GET**

```bash
curl -s "http://localhost:8000/api/v1/sources/7" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json; s=json.load(sys.stdin); print(s['parser_type'], s['patterns'])"
```

Expected: `tavily_search {'queries': ['appel offres informatique...', ...]}`

- [ ] **Step 3: Commit**

```bash
git add -p   # nothing to stage — no code changed
```

No commit needed for this task (API-only data change).

---

### Task 2: Add queries textarea to source form dialog

**Files:**
- Modify: `frontend/components/sources/source-form-dialog.tsx`

- [ ] **Step 1: Extend the form state and empty defaults**

In `source-form-dialog.tsx`, change the `empty` constant and `form` state to include `queries`:

```tsx
const empty = {
  name: "",
  base_url: "",
  list_url: "",
  parser_type: "html",
  rate_limit: "10/m",
  enabled: true,
  queries: "",          // newline-separated, for tavily_search only
};
```

- [ ] **Step 2: Populate queries when editing an existing source**

In the `useEffect` that populates the form for edit mode, add the `queries` field:

```tsx
useEffect(() => {
  if (open) {
    setForm(
      source
        ? {
            name: source.name,
            base_url: source.base_url,
            list_url: source.list_url,
            parser_type: source.parser_type,
            rate_limit: source.rate_limit,
            enabled: source.enabled,
            queries:
              (source.patterns?.queries as string[] | undefined)
                ?.join("\n") ?? "",
          }
        : { ...empty }
    );
    setError("");
  }
}, [open, source]);
```

Note: `source.patterns` is typed as `Record<string, unknown> | null | undefined` in `SourceOut`. Cast with `as string[]`.

- [ ] **Step 3: Include patterns in the submit payload**

Replace the existing `handleSubmit` payload construction:

```tsx
const payload = isEdit
  ? {
      ...form,
      patterns:
        form.parser_type === "tavily_search"
          ? { queries: form.queries.split("\n").map((q) => q.trim()).filter(Boolean) }
          : undefined,
    }
  : {
      ...form,
      ...(countryId !== undefined ? { country_id: countryId } : {}),
      patterns:
        form.parser_type === "tavily_search"
          ? { queries: form.queries.split("\n").map((q) => q.trim()).filter(Boolean) }
          : undefined,
    };
```

Remove `queries` from the raw spread so it doesn't go to the API as a top-level field:

```tsx
const { queries, ...formWithoutQueries } = form;
const payload = isEdit
  ? {
      ...formWithoutQueries,
      patterns:
        form.parser_type === "tavily_search"
          ? { queries: queries.split("\n").map((q) => q.trim()).filter(Boolean) }
          : undefined,
    }
  : {
      ...formWithoutQueries,
      ...(countryId !== undefined ? { country_id: countryId } : {}),
      patterns:
        form.parser_type === "tavily_search"
          ? { queries: queries.split("\n").map((q) => q.trim()).filter(Boolean) }
          : undefined,
    };
```

- [ ] **Step 4: Add the conditional textarea to the JSX**

After the rate limit / parser grid block and before the enabled checkbox, add:

```tsx
{form.parser_type === "tavily_search" && (
  <div className="space-y-2">
    <Label htmlFor="src-queries">
      Requêtes de recherche
      <span className="ml-1 text-xs text-slate-500 font-normal">
        (une par ligne)
      </span>
    </Label>
    <textarea
      id="src-queries"
      value={form.queries}
      onChange={(e) => set("queries", e.target.value)}
      rows={4}
      placeholder={"appel offres informatique site:achatscanada.canada.ca\nIT tender procurement Canada federal"}
      className="w-full border border-input rounded-md px-3 py-2 text-sm bg-background resize-y min-h-[96px]"
    />
  </div>
)}
```

- [ ] **Step 5: Commit**

```bash
git add frontend/components/sources/source-form-dialog.tsx
git commit -m "feat(ui): add Tavily queries editor to source form (shown for tavily_search)"
```

---

### Task 3: Verify end-to-end via Playwright + pipeline run

**Files:**
- No code change — verification only

- [ ] **Step 1: Run the verification script**

```bash
cat > /tmp/verify_tavily.py << 'EOF'
import asyncio
from playwright.async_api import async_playwright

SS = "/tmp/screenshots"

async def do_login(page):
    await page.goto("http://localhost:3000/login")
    await page.wait_for_selector('#username', timeout=10000)
    await page.locator('#username').fill("admin")
    await page.locator('#password').fill("NKZwElFt9DR6yShC")
    await page.locator('button[type="submit"]').click()
    await page.wait_for_url(lambda url: "login" not in url, timeout=15000)
    await asyncio.sleep(1)

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True, args=["--no-sandbox"])
        page = await browser.new_page(viewport={"width": 1400, "height": 900})
        await do_login(page)

        # Go to sources, select Canada, click Modifier on Achats Canada
        await page.goto("http://localhost:3000/sources")
        await page.wait_for_load_state("networkidle")
        await asyncio.sleep(1)
        await page.locator('[aria-label="Sélectionner un pays"]').select_option(label="Canada")
        await asyncio.sleep(1)
        await page.locator("button:has-text('Modifier')").first.click()
        await asyncio.sleep(1)
        await page.screenshot(path=f"{SS}/verify_01_edit_dialog.png")
        print("[01] Edit dialog for Achats Canada")

        # Check queries textarea is visible and has content
        textarea = page.locator('#src-queries')
        visible = await textarea.count() > 0 and await textarea.is_visible()
        value = await textarea.input_value() if visible else ""
        print(f"  Textarea visible: {visible}")
        print(f"  Queries content:\n{value}")

        # Dashboard: select Canada and run pipeline
        await page.goto("http://localhost:3000/")
        await page.wait_for_load_state("networkidle")
        await asyncio.sleep(1)
        await page.locator('[aria-label="Sélectionner un pays"]').select_option(label="Canada")
        await asyncio.sleep(1)
        await page.locator("button:has-text('Lancer maintenant')").click()
        await asyncio.sleep(3)
        await page.screenshot(path=f"{SS}/verify_02_run_started.png", full_page=True)
        print("[02] Pipeline started for Canada")

        # Wait for completion
        for i in range(20):
            await asyncio.sleep(5)
            await page.reload()
            await page.wait_for_load_state("networkidle")
            body = await page.inner_text("body")
            if "running" not in body[body.find("Runs récents"):]:
                print(f"  Completed after {(i+1)*5}s")
                break

        await page.screenshot(path=f"{SS}/verify_03_completed.png", full_page=True)
        body = await page.inner_text("body")
        idx = body.find("Runs récents")
        print(f"[03] Final run status:\n{body[idx:idx+400]}")
        await browser.close()

asyncio.run(main())
EOF
python3 /tmp/verify_tavily.py
```

Expected:
- `[01]`: Edit dialog shows textarea with 4 queries pre-filled
- `[03]`: Run completes with `items_fetched > 0`

- [ ] **Step 2: Check pipeline logs for relevant items**

```bash
docker logs tenderai-api 2>&1 | grep -E "tavily_search|queries|relevant_items" | tail -20
```

Expected: lines like `Tavily search query completed` and `relevant_items=N` (N ≥ 0).
