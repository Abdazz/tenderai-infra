# Multi-Company Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `tenderai-frontend` into the multi-company backend that chantier 5's sub-project A already shipped: rename stale `admin`/`viewer` role literals to `company_admin`/`company_viewer`, add a `CompanyContext` above the existing `CountryContext`, add a `/companies` management page (super_admin only), and thread `company_id` scoping through the Sources, Settings/Destinataires, Utilisateurs, and Reports pages.

**Architecture:** `CompanyProvider` wraps `CountryProvider` in `app/(dashboard)/layout.tsx`, both decoding claims straight from the JWT cookie (no `/me` round-trip). `CountryProvider` changes from fetching the global country catalog to fetching only the selected company's subscribed countries. A new `app/api/proxy/companies/` route family mirrors the existing `app/api/proxy/countries/` family exactly. Every other page reads `useCompany()`/`useCountry()` and threads `company_id`/`country_id` into its existing fetches, following the same query-param/URL-branch patterns those pages already use for `country_id`.

**Tech Stack:** Next.js (App Router), React, TypeScript, `jose` (JWT decode). No test runner exists in this repo — verification is `npm run build` (TypeScript compile) + `npm run lint` (`next lint`) + manual browser walkthrough under `super_admin`/`company_admin`/`company_viewer`.

**Spec:** `docs/superpowers/specs/2026-08-29-multi-company-frontend-design.md`

## Global Constraints

- **Role literals**: `"admin"` → `"company_admin"`, `"viewer"` → `"company_viewer"` everywhere. `"super_admin"` is unchanged. This must land in Task 1 before any other task, since every later task writes new code against the new literals.
- **No test runner in this repo.** `package.json` only defines `dev`/`build`/`start`/`lint`. Every task's verification step is: `npm run build` (from `/home/yulcom/web/tenderai/tenderai-frontend`) succeeds with no new TypeScript errors, `npm run lint` is clean, and a manual browser check of the specific page(s) touched. Do not invent a test framework or write `.test.ts` files — that is out of scope for this plan.
- **Deploy together, not now.** Do not trigger any `tenderai-infra` deploy or push to `staging` mid-plan expecting it to go live — per the user's explicit sequencing decision, the new backend (already merged to `tenderai-backend/staging`) and this frontend work deploy to the staging server together, only after this entire plan is implemented and reviewed. Pushing commits to `tenderai-frontend/staging` (git) is fine and expected per task; triggering `tenderai-infra`'s `deploy.yml` is not part of this plan.
- **`CompanyProvider` wraps `CountryProvider`**, never the reverse — `CountryProvider` depends on `useCompany()` internally (Task 2), so the nesting order is structural, not a style choice.
- **Fail closed, never silently reassign.** If a `company_admin`/`company_viewer`'s JWT `company_id` doesn't resolve to any company the API returns, `selectedCompany` stays `null` — never fall back to a different company. Same principle already used by `CountryProvider` today.
- **`/companies` page and its proxy routes are `super_admin`-only** in the same (implicit, link-visibility + backend-rejects-writes) style already used for `/countries` — no new authorization layer to invent.
- Local repo: `/home/yulcom/web/tenderai/tenderai-frontend`, already on branch `staging`. Confirm `git status`/`git branch --show-current` before each task's first edit.
- Every push to `staging` is a real action against the live repo (though not yet deployed) — confirm with the user before pushing each task's commit, per this project's established practice this session.

---

### Task 1: Role-literal rename (`admin`/`viewer` → `company_admin`/`company_viewer`)

**Files:**
- Modify: `lib/api.ts:32,40` (`LoginResponse.role`, `UserOut.role` types)
- Modify: `contexts/country-context.tsx:17,28` (`CountryContextValue.role`/`CountryProviderProps.role` types, default context value)
- Modify: `components/sidebar.tsx:26` (`SidebarProps.role` type)
- Modify: `app/(dashboard)/layout.tsx:13` (decoded JWT payload type)
- Modify: `components/users/create-user-dialog.tsx:31,48-49,70,120-121` (state type, validation message, reset value, `<option>` values/labels)
- Modify: `app/(dashboard)/users/page.tsx:13,108-109` (`User.role` type, badge variant logic)

**Interfaces:**
- Produces: every file in this repo that types a `role` field now uses `"super_admin" | "company_admin" | "company_viewer"`. Every later task's new code should be written against these literals directly — this task is why they're safe to use.

- [ ] **Step 1: Update `lib/api.ts`**

Change:
```typescript
export interface LoginResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  role: "admin" | "viewer";
  password_reset_required: boolean;
}
```
to:
```typescript
export interface LoginResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  role: "super_admin" | "company_admin" | "company_viewer";
  password_reset_required: boolean;
}
```
and:
```typescript
export interface UserOut {
  id: string;
  username: string;
  email: string;
  role: "admin" | "viewer";
  is_active: boolean;
  password_reset_required: boolean;
}
```
to:
```typescript
export interface UserOut {
  id: string;
  username: string;
  email: string;
  role: "super_admin" | "company_admin" | "company_viewer";
  is_active: boolean;
  password_reset_required: boolean;
}
```

- [ ] **Step 2: Update `contexts/country-context.tsx`**

Change:
```typescript
type CountryContextValue = {
  countries: Country[];
  selectedCountry: Country | null;
  setSelectedCountry: (c: Country) => void;
  loading: boolean;
  isSuperAdmin: boolean;
  role: "super_admin" | "admin" | "viewer";
};

const CountryContext = createContext<CountryContextValue>({
  countries: [],
  selectedCountry: null,
  setSelectedCountry: () => {},
  loading: true,
  isSuperAdmin: false,
  role: "viewer",
});
```
to:
```typescript
type CountryContextValue = {
  countries: Country[];
  selectedCountry: Country | null;
  setSelectedCountry: (c: Country) => void;
  loading: boolean;
  isSuperAdmin: boolean;
  role: "super_admin" | "company_admin" | "company_viewer";
};

const CountryContext = createContext<CountryContextValue>({
  countries: [],
  selectedCountry: null,
  setSelectedCountry: () => {},
  loading: true,
  isSuperAdmin: false,
  role: "company_viewer",
});
```
and update `CountryProviderProps.role` the same way:
```typescript
interface CountryProviderProps {
  children: ReactNode;
  fixedCountryId?: number | null;
  isSuperAdmin: boolean;
  role: "super_admin" | "company_admin" | "company_viewer";
}
```

- [ ] **Step 3: Update `components/sidebar.tsx`**

Change:
```typescript
interface SidebarProps {
  role: "super_admin" | "admin" | "viewer";
  username: string;
}
```
to:
```typescript
interface SidebarProps {
  role: "super_admin" | "company_admin" | "company_viewer";
  username: string;
}
```
(the existing `role === "super_admin"` logic elsewhere in this file needs no change.)

- [ ] **Step 4: Update `app/(dashboard)/layout.tsx`**

Change:
```typescript
let payload: { sub: string; role: "super_admin" | "admin" | "viewer"; country_id?: number | null };
```
to:
```typescript
let payload: { sub: string; role: "super_admin" | "company_admin" | "company_viewer"; country_id?: number | null };
```

- [ ] **Step 5: Update `components/users/create-user-dialog.tsx`**

Change the state type and default:
```typescript
const [role, setRole] = useState<"super_admin" | "admin" | "viewer">("viewer");
```
to:
```typescript
const [role, setRole] = useState<"super_admin" | "company_admin" | "company_viewer">("company_viewer");
```

Change the validation message:
```typescript
setError("Un pays est requis pour les rôles admin et viewer.");
```
to:
```typescript
setError("Un pays est requis pour les rôles company_admin et company_viewer.");
```

Change the reset-on-submit-success value:
```typescript
setRole("viewer");
```
to:
```typescript
setRole("company_viewer");
```

Change the `<select>` options:
```tsx
<option value="viewer">Viewer</option>
<option value="admin">Admin</option>
<option value="super_admin">Super Admin</option>
```
to:
```tsx
<option value="company_viewer">Company Viewer</option>
<option value="company_admin">Company Admin</option>
<option value="super_admin">Super Admin</option>
```

- [ ] **Step 6: Update `app/(dashboard)/users/page.tsx`**

Change:
```typescript
interface User {
  id: string;
  username: string;
  email: string;
  role: "super_admin" | "admin" | "viewer";
  is_active: boolean;
  password_reset_required: boolean;
  country_id: number | null;
}
```
to:
```typescript
interface User {
  id: string;
  username: string;
  email: string;
  role: "super_admin" | "company_admin" | "company_viewer";
  is_active: boolean;
  password_reset_required: boolean;
  country_id: number | null;
}
```

Change the badge variant logic:
```tsx
<Badge variant={user.role === "super_admin" ? "default" : user.role === "admin" ? "secondary" : "outline"}>
```
to:
```tsx
<Badge variant={user.role === "super_admin" ? "default" : user.role === "company_admin" ? "secondary" : "outline"}>
```

- [ ] **Step 7: Verify**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
npm run build
npm run lint
```
Expected: both succeed, no new errors. `grep -rn '"admin"\|'"'"'admin'"'"'' app components contexts lib --include="*.tsx" --include="*.ts" | grep -v "super_admin\|company_admin"` returns nothing (confirms no stray old-literal survives).

- [ ] **Step 8: Confirm with the user, then commit and push**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
git add lib/api.ts contexts/country-context.tsx components/sidebar.tsx "app/(dashboard)/layout.tsx" components/users/create-user-dialog.tsx "app/(dashboard)/users/page.tsx"
git commit -m "$(cat <<'EOF'
chore: rename admin/viewer role literals to company_admin/company_viewer

Matches the role rename already merged on the backend
(tenderai-backend/staging). Without this, the "Nouvel utilisateur"
dialog submits role values the backend now rejects (400), and every
role-typed field in this repo is stale. Part of chantier 5 sous-projet
B — see docs/superpowers/specs/2026-08-29-multi-company-frontend-design.md
in the monorepo.
EOF
)"
```
Ask the user for explicit confirmation before pushing. On yes: `git push origin staging`.

---

### Task 2: `CompanyContext` + layout wiring + `CountryProvider` re-scoping

**Files:**
- Create: `contexts/company-context.tsx`
- Modify: `contexts/country-context.tsx` (fetch URL changes to depend on selected company)
- Modify: `app/(dashboard)/layout.tsx` (decode `company_id`, wrap with `CompanyProvider`)

**Interfaces:**
- Consumes: Task 1's role-literal types.
- Produces: `useCompany()` hook returning `{ companies: Company[], selectedCompany: Company | null, setSelectedCompany: (c: Company) => void, loading: boolean, isSuperAdmin: boolean }`, importable as `import { useCompany } from "@/contexts/company-context"`. `Company` type: `{ id: number; name: string; slug: string; active: boolean; logo_url: string | null; subject_prefix: string | null; signature: string | null }`. Later tasks (3-8) that need the selected company read `useCompany().selectedCompany?.id`.

- [ ] **Step 1: Write `contexts/company-context.tsx`**

```tsx
"use client";

import { createContext, useContext, useState, useEffect, ReactNode } from "react";

export type Company = {
  id: number;
  name: string;
  slug: string;
  active: boolean;
  logo_url: string | null;
  subject_prefix: string | null;
  signature: string | null;
};

type CompanyContextValue = {
  companies: Company[];
  selectedCompany: Company | null;
  setSelectedCompany: (c: Company) => void;
  loading: boolean;
  isSuperAdmin: boolean;
};

const CompanyContext = createContext<CompanyContextValue>({
  companies: [],
  selectedCompany: null,
  setSelectedCompany: () => {},
  loading: true,
  isSuperAdmin: false,
});

interface CompanyProviderProps {
  children: ReactNode;
  /** For non-super_admin: the company_id from JWT. When set, selection is locked. */
  fixedCompanyId?: number | null;
  isSuperAdmin: boolean;
}

export function CompanyProvider({ children, fixedCompanyId, isSuperAdmin }: CompanyProviderProps) {
  const [companies, setCompanies] = useState<Company[]>([]);
  const [selectedCompany, setSelectedCompanyState] = useState<Company | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch("/api/proxy/companies")
      .then((r) => r.json())
      .then((data: Company[]) => {
        const active = Array.isArray(data) ? data.filter((c) => c.active) : [];
        setCompanies(active);

        if (fixedCompanyId) {
          // Non-super_admin: lock to their assigned company. Fail closed —
          // if the JWT's company_id doesn't resolve, selectedCompany stays
          // null rather than silently falling back to another company.
          const found = active.find((c) => c.id === fixedCompanyId) ?? null;
          setSelectedCompanyState(found);
        } else {
          // super_admin: restore from localStorage or pick first
          const storedId = typeof window !== "undefined"
            ? Number(localStorage.getItem("selectedCompanyId"))
            : 0;
          const found = active.find((c) => c.id === storedId) ?? active[0] ?? null;
          setSelectedCompanyState(found);
        }
      })
      .catch(() => setCompanies([]))
      .finally(() => setLoading(false));
  }, [fixedCompanyId]);

  function setSelectedCompany(c: Company) {
    if (fixedCompanyId) return; // locked for non-super_admin
    setSelectedCompanyState(c);
    if (typeof window !== "undefined") {
      localStorage.setItem("selectedCompanyId", String(c.id));
    }
  }

  return (
    <CompanyContext.Provider value={{ companies, selectedCompany, setSelectedCompany, loading, isSuperAdmin }}>
      {children}
    </CompanyContext.Provider>
  );
}

export const useCompany = () => useContext(CompanyContext);
```

This is a direct structural mirror of `contexts/country-context.tsx` — same fetch/localStorage/fail-closed pattern, one level up.

- [ ] **Step 2: Re-scope `CountryProvider`'s fetch to the selected company's subscriptions**

In `contexts/country-context.tsx`, add the import:
```typescript
import { useCompany } from "@/contexts/company-context";
```

Change the `useEffect` that fetches countries. Current:
```typescript
useEffect(() => {
    fetch("/api/proxy/countries")
      .then((r) => r.json())
      .then((data: Country[]) => {
        const active = Array.isArray(data) ? data.filter((c) => c.active) : [];
        setCountries(active);

        if (fixedCountryId) {
          const found = active.find((c) => c.id === fixedCountryId) ?? null;
          setSelectedCountryState(found);
        } else {
          const storedId = typeof window !== "undefined"
            ? Number(localStorage.getItem("selectedCountryId"))
            : 0;
          const found = active.find((c) => c.id === storedId) ?? active[0] ?? null;
          setSelectedCountryState(found);
        }
      })
      .catch(() => setCountries([]))
      .finally(() => setLoading(false));
  }, [fixedCountryId]);
```

New version — must be inside the `CountryProvider` function body, where `const { selectedCompany, loading: companyLoading } = useCompany();` is added near the top alongside the existing `useState` calls:

```typescript
useEffect(() => {
    if (companyLoading) return;
    if (!selectedCompany) {
      setCountries([]);
      setSelectedCountryState(null);
      setLoading(false);
      return;
    }

    setLoading(true);
    fetch(`/api/proxy/companies/${selectedCompany.id}/countries`)
      .then((r) => r.json())
      .then((subs: { country_id: number; enabled: boolean }[]) => {
        // The subscription endpoint returns {country_id, enabled} pairs, not
        // full Country objects (see CompanyCountrySubscriptionRead on the
        // backend) — cross-reference against the full catalog to get
        // name/code/locale for display.
        const subscribedIds = new Set(
          (Array.isArray(subs) ? subs : []).filter((s) => s.enabled).map((s) => s.country_id)
        );
        fetch("/api/proxy/countries")
          .then((r) => r.json())
          .then((allCountries: Country[]) => {
            const active = (Array.isArray(allCountries) ? allCountries : [])
              .filter((c) => c.active && subscribedIds.has(c.id));
            setCountries(active);

            if (fixedCountryId) {
              const found = active.find((c) => c.id === fixedCountryId) ?? null;
              setSelectedCountryState(found);
            } else {
              const storedId = typeof window !== "undefined"
                ? Number(localStorage.getItem("selectedCountryId"))
                : 0;
              const found = active.find((c) => c.id === storedId) ?? active[0] ?? null;
              setSelectedCountryState(found);
            }
          })
          .catch(() => setCountries([]));
      })
      .catch(() => setCountries([]))
      .finally(() => setLoading(false));
  }, [fixedCountryId, selectedCompany?.id, companyLoading]);
```

Note: this makes two sequential fetches (subscriptions, then full catalog) rather than one — acceptable for this plan's scope; a combined backend endpoint would be a separate future optimization, not part of this task.

- [ ] **Step 3: Wire `CompanyProvider` into the layout**

In `app/(dashboard)/layout.tsx`, add the import:
```typescript
import { CompanyProvider } from "@/contexts/company-context";
```

Change the payload type:
```typescript
let payload: { sub: string; role: "super_admin" | "company_admin" | "company_viewer"; country_id?: number | null; company_id?: number | null };
```

Add after `const fixedCountryId = ...` line:
```typescript
const fixedCompanyId = isSuperAdmin ? null : (payload.company_id ?? null);
```

Change the return statement:
```tsx
return (
    <CompanyProvider isSuperAdmin={isSuperAdmin} fixedCompanyId={fixedCompanyId}>
      <CountryProvider isSuperAdmin={isSuperAdmin} fixedCountryId={fixedCountryId} role={payload.role}>
        <div className="flex min-h-screen">
          <Sidebar role={payload.role} username={payload.sub} />
          <main className="flex-1 p-6 bg-slate-50">{children}</main>
        </div>
      </CountryProvider>
    </CompanyProvider>
  );
```

- [ ] **Step 4: Verify**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
npm run build
npm run lint
```
Expected: both succeed. This task alone will show country-dependent pages (Sources, Settings) returning empty data in the browser, since `/api/proxy/companies` doesn't exist yet (Task 3) — that's expected and gets resolved once Task 3 lands. Do not attempt to manually verify end-to-end browser behavior until Task 3 is done; verifying `npm run build`/`npm run lint` pass is sufficient for this task.

- [ ] **Step 5: Confirm with the user, then commit and push**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
git add contexts/company-context.tsx contexts/country-context.tsx "app/(dashboard)/layout.tsx"
git commit -m "$(cat <<'EOF'
feat: add CompanyContext, nest CountryProvider inside it

CompanyProvider mirrors CountryProvider's fetch/localStorage/fail-closed
pattern one level up, decoding company_id from the JWT cookie exactly
like country_id already is. CountryProvider now fetches only the
selected company's subscribed countries instead of the full catalog.
Requires the companies proxy route family (next task) to be functional
end-to-end in the browser.
EOF
)"
```
Ask the user for explicit confirmation before pushing. On yes: `git push origin staging`.

---

### Task 3: `companies` proxy route family

**Files:**
- Create: `app/api/proxy/companies/route.ts`
- Create: `app/api/proxy/companies/[id]/route.ts`
- Create: `app/api/proxy/companies/[id]/countries/route.ts`
- Create: `app/api/proxy/companies/[id]/countries/[countryId]/route.ts`
- Create: `app/api/proxy/companies/[id]/settings/route.ts`
- Create: `app/api/proxy/companies/[id]/settings/[section]/route.ts`
- Create: `app/api/proxy/companies/[id]/run/route.ts`

**Interfaces:**
- Consumes: nothing from Tasks 1-2 directly (proxy routes are server-side, stateless).
- Produces: the full set of URLs Task 2's `CountryProvider` and every later task's `fetch("/api/proxy/companies/...")` call rely on. This task makes Task 2's end-to-end browser behavior actually work.

Every file in this task follows the exact same shape — `getToken()` from the `auth_token` cookie, 401 if absent, forward to `${API_URL}/api/v1/admin/companies/...` with the bearer token, pass through status and body verbatim. Copy this boilerplate exactly; do not deviate.

- [ ] **Step 1: `app/api/proxy/companies/route.ts`**

```typescript
import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function GET() {
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/companies`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}

export async function POST(request: NextRequest) {
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const body = await request.json();
  const res = await fetch(`${API_URL}/api/v1/admin/companies`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Step 2: `app/api/proxy/companies/[id]/route.ts`**

```typescript
import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/companies/${id}`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}

export async function PUT(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const body = await request.json();
  const res = await fetch(`${API_URL}/api/v1/admin/companies/${id}`, {
    method: "PUT",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}

export async function DELETE(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/companies/${id}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${token}` },
  });
  if (res.status === 204) return new NextResponse(null, { status: 204 });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Step 3: `app/api/proxy/companies/[id]/countries/route.ts`**

```typescript
import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/companies/${id}/countries`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}

export async function POST(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const body = await request.json();
  const res = await fetch(`${API_URL}/api/v1/admin/companies/${id}/countries`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Step 4: `app/api/proxy/companies/[id]/countries/[countryId]/route.ts`**

```typescript
import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function DELETE(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string; countryId: string }> }
) {
  const { id, countryId } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/companies/${id}/countries/${countryId}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${token}` },
  });
  if (res.status === 204) return new NextResponse(null, { status: 204 });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Step 5: `app/api/proxy/companies/[id]/settings/route.ts`**

```typescript
import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/companies/${id}/settings`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Step 6: `app/api/proxy/companies/[id]/settings/[section]/route.ts`**

```typescript
import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string; section: string }> }
) {
  const { id, section } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/companies/${id}/settings/${section}`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}

export async function PUT(
  request: NextRequest,
  { params }: { params: Promise<{ id: string; section: string }> }
) {
  const { id, section } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const body = await request.json();
  const res = await fetch(`${API_URL}/api/v1/admin/companies/${id}/settings/${section}`, {
    method: "PUT",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Step 7: `app/api/proxy/companies/[id]/run/route.ts`**

```typescript
import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function getToken(): Promise<string | null> {
  return (await cookies()).get("auth_token")?.value ?? null;
}

export async function POST(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const token = await getToken();
  if (!token) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const res = await fetch(`${API_URL}/api/v1/admin/companies/${id}/run`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
  });
  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
```

- [ ] **Step 8: Verify**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
npm run build
npm run lint
```
Expected: both succeed. Manual check: with `npm run dev` running locally against a real backend (or the deployed staging API via `NEXT_PUBLIC_API_URL`), log in as `super_admin`, open browser dev tools network tab, confirm `GET /api/proxy/companies` returns the company list (not a 404/500) and that Sources/Settings pages (which now depend on `CountryProvider`'s re-scoped fetch from Task 2) load real country data again.

- [ ] **Step 9: Confirm with the user, then commit and push**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
git add app/api/proxy/companies
git commit -m "$(cat <<'EOF'
feat: add companies proxy route family

Mirrors the existing countries proxy route family exactly — CRUD,
country-subscription management, settings, and delivery trigger.
Makes CompanyContext's fetch (previous task) actually resolve.
EOF
)"
```
Ask the user for explicit confirmation before pushing. On yes: `git push origin staging`.

---

### Task 4: `/companies` page + nav

**Files:**
- Create: `app/(dashboard)/companies/page.tsx`
- Create: `app/(dashboard)/companies/new/page.tsx`
- Modify: `components/sidebar.tsx` (add nav link)

**Interfaces:**
- Consumes: `app/api/proxy/companies/*` routes from Task 3.
- Produces: no new interface consumed by later tasks — this is a leaf page.

- [ ] **Step 1: Write `app/(dashboard)/companies/page.tsx`**

Structural mirror of `app/(dashboard)/countries/page.tsx`, extended with a country-subscription checklist section. The subscription list endpoint (`GET /api/proxy/companies/{id}/countries`) returns `{country_id, enabled}` pairs, not full `Country` objects (see Task 2 Step 2's note on `CompanyCountrySubscriptionRead`) — this page fetches the full country catalog separately to render names next to checkboxes.

```tsx
"use client";

import { useEffect, useState } from "react";
import Link from "next/link";

type Company = {
  id: number;
  name: string;
  slug: string;
  active: boolean;
};

type Country = { id: number; name: string; code: string };
type Subscription = { country_id: number; enabled: boolean };

export default function CompaniesPage() {
  const [companies, setCompanies] = useState<Company[]>([]);
  const [loading, setLoading] = useState(true);
  const [expandedId, setExpandedId] = useState<number | null>(null);
  const [allCountries, setAllCountries] = useState<Country[]>([]);
  const [subscriptions, setSubscriptions] = useState<Subscription[]>([]);

  useEffect(() => {
    fetch("/api/proxy/companies")
      .then((r) => r.json())
      .then((data) => setCompanies(Array.isArray(data) ? data : []))
      .finally(() => setLoading(false));
  }, []);

  async function toggleActive(company: Company) {
    await fetch(`/api/proxy/companies/${company.id}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ active: !company.active }),
    });
    setCompanies((prev) =>
      prev.map((c) => (c.id === company.id ? { ...c, active: !c.active } : c))
    );
  }

  async function expandSubscriptions(company: Company) {
    if (expandedId === company.id) {
      setExpandedId(null);
      return;
    }
    setExpandedId(company.id);
    const [countriesRes, subsRes] = await Promise.all([
      fetch("/api/proxy/countries"),
      fetch(`/api/proxy/companies/${company.id}/countries`),
    ]);
    setAllCountries(countriesRes.ok ? await countriesRes.json() : []);
    setSubscriptions(subsRes.ok ? await subsRes.json() : []);
  }

  async function toggleSubscription(companyId: number, countryId: number, currentlyEnabled: boolean) {
    if (currentlyEnabled) {
      await fetch(`/api/proxy/companies/${companyId}/countries/${countryId}`, { method: "DELETE" });
    } else {
      await fetch(`/api/proxy/companies/${companyId}/countries`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ country_id: countryId }),
      });
    }
    const subsRes = await fetch(`/api/proxy/companies/${companyId}/countries`);
    setSubscriptions(subsRes.ok ? await subsRes.json() : []);
  }

  if (loading) return <p className="text-slate-500">Chargement...</p>;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-2xl font-bold text-slate-800">Compagnies</h1>
        <Link
          href="/companies/new"
          className="bg-blue-600 text-white px-4 py-2 rounded-md text-sm hover:bg-blue-700"
        >
          Ajouter une compagnie
        </Link>
      </div>

      <div className="bg-white rounded-lg border border-slate-200 overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 border-b border-slate-200">
            <tr>
              <th className="text-left px-4 py-3 font-medium text-slate-600">Nom</th>
              <th className="text-left px-4 py-3 font-medium text-slate-600">Slug</th>
              <th className="text-left px-4 py-3 font-medium text-slate-600">Statut</th>
              <th className="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            {companies.map((c) => (
              <>
                <tr key={c.id} className="border-b border-slate-100 hover:bg-slate-50">
                  <td className="px-4 py-3 font-medium text-slate-800">{c.name}</td>
                  <td className="px-4 py-3 text-slate-600 font-mono">{c.slug}</td>
                  <td className="px-4 py-3">
                    <span
                      className={`inline-flex px-2 py-0.5 rounded-full text-xs font-medium ${
                        c.active ? "bg-green-100 text-green-700" : "bg-slate-100 text-slate-500"
                      }`}
                    >
                      {c.active ? "Actif" : "Inactif"}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right space-x-2">
                    <button
                      onClick={() => expandSubscriptions(c)}
                      className="text-xs text-blue-600 hover:text-blue-800 underline"
                    >
                      Pays abonnés
                    </button>
                    <button
                      onClick={() => toggleActive(c)}
                      className="text-xs text-slate-500 hover:text-slate-700 underline"
                    >
                      {c.active ? "Désactiver" : "Activer"}
                    </button>
                  </td>
                </tr>
                {expandedId === c.id && (
                  <tr key={`${c.id}-subs`} className="bg-slate-50">
                    <td colSpan={4} className="px-4 py-3">
                      <div className="flex flex-wrap gap-3">
                        {allCountries.map((country) => {
                          const sub = subscriptions.find((s) => s.country_id === country.id);
                          const enabled = sub?.enabled ?? false;
                          return (
                            <label key={country.id} className="flex items-center gap-1.5 text-xs">
                              <input
                                type="checkbox"
                                checked={enabled}
                                onChange={() => toggleSubscription(c.id, country.id, enabled)}
                                className="h-3.5 w-3.5 rounded border-input"
                              />
                              {country.name} ({country.code})
                            </label>
                          );
                        })}
                      </div>
                    </td>
                  </tr>
                )}
              </>
            ))}
            {companies.length === 0 && (
              <tr>
                <td colSpan={4} className="px-4 py-8 text-center text-slate-400">
                  Aucune compagnie configurée.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Write `app/(dashboard)/companies/new/page.tsx`**

Simpler than `countries/new/page.tsx` (no tabbed pre-fill sections needed — company settings are seeded from global defaults server-side on creation, per the backend's `CompanyStore.seed_from_global`, same as country creation does today):

```tsx
"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";

export default function NewCompanyPage() {
  const router = useRouter();
  const [form, setForm] = useState({ name: "", slug: "", logo_url: "", subject_prefix: "", signature: "" });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!form.name || !form.slug) {
      setError("Nom et slug sont requis.");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const body = {
        name: form.name,
        slug: form.slug,
        logo_url: form.logo_url || null,
        subject_prefix: form.subject_prefix || null,
        signature: form.signature || null,
      };
      const resp = await fetch("/api/proxy/companies", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!resp.ok) {
        const data = await resp.json();
        setError(data.detail ?? "Erreur lors de la création.");
        return;
      }
      router.push("/companies");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="max-w-2xl">
      <h1 className="text-2xl font-bold text-slate-800 mb-6">Nouvelle compagnie</h1>

      <form onSubmit={handleSubmit} className="bg-white rounded-lg border border-slate-200 p-6 space-y-4">
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">Nom</label>
          <input
            type="text"
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
            placeholder="ex. Acme Corp"
            className="w-full border border-slate-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:border-blue-500"
            required
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">Slug</label>
          <input
            type="text"
            value={form.slug}
            onChange={(e) => setForm({ ...form, slug: e.target.value })}
            placeholder="ex. acme-corp"
            className="w-full border border-slate-300 rounded-md px-3 py-2 text-sm font-mono focus:outline-none focus:border-blue-500"
            required
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">Préfixe sujet email (optionnel)</label>
          <input
            type="text"
            value={form.subject_prefix}
            onChange={(e) => setForm({ ...form, subject_prefix: e.target.value })}
            placeholder="ex. [ACME]"
            className="w-full border border-slate-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:border-blue-500"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">Signature email (optionnel)</label>
          <input
            type="text"
            value={form.signature}
            onChange={(e) => setForm({ ...form, signature: e.target.value })}
            className="w-full border border-slate-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:border-blue-500"
          />
        </div>

        {error && <p className="text-sm text-red-600">{error}</p>}

        <div className="flex gap-3">
          <button
            type="submit"
            disabled={saving}
            className="bg-blue-600 text-white px-4 py-2 rounded-md text-sm hover:bg-blue-700 disabled:opacity-50"
          >
            {saving ? "Création..." : "Créer la compagnie"}
          </button>
          <button
            type="button"
            onClick={() => router.push("/companies")}
            className="px-4 py-2 rounded-md text-sm text-slate-600 hover:bg-slate-100"
          >
            Annuler
          </button>
        </div>
      </form>
    </div>
  );
}
```

- [ ] **Step 3: Add sidebar nav link**

In `components/sidebar.tsx`, change:
```typescript
const superAdminLinks = [
  { href: "/users", label: "Utilisateurs" },
  { href: "/countries", label: "Pays" },
];
```
to:
```typescript
const superAdminLinks = [
  { href: "/users", label: "Utilisateurs" },
  { href: "/countries", label: "Pays" },
  { href: "/companies", label: "Compagnies" },
];
```

- [ ] **Step 4: Verify**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
npm run build
npm run lint
```
Then manually: log in as `super_admin`, confirm "Compagnies" appears in the sidebar, navigate to `/companies`, confirm the list loads, click "Pays abonnés" on a company and toggle a checkbox, confirm it persists on reload. Create a new company via `/companies/new`, confirm it appears in the list.

- [ ] **Step 5: Confirm with the user, then commit and push**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
git add "app/(dashboard)/companies" components/sidebar.tsx
git commit -m "$(cat <<'EOF'
feat: add /companies management page and sidebar nav

super_admin-only page: list/create/deactivate companies, toggle
country subscriptions. Mirrors the existing /countries page structure.
EOF
)"
```
Ask the user for explicit confirmation before pushing. On yes: `git push origin staging`.

---

### Task 5: Utilisateurs page — `company_id` field

**Files:**
- Modify: `components/users/create-user-dialog.tsx` (add `company_id` field, fetch companies list)
- Modify: `app/(dashboard)/users/page.tsx` (add `company_id`/company-name column)

**Interfaces:**
- Consumes: `app/api/proxy/companies` (Task 3), `Company` type shape (Task 2).

- [ ] **Step 1: Add `company_id` to `create-user-dialog.tsx`**

Add a `Company` interface near the existing `Country` interface:
```typescript
interface Company {
  id: number;
  name: string;
}
```

Add state:
```typescript
const [companyId, setCompanyId] = useState<string>("");
const [companies, setCompanies] = useState<Company[]>([]);
```

Extend the existing fetch-on-open `useEffect`:
```typescript
useEffect(() => {
    if (open) {
      fetch("/api/proxy/countries")
        .then((r) => r.json())
        .then((data) => setCountries(Array.isArray(data) ? data : []))
        .catch(() => setCountries([]));
      fetch("/api/proxy/companies")
        .then((r) => r.json())
        .then((data) => setCompanies(Array.isArray(data) ? data : []))
        .catch(() => setCompanies([]));
    }
  }, [open]);
```

Update `handleSubmit`'s validation and body:
```typescript
async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (role !== "super_admin" && !countryId) {
      setError("Un pays est requis pour les rôles company_admin et company_viewer.");
      return;
    }
    if (role !== "super_admin" && !companyId) {
      setError("Une compagnie est requise pour les rôles company_admin et company_viewer.");
      return;
    }
    setLoading(true);
    setError("");
    try {
      const body: Record<string, unknown> = { username, email, role };
      if (role !== "super_admin" && countryId) body.country_id = Number(countryId);
      if (role !== "super_admin" && companyId) body.company_id = Number(companyId);
      const res = await fetch("/api/proxy/users", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        const data = await res.json();
        setError(data.detail ?? "Erreur lors de la création");
        return;
      }
      setOpen(false);
      setUsername("");
      setEmail("");
      setRole("company_viewer");
      setCountryId("");
      setCompanyId("");
      onCreated();
    } catch {
      setError("Erreur réseau.");
    } finally {
      setLoading(false);
    }
  }
```

Add the company `<select>` field in the JSX, right after the existing country `<select>` block (still inside the `{role !== "super_admin" && (...)}` conditional block, or as its own sibling conditional block — use a second `{role !== "super_admin" && (...)}` block for clarity rather than nesting deeper):
```tsx
{role !== "super_admin" && (
            <div className="space-y-2">
              <Label htmlFor="new-company">Compagnie <span className="text-red-500">*</span></Label>
              <select
                id="new-company"
                value={companyId}
                onChange={(e) => setCompanyId(e.target.value)}
                className="w-full border border-input rounded-md px-3 py-2 text-sm bg-background"
                required
              >
                <option value="">— Sélectionner une compagnie —</option>
                {companies.map((c) => (
                  <option key={c.id} value={c.id}>{c.name}</option>
                ))}
              </select>
            </div>
          )}
```

- [ ] **Step 2: Add a company column to `users/page.tsx`**

Add `company_id: number | null;` to the `User` interface. Add a `Company` interface and `companyMap` state, mirroring the existing `Country`/`countryMap` pattern exactly:
```typescript
interface Company {
  id: number;
  name: string;
}
```
```typescript
const [companyMap, setCompanyMap] = useState<Record<number, string>>({});
```

In `loadUsers`, extend the `Promise.all` and add company-map population:
```typescript
async function loadUsers() {
    setLoading(true);
    try {
      const [usersRes, countriesRes, companiesRes] = await Promise.all([
        fetch("/api/proxy/users"),
        fetch("/api/proxy/countries"),
        fetch("/api/proxy/companies"),
      ]);
      if (usersRes.ok) {
        const data = await usersRes.json();
        setUsers(data.users);
      }
      if (countriesRes.ok) {
        const data: Country[] = await countriesRes.json();
        const map: Record<number, string> = {};
        data.forEach((c) => { map[c.id] = c.name; });
        setCountryMap(map);
      }
      if (companiesRes.ok) {
        const data: Company[] = await companiesRes.json();
        const map: Record<number, string> = {};
        data.forEach((c) => { map[c.id] = c.name; });
        setCompanyMap(map);
      }
    } finally {
      setLoading(false);
    }
  }
```

Add a "Compagnie" column header and cell, next to the existing "Pays" column:
```tsx
<th className="pb-2">Pays</th>
<th className="pb-2">Compagnie</th>
```
```tsx
<td className="text-slate-600 text-xs">
                      {user.country_id ? (countryMap[user.country_id] ?? `#${user.country_id}`) : "—"}
                    </td>
                    <td className="text-slate-600 text-xs">
                      {user.company_id ? (companyMap[user.company_id] ?? `#${user.company_id}`) : "—"}
                    </td>
```
Update the `colSpan` on the empty-state row from `6` to `7` (one more column added).

- [ ] **Step 3: Verify**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
npm run build
npm run lint
```
Then manually: as `super_admin`, open "Nouvel utilisateur", select `company_admin` or `company_viewer`, confirm the "Compagnie" dropdown appears and is required, create a user, confirm the users table now shows both Pays and Compagnie columns populated.

- [ ] **Step 4: Confirm with the user, then commit and push**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
git add components/users/create-user-dialog.tsx "app/(dashboard)/users/page.tsx"
git commit -m "$(cat <<'EOF'
feat: require company_id when creating company_admin/company_viewer users

Mirrors the existing country_id requirement. Users table now shows
each user's company alongside their country.
EOF
)"
```
Ask the user for explicit confirmation before pushing. On yes: `git push origin staging`.

---

### Task 6: Sources page — read-only for non-super_admin

**Files:**
- Modify: `app/(dashboard)/sources/page.tsx`

**Interfaces:**
- Consumes: `role` from `useCountry()` (already exposed today — no new context needed for this task, `CountryContextValue.role` already carries the right value after Task 1's rename).

- [ ] **Step 1: Gate write controls on role**

In `app/(dashboard)/sources/page.tsx`, extend the existing `useCountry()` destructure:
```typescript
const { selectedCountry, role } = useCountry();
```

Wrap the "Nouvelle source" trigger (the `<SourceFormDialog onSaved={loadSources} countryId={selectedCountry?.id} />` in the page header) so it only renders for `super_admin`:
```tsx
<div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">Sources</h1>
        {role === "super_admin" && (
          <SourceFormDialog onSaved={loadSources} countryId={selectedCountry?.id} />
        )}
      </div>
```

Wrap the per-row "Modifier"/"Supprimer" actions the same way, leaving "Tester" (read-only, no mutation) visible to every role:
```tsx
<td className="space-x-1 whitespace-nowrap">
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => handleTest(source)}
                        disabled={testResults[source.id] === "..."}
                      >
                        Tester
                      </Button>
                      {role === "super_admin" && (
                        <>
                          <SourceFormDialog
                            source={source}
                            trigger={
                              <Button size="sm" variant="outline">
                                Modifier
                              </Button>
                            }
                            onSaved={loadSources}
                          />
                          <DeleteSourceDialog source={source} onDeleted={loadSources} />
                        </>
                      )}
                    </td>
```

This is UI-level gating only — the backend (`sources.py`, sous-projet A) already rejects writes from non-super_admin with 403, so this is a UX improvement (hide controls that would fail) not the actual security boundary, which already exists server-side.

- [ ] **Step 2: Verify**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
npm run build
npm run lint
```
Then manually: log in as a `company_admin` or `company_viewer` test user (create one via Task 5's dialog if none exists), navigate to `/sources`, confirm "Nouvelle source" and the per-row "Modifier"/"Supprimer" buttons are absent, "Tester" remains clickable. Log in as `super_admin`, confirm all controls are present as before.

- [ ] **Step 3: Confirm with the user, then commit and push**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
git add "app/(dashboard)/sources/page.tsx"
git commit -m "$(cat <<'EOF'
feat: hide source write controls for non-super_admin roles

UX-level gating matching the backend's existing super_admin-only
write enforcement on sources.py (sous-projet A) — read-only roles no
longer see controls that would fail server-side anyway.
EOF
)"
```
Ask the user for explicit confirmation before pushing. On yes: `git push origin staging`.

---

### Task 7: Settings + Destinataires — company-scoping

**Files:**
- Modify: `app/(dashboard)/settings/page.tsx` (resolve settings URL against selected company for the 3 company-scoped sections)
- Modify: `app/(dashboard)/settings/settings-client.tsx` (thread `companyId` prop, 3-tier `saveUrl` resolution for `classification`/`scheduler`/`email` only)
- Modify: `components/settings/recipients-section.tsx` (thread `companyId`, add to fetch query)
- Modify: `components/recipients/recipient-form-dialog.tsx` (add optional `company_id` field, `super_admin` only)

**Interfaces:**
- Consumes: `useCompany()` from Task 2.
- **Important — only 3 of the 8 settings tabs are company-scoped.** The backend's `CompanyStore.MUTABLE_SECTIONS` (already shipped in sous-projet A) is `{"classification", "scheduler", "email"}` — `pipeline`, `llm`, `rag`, `prompts`, and the read-only `Infrastructure` tab stay country/global-level only, unchanged by this task. Do not add company-scoping to those 5 tabs; that would be building against a backend endpoint that doesn't exist (`companies.py` only exposes `classification`/`scheduler`/`email` as mutable sections).

- [ ] **Step 1: Resolve the settings URL against company for the 3 scoped sections**

In `app/(dashboard)/settings/page.tsx`, add the import and destructure:
```typescript
import { useCompany } from "@/contexts/company-context";
```
```typescript
const { selectedCompany, loading: companyLoading } = useCompany();
```

This page's current single `useEffect` fetches the *whole* settings bundle from one URL (country-level or global). Since company-level settings only cover 3 sections while the other 5 stay country/global, this page cannot simply swap URLs wholesale — it must fetch **both** the country/global bundle (for the 5 non-company sections + Infrastructure) **and**, separately, the company settings bundle (for the 3 company sections), then merge. Change the `useEffect`:

```typescript
useEffect(() => {
    if (countryLoading || companyLoading) return;

    setLoading(true);
    const baseUrl = selectedCountry
      ? `/api/proxy/countries/${selectedCountry.id}/settings`
      : "/api/proxy/settings";

    const fetches: Promise<void>[] = [
      fetch(baseUrl)
        .then((r) => (r.ok ? r.json() : null))
        .then((body) => {
          if (body === null) return;
          if (selectedCountry) {
            setSettings((prev) => ({ sections: { ...prev.sections, ...body }, readonly: prev.readonly }));
          } else {
            setSettings((prev) => ({
              sections: { ...prev.sections, ...(body.sections ?? {}) },
              readonly: body.readonly ?? {},
            }));
          }
        }),
    ];

    if (selectedCompany) {
      fetches.push(
        fetch(`/api/proxy/companies/${selectedCompany.id}/settings`)
          .then((r) => (r.ok ? r.json() : null))
          .then((body) => {
            if (body === null) return;
            // Company settings only cover classification/scheduler/email —
            // merge those keys over the country/global values so the 3
            // company-scoped tabs show company data while the other 5
            // (pipeline/llm/rag/prompts) keep showing country/global data.
            setSettings((prev) => ({ sections: { ...prev.sections, ...body }, readonly: prev.readonly }));
          })
      );
    }

    Promise.all(fetches)
      .catch(() => setSettings({ sections: {}, readonly: {} }))
      .finally(() => setLoading(false));
  }, [selectedCountry?.id, countryLoading, selectedCompany?.id, companyLoading]);
```

Reset `setSettings({ sections: {}, readonly: {} })` at the top of the effect body (before the two fetches) if you find stale data from a previous company/country bleeding through during rapid switching — verify this in Step 4's manual check; add the reset only if actually observed, don't add it speculatively.

Pass `companyId` down to `SettingsClient`:
```tsx
<SettingsClient
        sections={settings.sections}
        readonly={settings.readonly}
        countryId={selectedCountry?.id}
        companyId={selectedCompany?.id}
      />
```

- [ ] **Step 2: Thread `companyId` through `settings-client.tsx`**

Add `companyId?: number;` to `Props`. Change `saveUrl` to only route `classification`/`scheduler`/`email` through the company endpoint:
```typescript
function saveUrl(section: string): string {
    if (companyId !== undefined && (section === "classification" || section === "scheduler" || section === "email")) {
      return `/api/proxy/companies/${companyId}/settings/${section}`;
    }
    if (countryId !== undefined) {
      return `/api/proxy/countries/${countryId}/settings/${section}`;
    }
    return `/api/proxy/settings/${section}`;
  }
```

Update the function signature:
```typescript
export function SettingsClient({ sections, readonly, countryId, companyId }: Props) {
```

Pass `companyId` to `RecipientsSection` (Destinataires tab):
```tsx
{active === "Destinataires" && (
        <RecipientsSection countryId={countryId} companyId={companyId} />
      )}
```

- [ ] **Step 3: Thread `companyId` through `recipients-section.tsx` and `recipient-form-dialog.tsx`**

In `components/settings/recipients-section.tsx`, add `companyId?: number;` to `Props`, update `load()`'s query building:
```typescript
async function load() {
    setLoading(true);
    try {
      const params = new URLSearchParams();
      if (countryId !== undefined) params.set("country_id", String(countryId));
      if (companyId !== undefined) params.set("company_id", String(companyId));
      const qs = params.toString();
      const res = await fetch(`/api/proxy/recipients${qs ? `?${qs}` : ""}`);
      if (res.ok) {
        const data = await res.json();
        setRecipients(data.recipients ?? []);
      }
    } finally {
      setLoading(false);
    }
  }
```
Update the `useEffect` dependency array from `[countryId]` to `[countryId, companyId]`. Update the component signature:
```typescript
export function RecipientsSection({ countryId, companyId }: Props) {
```
Pass `companyId` to `RecipientFormDialog`:
```tsx
<RecipientFormDialog onSaved={load} countryId={countryId} companyId={companyId} />
```

In `components/recipients/recipient-form-dialog.tsx`, add `companyId?: number;` to `Props`, include it in the create payload (the backend's `RecipientCreate.company_id` field, added in sous-projet A's I2 fix, defaults to the caller's own company for non-super_admin and is ignored if set — only meaningful when a super_admin sends it explicitly):
```typescript
const payload = isEdit
      ? { name: form.name || null, group: form.group, enabled: form.enabled }
      : {
          email: form.email,
          name: form.name || null,
          group: form.group,
          enabled: form.enabled,
          country_id: countryId ?? null,
          company_id: companyId ?? null,
        };
```
Update the component signature:
```typescript
export function RecipientFormDialog({ recipient, trigger, onSaved, countryId, companyId }: Props) {
```

- [ ] **Step 4: Verify**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
npm run build
npm run lint
```
Then manually as `super_admin`: navigate to `/settings`, select a company, confirm the Classification/Planificateur/Email tabs load and save against company-scoped data (edit a value, save, reload, confirm it persisted) while Pipeline/LLM/RAG/Prompts still show country/global data unaffected. Switch companies, confirm Classification/Scheduler/Email data changes but Pipeline/LLM data doesn't. On the Destinataires tab, confirm the recipient list filters correctly when switching companies.

- [ ] **Step 5: Confirm with the user, then commit and push**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
git add "app/(dashboard)/settings/page.tsx" "app/(dashboard)/settings/settings-client.tsx" components/settings/recipients-section.tsx components/recipients/recipient-form-dialog.tsx
git commit -m "$(cat <<'EOF'
feat: company-scope Classification/Scheduler/Email settings + recipients

Only these 3 settings sections are company-scoped server-side
(CompanyStore.MUTABLE_SECTIONS) — Pipeline/LLM/RAG/Prompts stay
country/global. Recipients now filter by selected company in addition
to country, and creation supports an explicit company_id for
super_admin.
EOF
)"
```
Ask the user for explicit confirmation before pushing. On yes: `git push origin staging`.

---

### Task 8: Reports page — distinguish harvest vs. delivery runs

**Files:**
- Modify: `lib/api.ts` (`RunItem` type)
- Modify: `app/(dashboard)/reports/page.tsx`

**Interfaces:**
- Consumes: `run_type` field on the `Run` model, already exposed by the backend's `/api/v1/runs` endpoint (sous-projet A added `Run.run_type`/`Run.company_id` scoping — the field itself predates that work, from chantier 3's pipeline split).

- [ ] **Step 1: Add `run_type` to the `RunItem` type**

In `lib/api.ts`:
```typescript
export interface RunItem {
  run_id: string;
  status: string;
  started_at: string;
  finished_at?: string;
  duration_seconds?: number;
  stats?: { relevant_items: number };
  run_type?: "harvest" | "delivery";
}
```

- [ ] **Step 2: Display a run-type badge in the reports table**

In `app/(dashboard)/reports/page.tsx`, add a column header:
```tsx
<th className="pb-2">Statut</th>
<th className="pb-2">Type</th>
```
Add the corresponding cell, right after the status badge cell:
```tsx
<td>
                    <Badge variant="default">{run.status}</Badge>
                  </td>
                  <td>
                    <Badge variant={run.run_type === "harvest" ? "secondary" : "outline"}>
                      {run.run_type === "harvest" ? "Collecte" : "Livraison"}
                    </Badge>
                  </td>
```
Update the `colSpan` on the empty-state row from `5` to `6`.

Note: this page currently shows all runs indiscriminately regardless of `run_type` — the backend's `list_runs`/`list_reports` scoping (sous-projet A) already restricts what a `company_admin`/`company_viewer` can see (only their own `run_type="delivery"` rows) at the API level, so this frontend change is purely a labeling improvement for `super_admin`, who sees both types mixed together and currently has no way to tell them apart. Do not add client-side filtering by `run_type` — the backend's response is already correctly scoped per role; adding a redundant client-side filter risks the two falling out of sync.

- [ ] **Step 3: Verify**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
npm run build
npm run lint
```
Then manually as `super_admin`: navigate to `/reports`, confirm each row shows a "Collecte" or "Livraison" badge matching its actual `run_type`. As `company_admin`, confirm only "Livraison" rows appear (server-side filtering, unchanged by this task, but worth reconfirming here).

- [ ] **Step 4: Confirm with the user, then commit and push**

```bash
cd /home/yulcom/web/tenderai/tenderai-frontend
git add lib/api.ts "app/(dashboard)/reports/page.tsx"
git commit -m "$(cat <<'EOF'
feat: show harvest/delivery badge on the reports page

super_admin sees both run types mixed in the list; this labels which
is which. Purely a display change — the backend already scopes what
company_admin/company_viewer can see.
EOF
)"
```
Ask the user for explicit confirmation before pushing. On yes: `git push origin staging`.

---

## Self-Review Notes

**Spec coverage:** Section 1 (role rename) → Task 1. Section 2 (`CompanyContext`) → Task 2. Section 3 (proxy routes) → Task 3. Section 4 (`/companies` page + nav) → Task 4. Section 5's table: Sources → Task 6, Destinataires → Task 7, Paramètres → Task 7, Utilisateurs → Task 5, Reports/Runs/Logs → Task 8 (Logs excluded — confirmed during planning it's a system-log viewer unrelated to company/run data, no changes needed).

**Explicitly not covered by this plan** (confirmed out of scope, per the spec's own "Hors périmètre" section): source-list filtering by company's country subscriptions (backend doesn't do this yet either); `/api/v1/admin/me` returning `company_id` (frontend decodes the JWT directly, doesn't need this); the backend's `uq_recipients_email_country` DB constraint gap (backend-only, unrelated to this plan's frontend surface).

**Sequencing note carried from the spec:** this plan's tasks may all be implemented and pushed to `tenderai-frontend/staging` (git) as they're completed, but the actual staging *server* deploy (triggering `tenderai-infra`'s `deploy.yml`) waits until this entire plan is done and reviewed, per the user's explicit decision to deploy backend and frontend together.
