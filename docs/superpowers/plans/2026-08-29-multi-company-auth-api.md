# Multi-Company Auth & API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Section 3 ("Auth & API") of the approved multi-company spec in `tenderai-backend` — JWT `company_id` claim, the `admin`→`company_admin`/`viewer`→`company_viewer` role rename, a new `companies.py` CRUD router, and `company_id` scoping on the existing `recipients`/`runs`/`reports`/`sources`/`users`/`countries` endpoints — removing the three YULCOM-hardcoded stopgaps along the way. Frontend (Section 4) is a separate future plan; this plan is backend-only and ships something independently testable via the API.

**Architecture:** `User.company_id` and the `Company`/`CompanyCountrySubscription`/`CompanySettings`/`CompanyNoticeStatus` tables already exist (chantier 0). This plan wires them into auth (JWT payload, a new `CompanyScopedUser` FastAPI dependency mirroring the existing `SuperAdminUser` pattern) and exposes company management/settings/subscription endpoints, following the exact structural pattern `countries.py` already uses for the equivalent country-scoped endpoints.

**Tech Stack:** FastAPI, SQLAlchemy, Alembic, `python-jose` (JWT), pytest + `TestClient` + in-memory SQLite.

**Spec:** `docs/superpowers/specs/2026-08-23-multi-company-design.md` (Section 3 "Auth & API" is the primary reference; Section 5 step 7 for the role rename). Two decisions confirmed with the user on 2026-08-29, not in the spec text itself, are captured in Global Constraints below.

## Global Constraints

- **Role rename executes now**: `User.role` values `admin` → `company_admin`, `viewer` → `company_viewer` (`super_admin` unchanged). Every string-literal role check in the codebase must be updated in the same task as the migration — a rename that leaves a stale `"admin"` comparison anywhere is incomplete, not deferred.
- **A second test company is created** during this plan's own verification (slug `test-co`) with its own country subscription, `CompanySettings`, and at least one `company_admin` user — specifically to exercise cross-company isolation (company A cannot read/write company B's data), not just assert it exists in the abstract.
- **Roles**: `super_admin` (`company_id=NULL`, only role that can create/manage `Company` rows) · `company_admin` (`company_id` set, full control within their company) · `company_viewer` (`company_id` set, read-only, may additionally carry `country_id` to restrict further within the company — mirrors today's `viewer` + `country_id`).
- **Scoping default**: `super_admin` sees/acts on everything, unrestricted. `company_admin`/`company_viewer` are always filtered to their own `company_id`; attempting to address another company's ID by path/query param is a 403, not a filtered-empty result — the caller must not be able to distinguish "wrong company" from "not found" in a way that leaks existence, so 403 is used uniformly (not 404) for cross-company access attempts, matching the spec's `CompanyScopedUser` description ("raises 403 if a company_admin/company_viewer targets another company's `company_id`").
- **`companies.py` router URL prefix**: `/api/v1/admin/companies` (registered in `main.py` exactly like `countries.router` is registered under `/api/v1/admin/countries`).
- **Backend only.** Do not touch `tenderai-frontend`. Do not touch pipeline internals (`agents/`) beyond what's needed to resolve `company_id` from the authenticated caller at the API boundary — `delivery_graph.py`/`company_store.py`/`select_new_notices.py` etc. are already correct and out of scope.
- **Migration numbering**: next Alembic revision is `0014` (down_revision `"0013"`) — confirmed head via `ls alembic/versions/`.
- All new/changed endpoints require authentication (`AuthenticatedUser` at minimum); no endpoint in this plan is anonymous.
- Every task's tests use the `client`/`db_session`/`admin_token`-style fixtures already established in `tests/api/test_users.py` (real login flow producing a real JWT, in-memory SQLite via `StaticPool`, `app.dependency_overrides[get_db]`) — not the looser "assert status in (200, 401, 403)" style in `tests/api/test_countries_endpoints.py`. Assert actual response bodies and status codes.
- Run tests with `poetry run pytest tests/ -v --no-cov -m "not slow and not integration"` (matches CI). Do not rely on the full `pytest` invocation's coverage gate for iterating locally.

---

### Task 1: Role rename migration + `create-admin` bootstrap fix

**Files:**
- Create: `alembic/versions/0014_rename_admin_viewer_roles.py`
- Modify: `src/tenderai_bf/cli.py:462` (the `create-admin` INSERT — hardcodes `role` literal `'admin'`)
- Test: `tests/test_migrations.py` (new — first migration-level test in this repo; check if one exists first, create if not)

**Interfaces:**
- Produces: after this task, no row in `users.role` is ever `'admin'` or `'viewer'` — only `'super_admin'`, `'company_admin'`, `'company_viewer'`. Task 2 depends on this being true before it touches any role-literal string in `dependencies.py`/`users.py`/`countries.py`.

- [ ] **Step 1: Write the migration**

```python
"""rename_admin_viewer_roles

Revision ID: 0014
Revises: 0013
Create Date: 2026-08-29

Renames User.role values to match the company-scoped role model:
admin -> company_admin, viewer -> company_viewer. super_admin is
unchanged. Idempotent — safe to re-run (UPDATE ... WHERE role = X
is a no-op once already applied).
"""
import sqlalchemy as sa
from alembic import op

revision = "0014"
down_revision = "0013"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("UPDATE users SET role = 'company_admin' WHERE role = 'admin'")
    op.execute("UPDATE users SET role = 'company_viewer' WHERE role = 'viewer'")


def downgrade() -> None:
    op.execute("UPDATE users SET role = 'admin' WHERE role = 'company_admin'")
    op.execute("UPDATE users SET role = 'viewer' WHERE role = 'company_viewer'")
```

- [ ] **Step 2: Fix `create-admin`'s hardcoded role**

In `src/tenderai_bf/cli.py`, the `create_admin` command's INSERT currently hardcodes `role` as `'admin'` (line ~462, inside the `else:` branch that creates a new user):

```python
                conn.execute(
                    text(
                        "INSERT INTO users (id, username, email, hashed_password, role, "
                        "is_active, password_reset_required) "
                        "VALUES (:id, :username, :email, :pwd, 'admin', true, false)"
                    ),
```

Change the literal `'admin'` to `'super_admin'`. This is a real, independent latent bug (not introduced by the rename): migration `0004_super_admin_role.py` promoted the *existing* bootstrap user to `super_admin` back when that role was introduced, but `create-admin` itself was never updated, so a **fresh** deployment running `create-admin` today creates a plain `'admin'` user — which after this task's rename would become an orphaned `company_admin` with `company_id=NULL`, violating the "company_admin requires company_id" rule the rest of this plan establishes, and unable to create the first `Company` row at all (only `super_admin` can). The bootstrap account must be `super_admin`.

```python
                conn.execute(
                    text(
                        "INSERT INTO users (id, username, email, hashed_password, role, "
                        "is_active, password_reset_required) "
                        "VALUES (:id, :username, :email, :pwd, 'super_admin', true, false)"
                    ),
```

- [ ] **Step 3: Write a migration test**

Check whether `tests/test_migrations.py` already exists (`ls tests/test_migrations.py`). If it does, follow its existing pattern for a new test function. If it doesn't, create it:

```python
"""Tests for standalone data-migration behavior not covered by model/API tests."""
import uuid

from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker

from tenderai_bf.models import Base, User


def test_role_rename_migration_logic():
    """Simulates migration 0014's UPDATE statements directly against a fresh
    in-memory DB seeded with legacy role values, since running real Alembic
    migrations against SQLite in test isn't set up in this repo (Postgres-only
    migrations use op.execute with Postgres-flavored SQL elsewhere)."""
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    Session = sessionmaker(bind=engine)
    session = Session()

    admin_user = User(
        id=str(uuid.uuid4()),
        username="legacy_admin",
        email="legacy_admin@test.com",
        hashed_password="hashed",
        role="admin",
    )
    viewer_user = User(
        id=str(uuid.uuid4()),
        username="legacy_viewer",
        email="legacy_viewer@test.com",
        hashed_password="hashed",
        role="viewer",
    )
    super_admin_user = User(
        id=str(uuid.uuid4()),
        username="root",
        email="root@test.com",
        hashed_password="hashed",
        role="super_admin",
    )
    session.add_all([admin_user, viewer_user, super_admin_user])
    session.commit()

    # Same UPDATE statements migration 0014 runs against Postgres.
    session.execute(text("UPDATE users SET role = 'company_admin' WHERE role = 'admin'"))
    session.execute(text("UPDATE users SET role = 'company_viewer' WHERE role = 'viewer'"))
    session.commit()

    session.refresh(admin_user)
    session.refresh(viewer_user)
    session.refresh(super_admin_user)

    assert admin_user.role == "company_admin"
    assert viewer_user.role == "company_viewer"
    assert super_admin_user.role == "super_admin"  # unchanged

    session.close()
```

- [ ] **Step 4: Run the test**

```bash
poetry run pytest tests/test_migrations.py -v --no-cov
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add alembic/versions/0014_rename_admin_viewer_roles.py src/tenderai_bf/cli.py tests/test_migrations.py
git commit -m "$(cat <<'EOF'
feat(auth): rename admin/viewer roles to company_admin/company_viewer

Executes the role rename deferred from migration 0013 (multi-company
data model). Also fixes create-admin CLI, which still hardcoded the
now-legacy 'admin' role literal for fresh bootstrap deployments —
independent latent bug, would have produced an orphaned company_admin
with no company_id after this rename.
EOF
)"
```

---

### Task 2: JWT `company_id` claim + role-literal cleanup

**Files:**
- Modify: `src/tenderai_bf/api/dependencies.py` (`get_current_user`, `require_admin`, add `CompanyScopedUser`)
- Modify: `src/tenderai_bf/api/routers/admin.py` (`_build_token`, `get_current_user_info`)
- Modify: `src/tenderai_bf/api/routers/users.py` (`VALID_ROLES`, create/update logic)
- Modify: `src/tenderai_bf/api/routers/countries.py` (role-literal checks at lines ~117, ~122, ~158, ~163)
- Test: `tests/api/test_auth_company_scoping.py` (new)

**Interfaces:**
- Consumes: Task 1's guarantee that no `User.role` is ever `'admin'`/`'viewer'` in the DB.
- Produces: JWT payload now includes `"company_id": int | None`. New `CompanyScopedUser = Annotated[dict, Depends(require_company_scope)]` type alias in `dependencies.py`, importable as `from ..dependencies import CompanyScopedUser`. `require_company_scope(current_user, company_id: int | None = None)` — a dependency factory is NOT used; instead `require_company_scope` takes the *target* `company_id` as an explicit parameter each router passes in per-request (see Task 3/4 for call sites), returns `current_user` unchanged if allowed, raises `403` otherwise. This shape is used by every task from here on — do not invent a second scoping helper.

- [ ] **Step 1: Write the failing tests**

```python
"""Tests for company_id JWT claim and cross-company scoping."""
import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from tenderai_bf.api.dependencies import get_password_hash
from tenderai_bf.api.main import app
from tenderai_bf.db import get_db
from tenderai_bf.models import Base, Company, User


@pytest.fixture(scope="function")
def db_engine():
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    yield engine
    Base.metadata.drop_all(engine)


@pytest.fixture(scope="function")
def db_session(db_engine):
    Session = sessionmaker(bind=db_engine)
    session = Session()
    yield session
    session.close()


@pytest.fixture(scope="function")
def client(db_session):
    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.clear()


@pytest.fixture
def two_companies(db_session):
    yulcom = Company(name="YULCOM Technologies", slug="yulcom", active=True)
    test_co = Company(name="Test Co", slug="test-co", active=True)
    db_session.add_all([yulcom, test_co])
    db_session.commit()
    return yulcom, test_co


def _login(client, username, password):
    resp = client.post(
        "/api/v1/admin/login/simple", json={"username": username, "password": password}
    )
    assert resp.status_code == 200
    return resp.json()["access_token"]


def test_login_jwt_includes_company_id(client, db_session, two_companies):
    yulcom, _ = two_companies
    user = User(
        id=str(uuid.uuid4()),
        username="yulcom_admin",
        email="yulcom_admin@test.com",
        hashed_password=get_password_hash("pass12345"),
        role="company_admin",
        company_id=yulcom.id,
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(user)
    db_session.commit()

    token = _login(client, "yulcom_admin", "pass12345")

    resp = client.get("/api/v1/admin/me", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    # /me's UserResponse doesn't carry company_id today — this test decodes
    # the token directly to check the claim, which is the actual contract.
    from jose import jwt

    from tenderai_bf.api.dependencies import ALGORITHM, SECRET_KEY

    payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    assert payload["company_id"] == yulcom.id


def test_login_jwt_company_id_null_for_super_admin(client, db_session):
    user = User(
        id=str(uuid.uuid4()),
        username="root",
        email="root@test.com",
        hashed_password=get_password_hash("pass12345"),
        role="super_admin",
        company_id=None,
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(user)
    db_session.commit()

    token = _login(client, "root", "pass12345")

    from jose import jwt

    from tenderai_bf.api.dependencies import ALGORITHM, SECRET_KEY

    payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    assert payload["company_id"] is None
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
poetry run pytest tests/api/test_auth_company_scoping.py -v --no-cov
```
Expected: FAIL — `payload["company_id"]` raises `KeyError` (claim doesn't exist yet).

- [ ] **Step 3: Add `company_id` to the JWT payload**

In `src/tenderai_bf/api/routers/admin.py`, `_build_token`:

```python
def _build_token(user: User) -> LoginResponse:
    token = create_access_token(
        data={
            "sub": user.username,
            "email": user.email,
            "role": user.role,
            "country_id": user.country_id,
            "company_id": user.company_id,
            "password_reset_required": user.password_reset_required,
        }
    )
```

In `src/tenderai_bf/api/dependencies.py`, `get_current_user` return dict:

```python
        return {
            "username": username,
            "email": payload.get("email"),
            "role": payload.get("role", "company_viewer"),
            "country_id": payload.get("country_id"),
            "company_id": payload.get("company_id"),
            "password_reset_required": payload.get("password_reset_required", False),
        }
```

(Note the default role fallback also changes from `"viewer"` to `"company_viewer"` here — part of Step 5's literal cleanup, done here since it's the same line.)

- [ ] **Step 4: Run tests to verify they pass**

```bash
poetry run pytest tests/api/test_auth_company_scoping.py -v --no-cov
```
Expected: PASS (both tests).

- [ ] **Step 5: Clean up every remaining `"admin"`/`"viewer"` string literal**

In `src/tenderai_bf/api/dependencies.py`, `require_admin`:
```python
async def require_admin(current_user: Annotated[dict, Depends(require_auth)]) -> dict:
    """Require company_admin role. Raises 403 if authenticated but not company_admin."""
    if current_user.get("role") != "company_admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Company admin access required",
        )
    return current_user
```

In `src/tenderai_bf/api/routers/admin.py`, `get_current_user_info`:
```python
    return UserResponse(
        username=user["username"],
        email=user.get("email"),
        role=user.get("role", "company_viewer"),
        is_active=True,
        password_reset_required=user.get("password_reset_required", False),
    )
```

In `src/tenderai_bf/api/routers/users.py`:
```python
VALID_ROLES = ("super_admin", "company_admin", "company_viewer")
```
and the docstring/comment on `UserCreateRequest.role` (`# "super_admin" | "company_admin" | "company_viewer"`).

In `src/tenderai_bf/api/routers/countries.py`, both occurrences of `not in ("super_admin", "admin")` become `not in ("super_admin", "company_admin")` (lines ~117 and ~158 — the settings-write and run-trigger permission checks).

- [ ] **Step 6: Add the `CompanyScopedUser` dependency**

Append to `src/tenderai_bf/api/dependencies.py`, after `require_super_admin`:

```python
async def require_company_scope(
    current_user: Annotated[dict, Depends(require_auth)],
    company_id: int | None = None,
) -> dict:
    """Enforce company scoping: super_admin may access any company_id (including
    None); company_admin/company_viewer may only access their own company_id.
    Raises 403 (not 404) on a mismatch, so a non-super_admin caller cannot
    distinguish "wrong company" from "company doesn't exist" via status code.
    """
    if current_user.get("role") == "super_admin":
        return current_user
    if current_user.get("company_id") != company_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Access denied for this company",
        )
    return current_user
```

Add the type alias at the bottom with the others:
```python
CompanyScopedUser = Annotated[dict, Depends(require_company_scope)]
```

Note: `require_company_scope` takes `company_id` as a plain function parameter, not path-bound — FastAPI resolves it from a query param by default when used as a bare `Depends`. Tasks 3+ that need this scoped to a **path** parameter (e.g. `/companies/{company_id}/...`) must NOT use the `CompanyScopedUser` type alias directly; instead call `Depends(require_company_scope)` explicitly in the endpoint signature so FastAPI binds `company_id` from the path (FastAPI resolves a dependency's parameters against the *endpoint's* path/query params, not the dependency's own declaration site — this works automatically because `company_id` is already a path parameter name on those routes). Confirm this resolves correctly in Task 3's tests before assuming it "just works" — if FastAPI's dependency injection doesn't pick up the outer path param this way in practice, the fallback is to add an explicit `company_id: int` parameter to each endpoint and call `await require_company_scope(current_user, company_id)` directly in the function body instead of via `Depends`. Task 3's own tests are the actual verification of which approach is needed — do not assume the elegant version works without a passing test proving it.

- [ ] **Step 7: Run the full existing auth/users test suite to confirm no regression**

```bash
poetry run pytest tests/api/test_auth.py tests/api/test_users.py tests/api/test_countries_endpoints.py tests/api/test_countries_run_trigger.py -v --no-cov
```
Expected: all PASS. `test_users.py`'s fixtures already use `role="super_admin"`/`role="viewer"` — the `role="viewer"` one (`test_list_users_forbidden_for_viewer`) will still pass because it only asserts `403`, which holds for any non-super_admin role string, but re-read that test now: if it still literally creates a user with `role="viewer"` and expects normal login to succeed, that's fine (login doesn't validate role against `VALID_ROLES`, only user-creation/update does) — but flag it to a human if it fails, since a literal `role="viewer"` in a test fixture is now stale terminology worth a follow-up, not a hard requirement to fix in this task.

- [ ] **Step 8: Commit**

```bash
git add src/tenderai_bf/api/dependencies.py src/tenderai_bf/api/routers/admin.py src/tenderai_bf/api/routers/users.py src/tenderai_bf/api/routers/countries.py tests/api/test_auth_company_scoping.py
git commit -m "$(cat <<'EOF'
feat(auth): add company_id JWT claim and CompanyScopedUser dependency

JWT now carries company_id (null for super_admin). New
require_company_scope/CompanyScopedUser dependency mirrors the
existing SuperAdminUser pattern: super_admin passes through
unrestricted, company_admin/company_viewer get 403 (not 404) on any
company_id other than their own. Also finishes the admin->company_admin
role-literal cleanup started by the Task 1 migration.
EOF
)"
```

---

### Task 3: New `companies.py` router — CRUD + subscriptions + settings

**Files:**
- Create: `src/tenderai_bf/api/schemas/companies.py`
- Create: `src/tenderai_bf/api/routers/companies.py`
- Modify: `src/tenderai_bf/api/main.py` (import + `include_router`)
- Test: `tests/api/test_companies_endpoints.py` (new)

**Interfaces:**
- Consumes: `CompanyScopedUser`/`require_company_scope` from Task 2. `CompanyStore` (`get_section`, `put_section`, `get_all_with_fallback`, `seed_from_global`) from the already-existing `src/tenderai_bf/company_store.py` — do not reimplement any of this, call it directly exactly as `countries.py` calls `CountryStore`.
- Produces: `router` object importable as `from tenderai_bf.api.routers import companies` then `companies.router`, registered at prefix `/api/v1/admin/companies`. Endpoints, exactly matching spec Section 3:
  - `GET /api/v1/admin/companies` — `SuperAdminUser` only
  - `POST /api/v1/admin/companies` — `SuperAdminUser` only
  - `GET /api/v1/admin/companies/{company_id}` — `CompanyScopedUser`
  - `PUT /api/v1/admin/companies/{company_id}` — `SuperAdminUser` only (branding/active are super_admin-managed, not self-service)
  - `DELETE /api/v1/admin/companies/{company_id}` — `SuperAdminUser` only, soft-delete (`active=False`)
  - `GET /api/v1/admin/companies/{company_id}/countries` — `CompanyScopedUser`
  - `POST /api/v1/admin/companies/{company_id}/countries` — `SuperAdminUser` only (spec doesn't grant company_admin subscription-management; only super_admin manages the country catalog relationship)
  - `DELETE /api/v1/admin/companies/{company_id}/countries/{country_id}` — `SuperAdminUser` only
  - `GET /api/v1/admin/companies/{company_id}/settings` — `CompanyScopedUser`
  - `GET /api/v1/admin/companies/{company_id}/settings/{section}` — `CompanyScopedUser`
  - `PUT /api/v1/admin/companies/{company_id}/settings/{section}` — `CompanyScopedUser`, additionally requires role `super_admin` or `company_admin` (not `company_viewer` — read-only), reschedules the delivery job when `section == "scheduler"`
  - `POST /api/v1/admin/companies/{company_id}/run` — `CompanyScopedUser`, additionally requires `super_admin`/`company_admin`; triggers `get_delivery_pipeline().run(company_id=..., country_id=...)` in the background exactly like `countries.py`'s `trigger_run` does today for harvest

- [ ] **Step 1: Write the schemas**

```python
"""Pydantic schemas for Company API."""

from datetime import datetime

from pydantic import BaseModel, Field


class CompanyCreate(BaseModel):
    name: str = Field(min_length=1, max_length=255)
    slug: str = Field(min_length=1, max_length=64)
    logo_url: str | None = None
    subject_prefix: str | None = Field(None, max_length=100)
    signature: str | None = Field(None, max_length=255)


class CompanyUpdate(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=255)
    active: bool | None = None
    logo_url: str | None = None
    subject_prefix: str | None = Field(None, max_length=100)
    signature: str | None = Field(None, max_length=255)


class CompanyRead(BaseModel):
    id: int
    name: str
    slug: str
    active: bool
    logo_url: str | None = None
    subject_prefix: str | None = None
    signature: str | None = None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class CompanyCountrySubscriptionCreate(BaseModel):
    country_id: int


class CompanyCountrySubscriptionRead(BaseModel):
    company_id: int
    country_id: int
    enabled: bool
    created_at: datetime

    model_config = {"from_attributes": True}
```

Save to `src/tenderai_bf/api/schemas/companies.py`.

- [ ] **Step 2: Write the failing tests**

```python
"""Tests for the companies CRUD/subscriptions/settings router."""
import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from tenderai_bf.api.dependencies import get_password_hash
from tenderai_bf.api.main import app
from tenderai_bf.db import get_db
from tenderai_bf.models import Base, Company, Country, User


@pytest.fixture(scope="function")
def db_engine():
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    yield engine
    Base.metadata.drop_all(engine)


@pytest.fixture(scope="function")
def db_session(db_engine):
    Session = sessionmaker(bind=db_engine)
    session = Session()
    yield session
    session.close()


@pytest.fixture(scope="function")
def client(db_session):
    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.clear()


def _login(client, username, password):
    resp = client.post(
        "/api/v1/admin/login/simple", json={"username": username, "password": password}
    )
    assert resp.status_code == 200
    return resp.json()["access_token"]


@pytest.fixture
def super_admin_token(client, db_session):
    user = User(
        id=str(uuid.uuid4()),
        username="root",
        email="root@test.com",
        hashed_password=get_password_hash("rootpass123"),
        role="super_admin",
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(user)
    db_session.commit()
    return _login(client, "root", "rootpass123")


def test_super_admin_can_create_company(client, super_admin_token):
    resp = client.post(
        "/api/v1/admin/companies",
        json={"name": "Test Co", "slug": "test-co"},
        headers={"Authorization": f"Bearer {super_admin_token}"},
    )
    assert resp.status_code == 201
    body = resp.json()
    assert body["slug"] == "test-co"
    assert body["active"] is True


def test_company_admin_cannot_create_company(client, db_session, super_admin_token):
    yulcom = Company(name="YULCOM Technologies", slug="yulcom", active=True)
    db_session.add(yulcom)
    db_session.commit()

    company_admin = User(
        id=str(uuid.uuid4()),
        username="yulcom_admin",
        email="yulcom_admin@test.com",
        hashed_password=get_password_hash("pass12345"),
        role="company_admin",
        company_id=yulcom.id,
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(company_admin)
    db_session.commit()

    token = _login(client, "yulcom_admin", "pass12345")

    resp = client.post(
        "/api/v1/admin/companies",
        json={"name": "Evil Co", "slug": "evil-co"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 403


def test_company_admin_cannot_read_other_companys_settings(client, db_session):
    yulcom = Company(name="YULCOM Technologies", slug="yulcom", active=True)
    test_co = Company(name="Test Co", slug="test-co", active=True)
    db_session.add_all([yulcom, test_co])
    db_session.commit()

    company_admin = User(
        id=str(uuid.uuid4()),
        username="yulcom_admin",
        email="yulcom_admin@test.com",
        hashed_password=get_password_hash("pass12345"),
        role="company_admin",
        company_id=yulcom.id,
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(company_admin)
    db_session.commit()

    token = _login(client, "yulcom_admin", "pass12345")

    resp = client.get(
        f"/api/v1/admin/companies/{test_co.id}/settings",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 403


def test_company_admin_can_read_own_settings(client, db_session):
    yulcom = Company(name="YULCOM Technologies", slug="yulcom", active=True)
    db_session.add(yulcom)
    db_session.commit()

    company_admin = User(
        id=str(uuid.uuid4()),
        username="yulcom_admin",
        email="yulcom_admin@test.com",
        hashed_password=get_password_hash("pass12345"),
        role="company_admin",
        company_id=yulcom.id,
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(company_admin)
    db_session.commit()

    token = _login(client, "yulcom_admin", "pass12345")

    resp = client.get(
        f"/api/v1/admin/companies/{yulcom.id}/settings",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200


def test_subscribe_company_to_country(client, db_session, super_admin_token):
    company = Company(name="Test Co", slug="test-co", active=True)
    country = Country(name="Canada", code="CA", locale="fr")
    db_session.add_all([company, country])
    db_session.commit()

    resp = client.post(
        f"/api/v1/admin/companies/{company.id}/countries",
        json={"country_id": country.id},
        headers={"Authorization": f"Bearer {super_admin_token}"},
    )
    assert resp.status_code == 201

    resp = client.get(
        f"/api/v1/admin/companies/{company.id}/countries",
        headers={"Authorization": f"Bearer {super_admin_token}"},
    )
    assert resp.status_code == 200
    subs = resp.json()
    assert len(subs) == 1
    assert subs[0]["country_id"] == country.id
    assert subs[0]["enabled"] is True


def test_delete_company_is_soft_delete(client, db_session, super_admin_token):
    company = Company(name="Test Co", slug="test-co", active=True)
    db_session.add(company)
    db_session.commit()
    company_id = company.id

    resp = client.delete(
        f"/api/v1/admin/companies/{company_id}",
        headers={"Authorization": f"Bearer {super_admin_token}"},
    )
    assert resp.status_code == 204

    db_session.expire_all()
    from tenderai_bf.models import Company as CompanyModel

    row = db_session.query(CompanyModel).filter(CompanyModel.id == company_id).first()
    assert row is not None  # not actually deleted
    assert row.active is False
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
poetry run pytest tests/api/test_companies_endpoints.py -v --no-cov
```
Expected: FAIL — `404` on every request (router doesn't exist / isn't registered yet).

- [ ] **Step 4: Write the router**

```python
"""CRUD endpoints for companies, their country subscriptions, and per-company settings."""

from fastapi import APIRouter, HTTPException, status
from sqlalchemy.exc import IntegrityError

from ...company_store import MUTABLE_SECTIONS, CompanyStore
from ...logging import get_logger
from ...models import Company, CompanyCountrySubscription, Country
from ..dependencies import (
    AuthenticatedUser,
    CompanyScopedUser,
    DatabaseSession,
    SuperAdminUser,
)
from ..schemas.companies import (
    CompanyCountrySubscriptionCreate,
    CompanyCountrySubscriptionRead,
    CompanyCreate,
    CompanyRead,
    CompanyUpdate,
)
from ..schemas.settings import SECTION_SCHEMAS

logger = get_logger(__name__)

router = APIRouter()


def _get_company_or_404(company_id: int, db: DatabaseSession) -> Company:
    company = db.query(Company).filter(Company.id == company_id).first()
    if not company:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Company not found")
    return company


@router.get("", response_model=list[CompanyRead])
async def list_companies(db: DatabaseSession, user: SuperAdminUser):
    return db.query(Company).order_by(Company.name).all()


@router.post("", response_model=CompanyRead, status_code=status.HTTP_201_CREATED)
async def create_company(body: CompanyCreate, db: DatabaseSession, user: SuperAdminUser):
    company = Company(
        name=body.name,
        slug=body.slug,
        logo_url=body.logo_url,
        subject_prefix=body.subject_prefix,
        signature=body.signature,
    )
    db.add(company)
    try:
        db.flush()
        db.commit()
        db.refresh(company)
    except IntegrityError as e:
        db.rollback()
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            detail=f"Company with slug '{body.slug}' already exists",
        ) from e
    CompanyStore.seed_from_global(db, company.id)
    return company


@router.get("/{company_id}", response_model=CompanyRead)
async def get_company(
    company_id: int, db: DatabaseSession, user: CompanyScopedUser
):
    return _get_company_or_404(company_id, db)


@router.put("/{company_id}", response_model=CompanyRead)
async def update_company(
    company_id: int, body: CompanyUpdate, db: DatabaseSession, user: SuperAdminUser
):
    company = _get_company_or_404(company_id, db)
    if body.name is not None:
        company.name = body.name
    if body.active is not None:
        company.active = body.active
    if body.logo_url is not None:
        company.logo_url = body.logo_url
    if body.subject_prefix is not None:
        company.subject_prefix = body.subject_prefix
    if body.signature is not None:
        company.signature = body.signature
    db.commit()
    db.refresh(company)
    return company


@router.delete("/{company_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_company(company_id: int, db: DatabaseSession, user: SuperAdminUser):
    company = _get_company_or_404(company_id, db)
    company.active = False
    db.commit()


@router.get(
    "/{company_id}/countries", response_model=list[CompanyCountrySubscriptionRead]
)
async def list_company_countries(
    company_id: int, db: DatabaseSession, user: CompanyScopedUser
):
    _get_company_or_404(company_id, db)
    return (
        db.query(CompanyCountrySubscription)
        .filter(CompanyCountrySubscription.company_id == company_id)
        .all()
    )


@router.post(
    "/{company_id}/countries",
    response_model=CompanyCountrySubscriptionRead,
    status_code=status.HTTP_201_CREATED,
)
async def subscribe_company_country(
    company_id: int,
    body: CompanyCountrySubscriptionCreate,
    db: DatabaseSession,
    user: SuperAdminUser,
):
    _get_company_or_404(company_id, db)
    country = db.query(Country).filter(Country.id == body.country_id).first()
    if not country:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Country not found")

    existing = (
        db.query(CompanyCountrySubscription)
        .filter(
            CompanyCountrySubscription.company_id == company_id,
            CompanyCountrySubscription.country_id == body.country_id,
        )
        .first()
    )
    if existing:
        existing.enabled = True
        db.commit()
        db.refresh(existing)
        return existing

    sub = CompanyCountrySubscription(
        company_id=company_id, country_id=body.country_id, enabled=True
    )
    db.add(sub)
    db.commit()
    db.refresh(sub)
    return sub


@router.delete(
    "/{company_id}/countries/{country_id}", status_code=status.HTTP_204_NO_CONTENT
)
async def unsubscribe_company_country(
    company_id: int, country_id: int, db: DatabaseSession, user: SuperAdminUser
):
    sub = (
        db.query(CompanyCountrySubscription)
        .filter(
            CompanyCountrySubscription.company_id == company_id,
            CompanyCountrySubscription.country_id == country_id,
        )
        .first()
    )
    if not sub:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Subscription not found")
    sub.enabled = False
    db.commit()


@router.get("/{company_id}/settings")
async def get_all_company_settings(
    company_id: int, db: DatabaseSession, user: CompanyScopedUser
):
    _get_company_or_404(company_id, db)
    return CompanyStore.get_all_with_fallback(db, company_id)


@router.get("/{company_id}/settings/{section}")
async def get_company_settings_section(
    company_id: int, section: str, db: DatabaseSession, user: CompanyScopedUser
):
    if section not in MUTABLE_SECTIONS:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, detail=f"Unknown section: {section}"
        )
    _get_company_or_404(company_id, db)
    data = CompanyStore.get_section(db, company_id, section)
    if data is None:
        raise HTTPException(
            status.HTTP_404_NOT_FOUND,
            detail=f"Section '{section}' not found for this company",
        )
    return data


@router.put("/{company_id}/settings/{section}")
async def update_company_settings_section(
    company_id: int,
    section: str,
    body: dict,
    db: DatabaseSession,
    user: CompanyScopedUser,
):
    if section not in MUTABLE_SECTIONS:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, detail=f"Unknown section: {section}"
        )
    if user.get("role") not in ("super_admin", "company_admin"):
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, detail="Company admin role required"
        )
    company = _get_company_or_404(company_id, db)
    schema_cls = SECTION_SCHEMAS.get(section)
    if schema_cls:
        try:
            schema_cls(**body)
        except Exception as e:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(e)
            ) from e
    CompanyStore.put_section(db, company_id, section, body, updated_by=user["username"])
    if section == "scheduler":
        from ...scheduler.schedule import reschedule_company_delivery_job

        try:
            reschedule_company_delivery_job(company_id, company.slug, body)
        except Exception as e:
            logger.warning(
                "Failed to reschedule company delivery job after settings update",
                company_id=company_id,
                error=str(e),
            )
    return body


@router.post("/{company_id}/run", status_code=status.HTTP_202_ACCEPTED)
async def trigger_company_delivery(
    company_id: int,
    db: DatabaseSession,
    user: CompanyScopedUser,
):
    if user.get("role") not in ("super_admin", "company_admin"):
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, detail="Company admin role required"
        )
    company = _get_company_or_404(company_id, db)
    from ...agents import get_delivery_pipeline

    subscriptions = (
        db.query(CompanyCountrySubscription)
        .filter(
            CompanyCountrySubscription.company_id == company_id,
            CompanyCountrySubscription.enabled == True,  # noqa: E712
        )
        .all()
    )
    for sub in subscriptions:
        get_delivery_pipeline().run(
            company_id=company_id,
            country_id=sub.country_id,
            triggered_by="api",
            triggered_by_user=user["username"],
        )
    return {"status": "accepted", "company_id": company_id, "company_name": company.name}
```

Save to `src/tenderai_bf/api/routers/companies.py`.

**Important — verify the `CompanyScopedUser` path-binding assumption from Task 2 Step 6 right now**: run the test suite after this step. If `test_company_admin_cannot_read_other_companys_settings`/`test_company_admin_can_read_own_settings` fail with a 422 (FastAPI couldn't resolve `company_id` for the dependency) rather than the expected 403/200, the bare `CompanyScopedUser` type-alias approach does not auto-bind to the path parameter. In that case, replace every `user: CompanyScopedUser` parameter in this router with an explicit dependency call: change the parameter to `user: AuthenticatedUser` and add `await require_company_scope(user, company_id)` as the first line of the function body (import `require_company_scope` directly instead of the type alias). Do not guess — let the test tell you which form is needed, then make all endpoints in this router consistent with whichever form actually works.

- [ ] **Step 5: Register the router**

In `src/tenderai_bf/api/main.py`:
```python
from .routers import (
    admin,
    companies,
    countries,
    health,
    recipients,
    reports,
    runs,
    sources,
    users,
)
```
and, alongside the other `include_router` calls:
```python
app.include_router(
    companies.router, prefix="/api/v1/admin/companies", tags=["Companies"]
)
```

Also add `"companies"` to `src/tenderai_bf/api/routers/__init__.py`'s `__all__` list (it currently reads `["health", "runs", "sources", "reports", "admin", "countries"]` — note `users`/`recipients` aren't in there either, so match whatever the actual current convention is rather than assuming; just make sure `companies` is importable the same way `countries` already is).

- [ ] **Step 6: Confirm the `reschedule_company_delivery_job` call site matches its real signature**

Already verified during planning: `src/tenderai_bf/scheduler/schedule.py` defines `reschedule_company_delivery_job(company_id: int, company_slug: str, scheduler_cfg: dict) -> None` (mirrors `reschedule_country_job`, no-ops if the scheduler isn't running). Step 4's router code above already calls it correctly as `reschedule_company_delivery_job(company_id, company.slug, body)`. This step is just confirming that call still matches after Step 4 — no code change expected here unless `schedule.py` changed since planning (re-run `grep -n "def reschedule_company_delivery_job" -A3 src/tenderai_bf/scheduler/schedule.py` to double check before moving on).

- [ ] **Step 7: Run tests to verify they pass**

```bash
poetry run pytest tests/api/test_companies_endpoints.py -v --no-cov
```
Expected: all PASS.

- [ ] **Step 8: Run the full API test suite**

```bash
poetry run pytest tests/api/ -v --no-cov
```
Expected: all PASS, no regressions.

- [ ] **Step 9: Commit**

```bash
git add src/tenderai_bf/api/schemas/companies.py src/tenderai_bf/api/routers/companies.py src/tenderai_bf/api/routers/__init__.py src/tenderai_bf/api/main.py tests/api/test_companies_endpoints.py
git commit -m "$(cat <<'EOF'
feat(api): add companies CRUD router with country subscriptions and settings

New GET/POST/PUT/DELETE /api/v1/admin/companies endpoints, plus
company-country subscription management and CompanySettings
read/write, mirroring the existing countries.py router structure.
Company management (create/update/delete/subscribe) is super_admin
only; company-scoped reads and settings writes use the new
CompanyScopedUser dependency from Task 2.
EOF
)"
```

---

### Task 4: `company_id` scoping on existing routers + remove YULCOM stopgaps

**Files:**
- Modify: `src/tenderai_bf/api/dependencies.py` (new `resolve_delivery_company_id` helper)
- Modify: `src/tenderai_bf/api/routers/recipients.py` (list/create scoping, remove YULCOM stopgap)
- Modify: `src/tenderai_bf/api/routers/runs.py` (list/trigger scoping, remove YULCOM stopgap, add explicit company selection)
- Modify: `src/tenderai_bf/api/routers/reports.py` (list scoping)
- Modify: `src/tenderai_bf/api/routers/sources.py` (read-only enforcement for non-super_admin)
- Modify: `src/tenderai_bf/api/routers/users.py` (`company_id` required for `company_admin`/`company_viewer`)
- Modify: `src/tenderai_bf/api/routers/countries.py` (remove YULCOM stopgap in `trigger_run`, add explicit company selection)
- Test: `tests/api/test_company_scoping_existing_routers.py` (new)

**Interfaces:**
- Consumes: `CompanyScopedUser`, `company_id` JWT claim from Task 2; `Company` model.
- Produces: `resolve_delivery_company_id(user: dict | None, requested_company_id: int | None, db: Session) -> int | None` in `dependencies.py` — the shared resolution rule used by both manual-trigger endpoints (Step 4) and `create_recipient` (Step 3). No other new public interface — this task otherwise only changes filtering/authorization behavior on endpoints Tasks 1-3 don't touch.
- **Pre-existing tests this task must not break**: `tests/api/test_recipients_endpoints.py::test_create_recipient_defaults_to_yulcom_company` and `tests/api/test_countries_run_trigger.py::test_trigger_run_calls_both_harvest_and_delivery` both currently pass by depending on the YULCOM stopgap this task removes — run them before and after each relevant step (see Step 3's note), not just at the final Step 9 full-suite run.

**Important — this task closes a real regression the original stopgap comments warn against, not just removes them.** The stopgap text in `countries.py`/`runs.py` reads *"Stopgap until the Auth/API plan adds company selection to this endpoint: deliver to YULCOM... so this manual trigger keeps sending email as it did before the pipeline split."* A naive fix that simply replaces the hardcoded YULCOM lookup with `current_user["company_id"]` would break exactly what that comment warns about: the live admin account is `super_admin`, whose `company_id` is always `None` — so the "Lancer maintenant" button (which calls `countries.py`'s `trigger_run`) would silently stop delivering email the moment this ships, with only a log line to notice. Step 4 below adds the actual company-selection capability the comment calls for, with a YULCOM fallback for `super_admin` when no explicit selection is made — preserving today's default button behavior until Section 4 (frontend) adds a real picker.

- [ ] **Step 1: Write the failing tests**

```python
"""Tests for company_id scoping added to recipients/runs/users, and removal
of the YULCOM-hardcoded stopgaps."""
import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from tenderai_bf.api.dependencies import get_password_hash
from tenderai_bf.api.main import app
from tenderai_bf.db import get_db
from tenderai_bf.models import Base, Company, Country, Recipient, User


@pytest.fixture(scope="function")
def db_engine():
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    yield engine
    Base.metadata.drop_all(engine)


@pytest.fixture(scope="function")
def db_session(db_engine):
    Session = sessionmaker(bind=db_engine)
    session = Session()
    yield session
    session.close()


@pytest.fixture(scope="function")
def client(db_session):
    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.clear()


def _login(client, username, password):
    resp = client.post(
        "/api/v1/admin/login/simple", json={"username": username, "password": password}
    )
    assert resp.status_code == 200
    return resp.json()["access_token"]


def test_recipient_created_by_company_admin_gets_own_company_id(client, db_session):
    company = Company(name="Test Co", slug="test-co", active=True)
    country = Country(name="Canada", code="CA", locale="fr")
    db_session.add_all([company, country])
    db_session.commit()

    admin = User(
        id=str(uuid.uuid4()),
        username="testco_admin",
        email="testco_admin@test.com",
        hashed_password=get_password_hash("pass12345"),
        role="company_admin",
        company_id=company.id,
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(admin)
    db_session.commit()

    token = _login(client, "testco_admin", "pass12345")

    resp = client.post(
        "/api/v1/recipients",
        json={
            "email": "someone@test-co.com",
            "name": "Someone",
            "group": "to",
            "enabled": True,
            "country_id": country.id,
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 201
    assert resp.json()["company_id"] == company.id  # not hardcoded to YULCOM


def test_recipients_list_filtered_to_own_company(client, db_session):
    company_a = Company(name="Company A", slug="company-a", active=True)
    company_b = Company(name="Company B", slug="company-b", active=True)
    db_session.add_all([company_a, company_b])
    db_session.commit()

    db_session.add_all(
        [
            Recipient(email="a@a.com", group="to", enabled=True, company_id=company_a.id),
            Recipient(email="b@b.com", group="to", enabled=True, company_id=company_b.id),
        ]
    )
    admin_a = User(
        id=str(uuid.uuid4()),
        username="admin_a",
        email="admin_a@test.com",
        hashed_password=get_password_hash("pass12345"),
        role="company_admin",
        company_id=company_a.id,
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(admin_a)
    db_session.commit()

    token = _login(client, "admin_a", "pass12345")

    resp = client.get(
        "/api/v1/recipients", headers={"Authorization": f"Bearer {token}"}
    )
    assert resp.status_code == 200
    emails = [r["email"] for r in resp.json()["recipients"]]
    assert emails == ["a@a.com"]


def test_create_company_admin_user_requires_company_id(client, db_session):
    root = User(
        id=str(uuid.uuid4()),
        username="root",
        email="root@test.com",
        hashed_password=get_password_hash("rootpass123"),
        role="super_admin",
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(root)
    db_session.commit()
    token = _login(client, "root", "rootpass123")

    resp = client.post(
        "/api/v1/users",
        json={
            "username": "newcompanyadmin",
            "email": "newcompanyadmin@test.com",
            "role": "company_admin",
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 400


def test_super_admin_manual_trigger_defaults_to_yulcom(client, db_session, monkeypatch):
    """The exact regression this task must not reintroduce: today's live
    admin account is super_admin, and clicking "Lancer maintenant" must
    keep delivering to YULCOM by default when no company_id is given."""
    from tenderai_bf.models import Country

    yulcom = Company(name="YULCOM Technologies", slug="yulcom", active=True)
    country = Country(name="Burkina Faso", code="BF", locale="fr")
    db_session.add_all([yulcom, country])
    db_session.commit()

    root = User(
        id=str(uuid.uuid4()),
        username="root",
        email="root@test.com",
        hashed_password=get_password_hash("rootpass123"),
        role="super_admin",
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(root)
    db_session.commit()
    token = _login(client, "root", "rootpass123")

    from unittest.mock import MagicMock

    from tenderai_bf.agents import get_delivery_pipeline

    fake_result = MagicMock(error_occurred=False, warnings=[])
    captured = {}

    def fake_run(**kwargs):
        captured.update(kwargs)
        return fake_result

    monkeypatch.setattr(get_delivery_pipeline(), "run", fake_run)

    resp = client.post(
        f"/api/v1/admin/countries/{country.id}/run",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 202
    assert resp.json()["company_id"] == yulcom.id


def test_company_admin_cannot_trigger_delivery_for_another_company(
    client, db_session
):
    from tenderai_bf.models import Country

    own_company = Company(name="Own Co", slug="own-co", active=True)
    other_company = Company(name="Other Co", slug="other-co", active=True)
    country = Country(name="Burkina Faso", code="BF", locale="fr")
    db_session.add_all([own_company, other_company, country])
    db_session.commit()

    admin = User(
        id=str(uuid.uuid4()),
        username="own_admin",
        email="own_admin@test.com",
        hashed_password=get_password_hash("pass12345"),
        role="company_admin",
        company_id=own_company.id,
        country_id=country.id,
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(admin)
    db_session.commit()
    token = _login(client, "own_admin", "pass12345")

    resp = client.post(
        f"/api/v1/admin/countries/{country.id}/run?company_id={other_company.id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 403
```

The first new test (`test_super_admin_manual_trigger_defaults_to_yulcom`) patches the `get_delivery_pipeline()` singleton's `run` method with a `MagicMock`-backed stand-in, so the test doesn't actually execute a real harvest/delivery run and doesn't need to know `TenderAIState`'s full constructor — it only asserts the endpoint *resolved and returned* `company_id == yulcom.id` in its response, which is enough to prove the fallback logic ran correctly. Before trusting this pattern, confirm `get_delivery_pipeline()` in `src/tenderai_bf/agents/__init__.py` returns a stable singleton instance (check whether it's cached/memoized) — if it constructs a fresh instance on every call, `monkeypatch.setattr(get_delivery_pipeline(), "run", fake_run)` in the test would patch a different instance than the one the endpoint code calls, and the mock would never be hit. If that's the case, patch the class instead: find the pipeline class name and use `monkeypatch.setattr(SomeDeliveryPipelineClass, "run", lambda self, **kw: fake_run(**kw))`. Whichever form actually works, the point of the test is the `202` response's `company_id` field matching `yulcom.id` — do not weaken that assertion to make the test pass.

- [ ] **Step 2: Run tests to verify they fail**

```bash
poetry run pytest tests/api/test_company_scoping_existing_routers.py -v --no-cov
```
Expected: FAIL on all five — recipients still hardcode YULCOM (first test's `company_id` assertion fails if a YULCOM company doesn't even exist in this test's DB, likely erroring instead), list isn't filtered, `users.py` still only validates `country_id` not `company_id`, and the two new manual-trigger tests fail (`404`/`422` — `?company_id=` query param and the `company_id` response field don't exist yet on `countries.py`'s `trigger_run`).

- [ ] **Step 3: Fix `recipients.py`**

**First, verify a pre-existing test this step must not break**: run `poetry run pytest tests/api/test_recipients_endpoints.py -v --no-cov` before touching this file. `test_create_recipient_defaults_to_yulcom_company` creates a recipient as a `super_admin` caller (`admin_token` fixture) and asserts `row.company_id == yulcom.id` — i.e. today's YULCOM stopgap is depended on by an existing, currently-passing test, not just the two manual-trigger endpoints Step 4 already handles. A naive `company_id=user.get("company_id")` substitution here would give `None` for that same `super_admin` caller and break this test, for the identical reason Step 4 fixes `runs.py`/`countries.py`. Use `resolve_delivery_company_id` (from `dependencies.py`, already added earlier in this task) here too — it already encodes exactly this fallback rule (own company for `company_admin`/`company_viewer`, YULCOM fallback for `super_admin` with no override) even though this endpoint has no `requested_company_id` override to pass, so call it as `resolve_delivery_company_id(user, None, db)`.

Replace the YULCOM stopgap in `create_recipient` and add company-scoping to `list_recipients`:

```python
@router.get("", response_model=RecipientListResponse)
async def list_recipients(
    db: DatabaseSession,
    user: AuthenticatedUser,
    country_id: int | None = None,
    enabled_only: bool = False,
):
    from ...models import Recipient

    query = db.query(Recipient)
    if user.get("role") != "super_admin":
        query = query.filter(Recipient.company_id == user.get("company_id"))
    if country_id is not None:
        query = query.filter(Recipient.country_id == country_id)
    if enabled_only:
        query = query.filter(Recipient.enabled == True)  # noqa: E712

    rows = query.order_by(Recipient.email).all()
    return RecipientListResponse(
        recipients=[RecipientSchema.from_orm(r) for r in rows],
        total=len(rows),
    )
```

```python
@router.post("", response_model=RecipientSchema, status_code=status.HTTP_201_CREATED)
async def create_recipient(
    request: RecipientCreate, db: DatabaseSession, user: AuthenticatedUser
):
    from ...models import Recipient

    query = db.query(Recipient).filter(Recipient.email == request.email)
    if request.country_id is not None:
        query = query.filter(Recipient.country_id == request.country_id)
    if query.first():
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Recipient with email '{request.email}' already exists for this country",
        )

    from ..dependencies import resolve_delivery_company_id

    row = Recipient(
        email=request.email,
        name=request.name,
        group=request.group,
        enabled=request.enabled,
        preferences=request.preferences,
        country_id=request.country_id,
        company_id=resolve_delivery_company_id(user, None, db),
    )
    db.add(row)
    db.commit()
    db.refresh(row)

    logger.info(
        "Recipient created",
        recipient_id=row.id,
        email=row.email,
        created_by=user.get("username"),
    )
    return RecipientSchema.from_orm(row)
```

Remove the now-unused `from ...models import Company` import if `Company` isn't referenced anywhere else in this file after the edit (check with `grep -n "Company" src/tenderai_bf/api/routers/recipients.py`) — `resolve_delivery_company_id` does its own `Company` import internally, this file doesn't need its own anymore.

- [ ] **Step 4: Add `resolve_delivery_company_id`, then fix `runs.py` and `countries.py`'s YULCOM stopgaps**

First, append to `src/tenderai_bf/api/dependencies.py` (after `require_company_scope`/`CompanyScopedUser`):

```python
def resolve_delivery_company_id(
    user: dict | None, requested_company_id: int | None, db: Session
) -> int | None:
    """Resolve which company_id a manual harvest-trigger endpoint should
    deliver to.

    - Anonymous caller (user is None): no company can be resolved — caller
      must handle None by skipping delivery.
    - company_admin/company_viewer: always their own company_id. Callers
      must reject a mismatched requested_company_id with 403 *before*
      calling this (see the two router call sites below) — this function
      does not re-check that, it only resolves the effective value once
      authorization has already passed.
    - super_admin with an explicit requested_company_id: uses it as given.
    - super_admin with no explicit selection: falls back to the YULCOM
      company, preserving today's default behavior for the existing
      "Lancer maintenant" button until the frontend (Section 4) adds a
      real company picker that sends an explicit company_id.

    Returns None if no company can be resolved at all (e.g. anonymous
    caller, or the YULCOM row is missing) — callers must handle None by
    skipping delivery and logging, not raising.
    """
    if user is None:
        return None
    if user.get("role") != "super_admin":
        return user.get("company_id")
    if requested_company_id is not None:
        return requested_company_id

    from ..models import Company

    yulcom = db.query(Company).filter(Company.slug == "yulcom").first()
    return yulcom.id if yulcom else None
```

`Session` is already imported in `dependencies.py` (used by `DatabaseSession = Annotated[Session, Depends(get_db)]`) — no new import needed for the type hint.

In `src/tenderai_bf/api/routers/runs.py`, add a `company_id` field to `RunTriggerRequest`:

```python
    company_id: int | None = Field(
        default=None,
        description="Company to deliver to (super_admin only; company_admin/"
        "company_viewer always deliver to their own company; defaults to "
        "YULCOM for super_admin if omitted)",
    )
```

Then, before the `def run_pipeline():` closure inside `trigger_run` (so the resolution runs synchronously against the request-scoped `db` session, not inside the background thread — the original stopgap code opened a *fresh* `get_db_context()` session specifically because a background task can run after the request's `db` session is closed; resolving up front avoids needing that entirely):

```python
    # Non-super_admin cannot request delivery to a company other than their own
    if (
        current_user
        and current_user.get("role") != "super_admin"
        and request.company_id is not None
        and request.company_id != current_user.get("company_id")
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Cannot trigger delivery for another company",
        )

    from ..dependencies import resolve_delivery_company_id

    target_company_id = resolve_delivery_company_id(
        current_user, request.company_id, db
    )
```

This needs `db: DatabaseSession` added as a parameter of `trigger_run` if it isn't already one (check — `trigger_run` currently takes `request`, `background_tasks`, `current_user`; add `db: DatabaseSession` to the signature, matching how `countries.py`'s `trigger_run` already takes `db`).

Replace the stopgap block inside `run_pipeline()`:

```python
            result = harvest_result
            if request.send_email:
                if target_company_id is not None:
                    result = get_delivery_pipeline().run(
                        company_id=target_company_id,
                        country_id=request.country_id,
                        triggered_by=request.triggered_by,
                        triggered_by_user=triggered_by_user,
                    )
                else:
                    logger.warning(
                        "No company_id resolved for delivery after manual harvest "
                        "trigger — skipping delivery",
                        country_id=request.country_id,
                    )
```

`target_company_id` is a plain closed-over variable from the outer scope (resolved before `run_pipeline` is defined) — this removes the `from ...db import get_db_context` / `from ...models import Company` YULCOM lookup from inside the closure entirely.

Apply the equivalent transformation to `src/tenderai_bf/api/routers/countries.py`'s `trigger_run`. Add a `company_id: int | None = None` query parameter to the endpoint signature:

```python
@router.post("/{country_id}/run", status_code=status.HTTP_202_ACCEPTED)
async def trigger_run(
    country_id: int,
    db: DatabaseSession,
    user: AuthenticatedUser,
    background_tasks: BackgroundTasks,
    company_id: int | None = None,
):
    # Only company_admin or super_admin may trigger pipeline runs
    if user.get("role") not in ("super_admin", "company_admin"):
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, detail="Admin role required to trigger runs"
        )
    # Non-super_admin can only trigger runs for their own country
    if user.get("role") != "super_admin" and user.get("country_id") != country_id:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, detail="Access denied for this country"
        )
    # Non-super_admin cannot request delivery to a company other than their own
    if (
        user.get("role") != "super_admin"
        and company_id is not None
        and company_id != user.get("company_id")
    ):
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, detail="Cannot trigger delivery for another company"
        )
    _get_country_or_404(country_id, db)
    from ...agents import get_delivery_pipeline, get_pipeline
    from ..dependencies import resolve_delivery_company_id

    target_company_id = resolve_delivery_company_id(user, company_id, db)

    def _run():
        get_pipeline().run(
            country_id=country_id,
            triggered_by="api",
            triggered_by_user=user["username"],
        )
        if target_company_id is not None:
            get_delivery_pipeline().run(
                company_id=target_company_id,
                country_id=country_id,
                triggered_by="api",
                triggered_by_user=user["username"],
            )
        else:
            logger.warning(
                "No company_id resolved for delivery after manual harvest trigger",
                country_id=country_id,
                username=user["username"],
            )

    background_tasks.add_task(_run)
    return {"status": "accepted", "country_id": country_id, "company_id": target_company_id}
```

Note: Task 2 Step 5 already fixed this same role-literal (`"admin"` → `"company_admin"`) at this line as part of its cleanup pass — this Step 4 rewrite naturally carries that fix forward since it replaces the whole function body. No separate action needed here beyond what's shown above; just confirm no stray `"admin"` literal remains anywhere else in this file with `grep -n '"admin"' src/tenderai_bf/api/routers/countries.py` before moving on.

- [ ] **Step 5: Scope `reports.py` and `runs.py`'s list/status endpoints**

`Run.company_id` and `Run.run_type` already exist (Task's Global Constraints — chantier 3 work). Add filtering to `list_runs` in `runs.py`:

```python
@router.get("", response_model=RunListResponse)
async def list_runs(
    db: DatabaseSession,
    current_user: CurrentUser,
    page: int = 1,
    page_size: int = 20,
    status_filter: str | None = None,
    country_id: int | None = None,
):
    from ...models import Run

    query = db.query(Run)

    if current_user and current_user.get("role") != "super_admin":
        query = query.filter(
            Run.run_type == "delivery", Run.company_id == current_user.get("company_id")
        )

    if status_filter:
        query = query.filter(Run.status == status_filter)

    if country_id is not None:
        query = query.filter(Run.country_id == country_id)
    ...
```//rest of function unchanged, only the query-building block above `total = query.count()` gets these lines inserted.

Apply the same `Run.company_id`/`Run.run_type` filter pattern to `reports.py`'s `list_reports` — but note `reports.py` currently has no `AuthenticatedUser`/`CurrentUser` parameter on any endpoint at all (re-check the file — confirmed during exploration: `list_reports(db: DatabaseSession, limit: int = 50)` takes no user). Add `current_user: CurrentUser` as a parameter to `list_reports` and filter identically:

```python
@router.get("", response_model=ReportListResponse)
async def list_reports(db: DatabaseSession, current_user: CurrentUser, limit: int = 50):
    from ...models import Run

    query = db.query(Run).filter(Run.report_url.isnot(None))
    if current_user and current_user.get("role") != "super_admin":
        query = query.filter(
            Run.run_type == "delivery", Run.company_id == current_user.get("company_id")
        )
    runs = query.order_by(Run.completed_at.desc()).limit(limit).all()
    ...
```//rest of function unchanged.

Do not add auth requirements to `reports.py`'s other endpoints (`download_report`, `preview_report`, etc.) — they're out of scope for this task; only `list_reports` needs company-scoped filtering per the spec's table (`runs.py`, `reports.py` row).

- [ ] **Step 6: Enforce read-only `sources.py` for non-super_admin**

Per spec: "Read-only for company_admin/viewer... Write endpoints stay super_admin only." Add the check to `create_source`, `update_source`, `delete_source`:

```python
@router.post("", response_model=SourceSchema, status_code=status.HTTP_201_CREATED)
async def create_source(
    request: SourceCreate, db: DatabaseSession, user: AuthenticatedUser
):
    """Create a new source (super_admin only)."""
    if user.get("role") != "super_admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Super-admin access required to create sources",
        )
    ...
```
Apply the identical `if user.get("role") != "super_admin": raise HTTPException(403, ...)` guard as the first line inside `update_source` and `delete_source` too (after the existing docstrings, before any DB query). `list_sources`/`get_source`/`test_source` stay open to any authenticated role (read-only).

- [ ] **Step 7: `company_id` required for `company_admin`/`company_viewer` in `users.py`**

Mirror the existing `country_id` requirement exactly. In `create_user`:

```python
    # Non-super_admin users must have a country and a company
    if request.role != "super_admin" and not request.country_id:
        raise HTTPException(
            status_code=400, detail="country_id is required for company_admin and company_viewer roles"
        )
    if request.role != "super_admin" and not request.company_id:
        raise HTTPException(
            status_code=400, detail="company_id is required for company_admin and company_viewer roles"
        )

    # Validate country exists
    if request.country_id:
        country = db.query(Country).filter(Country.id == request.country_id).first()
        if not country:
            raise HTTPException(status_code=400, detail="Country not found")

    # Validate company exists
    if request.company_id:
        from ...models import Company

        company = db.query(Company).filter(Company.id == request.company_id).first()
        if not company:
            raise HTTPException(status_code=400, detail="Company not found")
```

Add `company_id: int | None = None` to `UserCreateRequest` and `UserUpdateRequest`, and `company_id: int | None = None` to `UserOut`. Update the `User(...)` construction in `create_user` to pass `company_id=request.company_id if request.role != "super_admin" else None`, and add the equivalent `if request.company_id is not None:` validate-and-assign block to `update_user`, mirroring the existing `country_id` block exactly.

- [ ] **Step 8: Run tests to verify they pass**

```bash
poetry run pytest tests/api/test_company_scoping_existing_routers.py -v --no-cov
```
Expected: all PASS.

- [ ] **Step 9: Run the full API + auth + users + companies test suite**

```bash
poetry run pytest tests/api/ tests/test_migrations.py -v --no-cov
```
Expected: all PASS, no regressions from Tasks 1-3.

- [ ] **Step 10: Commit**

```bash
git add src/tenderai_bf/api/dependencies.py src/tenderai_bf/api/routers/recipients.py src/tenderai_bf/api/routers/runs.py src/tenderai_bf/api/routers/reports.py src/tenderai_bf/api/routers/sources.py src/tenderai_bf/api/routers/users.py src/tenderai_bf/api/routers/countries.py tests/api/test_company_scoping_existing_routers.py
git commit -m "$(cat <<'EOF'
feat(api): scope recipients/runs/reports/sources/users by company_id

Removes the three YULCOM-hardcoded stopgaps (countries.py, runs.py,
recipients.py) now that company_id flows through the JWT. Manual
harvest triggers now support explicit company selection via a
company_id param, with a YULCOM fallback for super_admin when omitted
(new resolve_delivery_company_id helper) — preserves today's default
"Lancer maintenant" behavior instead of silently dropping delivery for
super_admin, which a naive stopgap removal would have caused. Adds
company_id filtering to recipient/run/report listings, enforces
read-only sources.py for non-super_admin, and requires company_id when
creating company_admin/company_viewer users (mirrors the existing
country_id requirement).
EOF
)"
```

---

### Task 5: End-to-end cross-company isolation verification

**Files:**
- Test: `tests/api/test_multi_company_isolation_e2e.py` (new)

**Interfaces:**
- Consumes: everything from Tasks 1-4. This task adds no production code — it's the plan's confirmed "second test company" verification, exercising the full stack together rather than one router at a time.

- [ ] **Step 1: Write the end-to-end isolation test**

```python
"""End-to-end verification that two companies are fully isolated from each
other across the surfaces this plan touches: settings, recipients, runs,
and company management itself. Exercises real login + real JWTs + real
DB queries across two independently seeded companies (YULCOM and a
throwaway 'test-co'), per this plan's Global Constraints."""
import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from tenderai_bf.api.dependencies import get_password_hash
from tenderai_bf.api.main import app
from tenderai_bf.db import get_db
from tenderai_bf.models import Base, Company, Country, Recipient, User


@pytest.fixture(scope="function")
def db_engine():
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    yield engine
    Base.metadata.drop_all(engine)


@pytest.fixture(scope="function")
def db_session(db_engine):
    Session = sessionmaker(bind=db_engine)
    session = Session()
    yield session
    session.close()


@pytest.fixture(scope="function")
def client(db_session):
    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.clear()


def _login(client, username, password):
    resp = client.post(
        "/api/v1/admin/login/simple", json={"username": username, "password": password}
    )
    assert resp.status_code == 200
    return resp.json()["access_token"]


@pytest.fixture
def two_isolated_companies(client, db_session):
    """Seeds YULCOM and test-co, each with a country subscription, settings,
    a company_admin user, and a recipient — the full shape this plan's
    scoping logic needs to actually exercise isolation, not just assert it."""
    yulcom = Company(name="YULCOM Technologies", slug="yulcom", active=True)
    test_co = Company(name="Test Co", slug="test-co", active=True)
    bf = Country(name="Burkina Faso", code="BF", locale="fr")
    ca = Country(name="Canada", code="CA", locale="fr")
    db_session.add_all([yulcom, test_co, bf, ca])
    db_session.commit()

    root = User(
        id=str(uuid.uuid4()),
        username="root",
        email="root@test.com",
        hashed_password=get_password_hash("rootpass123"),
        role="super_admin",
        is_active=True,
        password_reset_required=False,
    )
    yulcom_admin = User(
        id=str(uuid.uuid4()),
        username="yulcom_admin",
        email="yulcom_admin@test.com",
        hashed_password=get_password_hash("pass12345"),
        role="company_admin",
        company_id=yulcom.id,
        is_active=True,
        password_reset_required=False,
    )
    testco_admin = User(
        id=str(uuid.uuid4()),
        username="testco_admin",
        email="testco_admin@test.com",
        hashed_password=get_password_hash("pass12345"),
        role="company_admin",
        company_id=test_co.id,
        is_active=True,
        password_reset_required=False,
    )
    db_session.add_all([root, yulcom_admin, testco_admin])
    db_session.add_all(
        [
            Recipient(
                email="yulcom-recipient@test.com",
                group="to",
                enabled=True,
                company_id=yulcom.id,
                country_id=bf.id,
            ),
            Recipient(
                email="testco-recipient@test.com",
                group="to",
                enabled=True,
                company_id=test_co.id,
                country_id=ca.id,
            ),
        ]
    )
    db_session.commit()

    root_token = _login(client, "root", "rootpass123")
    client.post(
        f"/api/v1/admin/companies/{yulcom.id}/countries",
        json={"country_id": bf.id},
        headers={"Authorization": f"Bearer {root_token}"},
    )
    client.post(
        f"/api/v1/admin/companies/{test_co.id}/countries",
        json={"country_id": ca.id},
        headers={"Authorization": f"Bearer {root_token}"},
    )

    return {
        "yulcom": yulcom,
        "test_co": test_co,
        "root_token": root_token,
        "yulcom_token": _login(client, "yulcom_admin", "pass12345"),
        "testco_token": _login(client, "testco_admin", "pass12345"),
    }


def test_company_admin_sees_only_own_recipients(client, two_isolated_companies):
    resp = client.get(
        "/api/v1/recipients",
        headers={"Authorization": f"Bearer {two_isolated_companies['yulcom_token']}"},
    )
    assert resp.status_code == 200
    emails = {r["email"] for r in resp.json()["recipients"]}
    assert emails == {"yulcom-recipient@test.com"}

    resp = client.get(
        "/api/v1/recipients",
        headers={"Authorization": f"Bearer {two_isolated_companies['testco_token']}"},
    )
    assert resp.status_code == 200
    emails = {r["email"] for r in resp.json()["recipients"]}
    assert emails == {"testco-recipient@test.com"}


def test_company_admin_cannot_access_other_companys_country_subscriptions(
    client, two_isolated_companies
):
    resp = client.get(
        f"/api/v1/admin/companies/{two_isolated_companies['test_co'].id}/countries",
        headers={"Authorization": f"Bearer {two_isolated_companies['yulcom_token']}"},
    )
    assert resp.status_code == 403


def test_super_admin_sees_both_companies(client, two_isolated_companies):
    resp = client.get(
        "/api/v1/admin/companies",
        headers={"Authorization": f"Bearer {two_isolated_companies['root_token']}"},
    )
    assert resp.status_code == 200
    slugs = {c["slug"] for c in resp.json()}
    assert slugs == {"yulcom", "test-co"}


def test_super_admin_sees_all_recipients_unfiltered(client, two_isolated_companies):
    resp = client.get(
        "/api/v1/recipients",
        headers={"Authorization": f"Bearer {two_isolated_companies['root_token']}"},
    )
    assert resp.status_code == 200
    emails = {r["email"] for r in resp.json()["recipients"]}
    assert emails == {"yulcom-recipient@test.com", "testco-recipient@test.com"}
```

- [ ] **Step 2: Run the test**

```bash
poetry run pytest tests/api/test_multi_company_isolation_e2e.py -v --no-cov
```
Expected: all PASS. If any fail, the bug is in Tasks 1-4's scoping logic, not this test — go back and fix the relevant router, do not weaken this test's assertions to make it pass.

- [ ] **Step 3: Run the complete test suite one final time**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```
Expected: all PASS.

```bash
poetry run ruff check src tests
poetry run ruff format --check src tests
```
Expected: clean (or only the pre-existing violations documented elsewhere in this repo's history — do not introduce new ones).

- [ ] **Step 4: Commit**

```bash
git add tests/api/test_multi_company_isolation_e2e.py
git commit -m "$(cat <<'EOF'
test: add end-to-end multi-company isolation verification

Seeds two fully independent companies (YULCOM + throwaway test-co)
with their own country subscriptions, users, and recipients, and
verifies company_admin scoping actually isolates them across
recipients, company management, and country subscriptions — while
super_admin retains unrestricted cross-company visibility. Confirms
Tasks 1-4's scoping logic end-to-end rather than router-by-router.
EOF
)"
```

---

## Self-Review Notes

**Spec coverage:** JWT `company_id` claim (Task 2) ✅. Role rename (Task 1) ✅. `CompanyScopedUser` dependency (Task 2) ✅. `companies.py` router — all 9 endpoints listed in spec Section 3 (Task 3) ✅. `recipients.py`/`runs.py`/`reports.py`/`sources.py`/`users.py` scoping table (Task 4) ✅. Three YULCOM stopgaps removed — `countries.py`, `runs.py`, `recipients.py` (Task 4) ✅. Second test company for isolation testing (Task 5, per the user's confirmed decision) ✅.

**Explicitly not covered by this plan** (confirmed out of scope): Section 4 (frontend — `CompanyContext`, `/companies` page, sidebar nav, proxy route) is a separate future plan. `sources.py`'s spec-mentioned "scoped to their subscribed countries" (beyond plain read-only) is not implemented — the spec says company_admin/viewer get read-only sources, but doesn't specify filtering the *list* by their company's subscriptions the way `recipients`/`runs` are filtered; Task 4 Step 6 implements the read-only part only. If country-subscription-filtered source lists turn out to be required, that's a gap to raise with the user before or during execution, not something to silently add or silently skip.

**Revision (2026-08-29, coordinator review before user hand-off):** Task 4's original draft removed the three YULCOM stopgaps by simply substituting `current_user["company_id"]` for the hardcoded lookup — but the live admin account is `super_admin`, whose `company_id` is always `None`, so that substitution would have silently broken the "Lancer maintenant" button's email delivery, which is exactly the regression the original stopgap comments ("Stopgap until the Auth/API plan adds company selection...") were written to avoid. Fixed by adding a `resolve_delivery_company_id` helper and an explicit `company_id` param to both manual-trigger endpoints, with a YULCOM fallback for `super_admin` when no company is specified — this actually delivers the "company selection" capability the stopgap comments called for, not just a stopgap removal. Confirmed with the user before finalizing (chose "add explicit company selection" over "accept the regression").

**Second revision (2026-08-29, same review pass, caught by running the baseline test suite before dispatching Task 1):** the identical regression pattern was found in `recipients.py`'s `create_recipient` — a pre-existing, currently-passing test (`test_recipients_endpoints.py::test_create_recipient_defaults_to_yulcom_company`) creates a recipient as `super_admin` and asserts it lands on YULCOM. This test wasn't in the original Task 4 file list and the original `create_recipient` fix (`company_id=user.get("company_id")`) would have broken it the same way. Fixed by routing `create_recipient` through the same `resolve_delivery_company_id` helper (Task 4 Step 3). Also confirmed `test_countries_run_trigger.py`'s existing test continues to pass unmodified under the `countries.py` fix — its `get_db_context` mock becomes vestigial (the new code resolves the target company synchronously against the request-scoped session instead) but harmless.

**Open question for the user, not resolved by the spec or codebase exploration:** `ClassificationSettingsSchema` (used by both `countries.py` and this plan's new `companies.py` settings endpoint) only declares `relevant_keywords` — it does not declare `min_relevance_score`, even though migration `0013`'s seed step explicitly merges `min_relevance_score` into the company-level `classification` section. Whether this silently passes through today (Pydantic's default `extra` behavior needs checking against this specific `BaseModel`'s config) or was already a pre-existing gap in the country-level settings endpoint is not something this plan's exploration resolved, and it's identical pre-existing behavior either way — not a regression this plan introduces. Flag to the user; do not fix speculatively inside this plan.
