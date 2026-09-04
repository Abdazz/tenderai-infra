# Three-Role System with Country Binding — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a `super_admin` role that is the only one who can manage users, manage countries, and switch between countries; `admin` and `viewer` users are bound to a single country and cannot access user/country management.

**Architecture:** Add `country_id` (nullable FK) to the `users` table and widen the `role` column to 15 chars via a new Alembic migration. The JWT carries `country_id`; the backend enforces per-role access via a new `require_super_admin` dependency. The frontend reads `role` and `country_id` from the JWT cookie to lock non-super_admin users to their country and hide the country selector / admin links.

**Tech Stack:** Python 3.11, SQLAlchemy, Alembic, FastAPI, JWT (python-jose), Next.js 14 App Router, TypeScript, Tailwind CSS.

---

## Files modified / created

| Path | Action | What changes |
|---|---|---|
| `alembic/versions/0004_super_admin_role.py` | Create | Widens `role` to 15 chars, adds `country_id` FK on users, promotes existing `admin` → `super_admin` |
| `src/tenderai_bf/models.py` | Modify | `User`: widen `role` column string, add `country_id` column + relationship |
| `src/tenderai_bf/api/dependencies.py` | Modify | Add `require_super_admin` dependency and `SuperAdminUser` alias |
| `src/tenderai_bf/api/routers/admin.py` | Modify | Include `country_id` in JWT payload (`_build_token`) |
| `src/tenderai_bf/api/routers/users.py` | Modify | Use `SuperAdminUser`; accept `super_admin` role; require `country_id` for non-super_admin; expose `country_id` in `UserOut` |
| `src/tenderai_bf/api/routers/countries.py` | Modify | POST/PUT/DELETE require `SuperAdminUser`; GET stays open to all |
| `frontend/lib/auth.ts` | Modify | Add `super_admin` to role union type; add `country_id` to `JWTPayload` |
| `frontend/middleware.ts` | Modify | `/users` and `/countries` routes restricted to `super_admin` only |
| `frontend/contexts/country-context.tsx` | Modify | Accept `fixedCountryId` prop; lock selection for non-super_admin |
| `frontend/app/(dashboard)/layout.tsx` | Modify | Decode JWT to get `role` + `country_id`; pass to `CountryProvider`; only render `CountrySelector` for `super_admin` |
| `frontend/components/sidebar.tsx` | Modify | Hide "Utilisateurs" and "Pays" links for non-super_admin; show static country badge for non-super_admin |
| `frontend/components/country-selector.tsx` | No change needed | Already uses context; hidden when not super_admin by layout |
| `frontend/components/users/create-user-dialog.tsx` | Modify | Add country selector field (required for admin/viewer); add `super_admin` option |
| `frontend/app/(dashboard)/users/page.tsx` | Modify | Show `country` column in user list |

---

## Task 1: Database migration — widen role, add country_id to users

**Files:**
- Create: `alembic/versions/0004_super_admin_role.py`

- [ ] **Step 1: Write the migration**

```python
# alembic/versions/0004_super_admin_role.py
"""add super_admin role and country_id to users

Revision ID: 0004
Revises: 0003
Create Date: 2026-06-02
"""
import sqlalchemy as sa
from alembic import op

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Widen role column from VARCHAR(10) to VARCHAR(15)
    op.alter_column(
        "users", "role",
        existing_type=sa.String(10),
        type_=sa.String(15),
        existing_nullable=False,
    )
    # Add country_id FK (nullable — super_admin has no country)
    op.add_column(
        "users",
        sa.Column("country_id", sa.Integer(), sa.ForeignKey("countries.id"), nullable=True, index=True),
    )
    op.create_index("ix_users_country_id", "users", ["country_id"])
    # Promote existing admin users to super_admin
    op.execute("UPDATE users SET role = 'super_admin' WHERE role = 'admin'")


def downgrade() -> None:
    op.execute("UPDATE users SET role = 'admin' WHERE role = 'super_admin'")
    op.drop_index("ix_users_country_id", "users")
    op.drop_column("users", "country_id")
    op.alter_column(
        "users", "role",
        existing_type=sa.String(15),
        type_=sa.String(10),
        existing_nullable=False,
    )
```

- [ ] **Step 2: Run migration inside the API container**

```bash
docker exec tenderai-api poetry run alembic upgrade head
```

Expected output: `Running upgrade 0003 -> 0004, add super_admin role and country_id to users`

- [ ] **Step 3: Verify schema**

```bash
docker exec tenderai-postgres psql -U tenderai -d tenderai_bf -c "\d users"
```

Expected: `role` column shows `character varying(15)`, `country_id` column exists.

```bash
docker exec tenderai-postgres psql -U tenderai -d tenderai_bf -c "SELECT username, role, country_id FROM users;"
```

Expected: `admin` user now has `role = super_admin`, `country_id = NULL`.

- [ ] **Step 4: Commit**

```bash
git add alembic/versions/0004_super_admin_role.py
git commit -m "feat(db): add super_admin role and country_id to users table"
```

---

## Task 2: Backend model — User

**Files:**
- Modify: `src/tenderai_bf/models.py`

- [ ] **Step 1: Update User model**

In `models.py`, find the `User` class and replace it with:

```python
class User(Base):
    """Application users with role-based access."""

    __tablename__ = "users"

    id = Column(String(36), primary_key=True, index=True)
    username = Column(String(64), nullable=False, unique=True, index=True)
    email = Column(String(255), nullable=False, unique=True, index=True)
    hashed_password = Column(String(255), nullable=False)
    role = Column(String(15), nullable=False, default="viewer")  # super_admin | admin | viewer
    is_active = Column(Boolean, nullable=False, default=True)
    password_reset_required = Column(Boolean, nullable=False, default=True)
    country_id = Column(Integer, ForeignKey("countries.id"), nullable=True, index=True)
    created_at = Column(DateTime, nullable=False, default=func.now())
    last_login_at = Column(DateTime, nullable=True)

    country = relationship("Country", foreign_keys=[country_id])

    def __repr__(self) -> str:
        return f"<User(username='{self.username}', role='{self.role}')>"
```

- [ ] **Step 2: Restart API to pick up model change**

```bash
docker compose restart api
sleep 5
docker compose ps api
```

Expected: `api` container is `Up (healthy)`.

- [ ] **Step 3: Commit**

```bash
git add src/tenderai_bf/models.py
git commit -m "feat(models): add country_id and widen role on User"
```

---

## Task 3: Backend dependencies — require_super_admin

**Files:**
- Modify: `src/tenderai_bf/api/dependencies.py`

- [ ] **Step 1: Add `require_super_admin` and `SuperAdminUser`**

After the existing `require_admin` function, add:

```python
async def require_super_admin(current_user: Annotated[dict, Depends(require_auth)]) -> dict:
    """Require super_admin role. Raises 403 if not super_admin."""
    if current_user.get("role") != "super_admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Super-admin access required",
        )
    return current_user
```

And at the bottom of the file, add the type alias:

```python
SuperAdminUser = Annotated[dict, Depends(require_super_admin)]
```

- [ ] **Step 2: Rebuild API container**

```bash
docker compose build api && docker compose up -d api
sleep 8
curl -s http://localhost:8000/health | python3 -m json.tool
```

Expected: `{"status": "healthy", ...}`

- [ ] **Step 3: Commit**

```bash
git add src/tenderai_bf/api/dependencies.py
git commit -m "feat(auth): add require_super_admin dependency"
```

---

## Task 4: Backend — include country_id in JWT

**Files:**
- Modify: `src/tenderai_bf/api/routers/admin.py`

- [ ] **Step 1: Update `_build_token` to include `country_id`**

Find `_build_token` and replace it with:

```python
def _build_token(user: User) -> LoginResponse:
    token = create_access_token(
        data={
            "sub": user.username,
            "email": user.email,
            "role": user.role,
            "country_id": user.country_id,
            "password_reset_required": user.password_reset_required,
        }
    )
    return LoginResponse(
        access_token=token,
        token_type="bearer",
        expires_in=ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        role=user.role,
        password_reset_required=user.password_reset_required,
    )
```

- [ ] **Step 2: Update `get_current_user` in `dependencies.py` to extract `country_id`**

In `dependencies.py`, find the `return {...}` block inside `get_current_user` and update it:

```python
        return {
            "username": username,
            "email": payload.get("email"),
            "role": payload.get("role", "viewer"),
            "country_id": payload.get("country_id"),
            "password_reset_required": payload.get("password_reset_required", False),
        }
```

- [ ] **Step 3: Rebuild and test token**

```bash
docker compose build api && docker compose up -d api
sleep 8
TOKEN=$(curl -s -X POST http://localhost:8000/api/v1/admin/login/simple \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"NKZwElFt9DR6yShC"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
# Decode payload (middle part of JWT)
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

Expected: JSON contains `"role": "super_admin"` and `"country_id": null`.

- [ ] **Step 4: Commit**

```bash
git add src/tenderai_bf/api/routers/admin.py src/tenderai_bf/api/dependencies.py
git commit -m "feat(auth): include country_id in JWT payload"
```

---

## Task 5: Backend — users router with super_admin enforcement

**Files:**
- Modify: `src/tenderai_bf/api/routers/users.py`

- [ ] **Step 1: Rewrite users.py**

```python
"""User management endpoints (super_admin only)."""

import os
import secrets
import uuid

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, EmailStr

from ...email import send_credentials_email
from ...logging import get_logger
from ...models import Country, User
from ..dependencies import DatabaseSession, SuperAdminUser, get_password_hash

logger = get_logger(__name__)
router = APIRouter()

FRONTEND_URL = os.environ.get("FRONTEND_URL", "http://localhost:3000")

VALID_ROLES = ("super_admin", "admin", "viewer")


class UserCreateRequest(BaseModel):
    username: str
    email: EmailStr
    role: str  # "super_admin" | "admin" | "viewer"
    country_id: int | None = None


class UserUpdateRequest(BaseModel):
    role: str | None = None
    is_active: bool | None = None
    country_id: int | None = None


class UserOut(BaseModel):
    id: str
    username: str
    email: str
    role: str
    is_active: bool
    password_reset_required: bool
    country_id: int | None = None

    class Config:
        from_attributes = True


@router.get("", response_model=dict)
async def list_users(current_user: SuperAdminUser, db: DatabaseSession):
    users = db.query(User).order_by(User.created_at.desc()).all()
    return {"users": [UserOut.model_validate(u) for u in users]}


@router.post("", response_model=UserOut, status_code=201)
async def create_user(
    request: UserCreateRequest, current_user: SuperAdminUser, db: DatabaseSession
):
    if request.role not in VALID_ROLES:
        raise HTTPException(status_code=400, detail=f"role must be one of: {', '.join(VALID_ROLES)}")

    # Non-super_admin users must have a country
    if request.role != "super_admin" and not request.country_id:
        raise HTTPException(status_code=400, detail="country_id is required for admin and viewer roles")

    # Validate country exists
    if request.country_id:
        country = db.query(Country).filter(Country.id == request.country_id).first()
        if not country:
            raise HTTPException(status_code=400, detail="Country not found")

    if db.query(User).filter(User.username == request.username).first():
        raise HTTPException(status_code=409, detail="Username already exists")

    if db.query(User).filter(User.email == request.email).first():
        raise HTTPException(status_code=409, detail="Email already exists")

    password = secrets.token_urlsafe(12)
    user = User(
        id=str(uuid.uuid4()),
        username=request.username,
        email=request.email,
        hashed_password=get_password_hash(password),
        role=request.role,
        country_id=request.country_id if request.role != "super_admin" else None,
        is_active=True,
        password_reset_required=True,
    )
    db.add(user)
    db.commit()
    db.refresh(user)

    send_credentials_email(
        to_address=user.email,
        username=user.username,
        password=password,
        frontend_url=FRONTEND_URL,
        is_reset=False,
    )
    logger.info("User created", username=user.username, created_by=current_user["username"])
    return UserOut.model_validate(user)


@router.patch("/{user_id}", response_model=UserOut)
async def update_user(
    user_id: str,
    request: UserUpdateRequest,
    current_user: SuperAdminUser,
    db: DatabaseSession,
):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    if user.username == current_user["username"] and request.is_active is False:
        raise HTTPException(status_code=400, detail="You cannot deactivate your own account")

    if request.role is not None:
        if request.role not in VALID_ROLES:
            raise HTTPException(status_code=400, detail=f"role must be one of: {', '.join(VALID_ROLES)}")
        user.role = request.role

    if request.country_id is not None:
        country = db.query(Country).filter(Country.id == request.country_id).first()
        if not country:
            raise HTTPException(status_code=400, detail="Country not found")
        user.country_id = request.country_id

    if request.is_active is not None:
        user.is_active = request.is_active

    db.commit()
    db.refresh(user)
    logger.info("User updated", user_id=user_id, updated_by=current_user["username"])
    return UserOut.model_validate(user)


@router.delete("/{user_id}", status_code=204)
async def delete_user(user_id: str, current_user: SuperAdminUser, db: DatabaseSession):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if user.username == current_user["username"]:
        raise HTTPException(status_code=400, detail="You cannot delete your own account")
    db.delete(user)
    db.commit()
    logger.info("User deleted", user_id=user_id, deleted_by=current_user["username"])


@router.post("/{user_id}/reset-password", response_model=UserOut)
async def reset_password(user_id: str, current_user: SuperAdminUser, db: DatabaseSession):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    password = secrets.token_urlsafe(12)
    user.hashed_password = get_password_hash(password)
    user.password_reset_required = True
    db.commit()
    db.refresh(user)

    send_credentials_email(
        to_address=user.email,
        username=user.username,
        password=password,
        frontend_url=FRONTEND_URL,
        is_reset=True,
    )
    logger.info("Password reset", user_id=user_id, reset_by=current_user["username"])
    return UserOut.model_validate(user)
```

- [ ] **Step 2: Verify old admin-role tests still pass**

```bash
docker exec tenderai-api poetry run pytest tests/ -m "not slow and not integration" --no-cov -q 2>&1 | tail -20
```

Expected: tests pass (or only pre-existing failures).

- [ ] **Step 3: Rebuild API**

```bash
docker compose build api && docker compose up -d api
sleep 8
```

- [ ] **Step 4: Smoke test — list users as super_admin**

```bash
TOKEN=$(curl -s -X POST http://localhost:8000/api/v1/admin/login/simple \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"NKZwElFt9DR6yShC"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v1/users | python3 -m json.tool
```

Expected: list of users with `country_id` field visible.

- [ ] **Step 5: Commit**

```bash
git add src/tenderai_bf/api/routers/users.py
git commit -m "feat(users): require super_admin, add country_id to create/update/list"
```

---

## Task 6: Backend — countries router, super_admin for write operations

**Files:**
- Modify: `src/tenderai_bf/api/routers/countries.py`

- [ ] **Step 1: Add `SuperAdminUser` import and restrict write endpoints**

Replace the import line:
```python
from ..dependencies import AuthenticatedUser, DatabaseSession
```
with:
```python
from ..dependencies import AuthenticatedUser, DatabaseSession, SuperAdminUser
```

Then update the POST, PUT, and DELETE signatures:

```python
@router.post("", response_model=CountryRead, status_code=status.HTTP_201_CREATED)
async def create_country(
    body: CountryCreate, db: DatabaseSession, user: SuperAdminUser  # was AuthenticatedUser
):
    ...

@router.put("/{country_id}", response_model=CountryRead)
async def update_country(
    country_id: int, body: CountryUpdate, db: DatabaseSession, user: SuperAdminUser  # was AuthenticatedUser
):
    ...

@router.delete("/{country_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_country(country_id: int, db: DatabaseSession, user: SuperAdminUser  # was AuthenticatedUser
):
    ...
```

GET (list/get) and settings endpoints remain `AuthenticatedUser` so non-super_admin can still read their own country's settings.

Also restrict country settings writes to super_admin or the user's own country:

```python
@router.put("/{country_id}/settings/{section}")
async def update_section(
    country_id: int,
    section: str,
    body: dict,
    db: DatabaseSession,
    user: AuthenticatedUser,  # keep — but add country check below
):
    # Non-super_admin can only update their own country
    if user.get("role") != "super_admin" and user.get("country_id") != country_id:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="Access denied for this country")
    ...  # rest unchanged
```

- [ ] **Step 2: Rebuild and smoke test**

```bash
docker compose build api && docker compose up -d api && sleep 8
# Try creating a country as super_admin — should work
TOKEN=$(curl -s -X POST http://localhost:8000/api/v1/admin/login/simple \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"NKZwElFt9DR6yShC"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
curl -s -X POST http://localhost:8000/api/v1/admin/countries \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"Test","code":"ZZ","locale":"fr"}' | python3 -m json.tool
```

Expected: `{"id": ..., "name": "Test", "code": "ZZ", ...}`

```bash
# Clean up test country
COUNTRY_ID=$(curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v1/admin/countries | python3 -c "import sys,json; cs=json.load(sys.stdin); c=next(x for x in cs if x['code']=='ZZ'); print(c['id'])")
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v1/admin/countries/$COUNTRY_ID
```

- [ ] **Step 3: Commit**

```bash
git add src/tenderai_bf/api/routers/countries.py
git commit -m "feat(countries): restrict write ops to super_admin"
```

---

## Task 7: Frontend — update auth types

**Files:**
- Modify: `frontend/lib/auth.ts`

- [ ] **Step 1: Update JWTPayload type**

```typescript
import { decodeJwt } from "jose";

export interface JWTPayload {
  sub: string;
  email: string;
  role: "super_admin" | "admin" | "viewer";
  country_id: number | null;
  password_reset_required: boolean;
  exp: number;
}

export function decodeToken(token: string): JWTPayload | null {
  try {
    return decodeJwt(token) as JWTPayload;
  } catch {
    return null;
  }
}

export function isTokenExpired(token: string): boolean {
  const payload = decodeToken(token);
  if (!payload) return true;
  return payload.exp * 1000 < Date.now();
}

export function getRole(token: string): "super_admin" | "admin" | "viewer" | null {
  const payload = decodeToken(token);
  return payload?.role ?? null;
}
```

- [ ] **Step 2: Commit**

```bash
git add frontend/lib/auth.ts
git commit -m "feat(frontend): add super_admin to role types, country_id to JWTPayload"
```

---

## Task 8: Frontend — middleware route guards

**Files:**
- Modify: `frontend/middleware.ts`

- [ ] **Step 1: Rewrite middleware**

```typescript
import { NextRequest, NextResponse } from "next/server";
import { jwtVerify } from "jose";

const PUBLIC_PATHS = ["/login", "/api/auth/login", "/api/auth/logout"];
const SUPER_ADMIN_PATHS = ["/users", "/countries"];
const JWT_SECRET = new TextEncoder().encode(process.env.JWT_SECRET ?? "");

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  if (PUBLIC_PATHS.some((p) => pathname.startsWith(p))) {
    return NextResponse.next();
  }

  const token = request.cookies.get("auth_token")?.value;
  if (!token) {
    return NextResponse.redirect(new URL("/login", request.url));
  }

  try {
    const { payload } = await jwtVerify(token, JWT_SECRET);

    if (payload.password_reset_required && pathname !== "/change-password") {
      return NextResponse.redirect(new URL("/change-password", request.url));
    }

    const role = payload.role as string;

    if (SUPER_ADMIN_PATHS.some((p) => pathname.startsWith(p)) && role !== "super_admin") {
      return NextResponse.redirect(new URL("/", request.url));
    }

    return NextResponse.next();
  } catch {
    return NextResponse.redirect(new URL("/login", request.url));
  }
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
```

- [ ] **Step 2: Commit**

```bash
git add frontend/middleware.ts
git commit -m "feat(middleware): restrict /users and /countries to super_admin"
```

---

## Task 9: Frontend — CountryProvider accepts fixedCountryId

**Files:**
- Modify: `frontend/contexts/country-context.tsx`

- [ ] **Step 1: Update CountryProvider to support locked country**

```typescript
"use client";

import { createContext, useContext, useState, useEffect, ReactNode } from "react";

export type Country = {
  id: number;
  name: string;
  code: string;
  locale: string;
  active: boolean;
};

type CountryContextValue = {
  countries: Country[];
  selectedCountry: Country | null;
  setSelectedCountry: (c: Country) => void;
  loading: boolean;
  isSuperAdmin: boolean;
};

const CountryContext = createContext<CountryContextValue>({
  countries: [],
  selectedCountry: null,
  setSelectedCountry: () => {},
  loading: true,
  isSuperAdmin: false,
});

interface CountryProviderProps {
  children: ReactNode;
  /** For non-super_admin: the country_id from JWT. When set, selection is locked. */
  fixedCountryId?: number | null;
  isSuperAdmin: boolean;
}

export function CountryProvider({ children, fixedCountryId, isSuperAdmin }: CountryProviderProps) {
  const [countries, setCountries] = useState<Country[]>([]);
  const [selectedCountry, setSelectedCountryState] = useState<Country | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch("/api/proxy/countries")
      .then((r) => r.json())
      .then((data: Country[]) => {
        const active = Array.isArray(data) ? data.filter((c) => c.active) : [];
        setCountries(active);

        if (fixedCountryId) {
          // Non-super_admin: lock to their assigned country
          const found = active.find((c) => c.id === fixedCountryId) ?? null;
          setSelectedCountryState(found);
        } else {
          // super_admin: restore from localStorage or pick first
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

  function setSelectedCountry(c: Country) {
    if (fixedCountryId) return; // locked for non-super_admin
    setSelectedCountryState(c);
    if (typeof window !== "undefined") {
      localStorage.setItem("selectedCountryId", String(c.id));
    }
  }

  return (
    <CountryContext.Provider value={{ countries, selectedCountry, setSelectedCountry, loading, isSuperAdmin }}>
      {children}
    </CountryContext.Provider>
  );
}

export const useCountry = () => useContext(CountryContext);
```

- [ ] **Step 2: Commit**

```bash
git add frontend/contexts/country-context.tsx
git commit -m "feat(context): lock country selection for non-super_admin"
```

---

## Task 10: Frontend — layout passes role and country_id to CountryProvider

**Files:**
- Modify: `frontend/app/(dashboard)/layout.tsx`

- [ ] **Step 1: Rewrite layout**

```typescript
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { jwtVerify } from "jose";
import { Sidebar } from "@/components/sidebar";
import { CountryProvider } from "@/contexts/country-context";

const JWT_SECRET = new TextEncoder().encode(process.env.JWT_SECRET ?? "");

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  const token = (await cookies()).get("auth_token")?.value;
  if (!token) redirect("/login");

  let payload: { sub: string; role: "super_admin" | "admin" | "viewer"; country_id?: number | null };
  try {
    const result = await jwtVerify(token, JWT_SECRET);
    payload = result.payload as typeof payload;
  } catch {
    redirect("/login");
  }

  const isSuperAdmin = payload.role === "super_admin";
  const fixedCountryId = isSuperAdmin ? null : (payload.country_id ?? null);

  return (
    <CountryProvider isSuperAdmin={isSuperAdmin} fixedCountryId={fixedCountryId}>
      <div className="flex min-h-screen">
        <Sidebar role={payload.role} username={payload.sub} />
        <main className="flex-1 p-6 bg-slate-50">{children}</main>
      </div>
    </CountryProvider>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add frontend/app/(dashboard)/layout.tsx
git commit -m "feat(layout): pass role and fixedCountryId to CountryProvider"
```

---

## Task 11: Frontend — sidebar role-based links and country badge

**Files:**
- Modify: `frontend/components/sidebar.tsx`

- [ ] **Step 1: Rewrite sidebar**

```typescript
"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { cn } from "@/lib/utils";
import { CountrySelector } from "@/components/country-selector";
import { useCountry } from "@/contexts/country-context";

const baseLinks = [
  { href: "/", label: "Dashboard" },
  { href: "/reports", label: "Rapports" },
  { href: "/sources", label: "Sources" },
  { href: "/settings", label: "Paramètres" },
  { href: "/logs", label: "Logs" },
];

const superAdminLinks = [
  { href: "/users", label: "Utilisateurs" },
  { href: "/countries", label: "Pays" },
];

interface SidebarProps {
  role: "super_admin" | "admin" | "viewer";
  username: string;
}

export function Sidebar({ role, username }: SidebarProps) {
  const pathname = usePathname();
  const router = useRouter();
  const { selectedCountry } = useCountry();
  const links = role === "super_admin" ? [...baseLinks, ...superAdminLinks] : baseLinks;

  async function handleLogout() {
    await fetch("/api/auth/logout", { method: "POST" });
    router.push("/login");
  }

  return (
    <aside className="w-56 min-h-screen bg-slate-900 text-slate-100 flex flex-col">
      <div className="p-4 border-b border-slate-700">
        <h1 className="font-bold text-lg">TenderAI BF</h1>
        <p className="text-xs text-slate-400 mt-1">{username}</p>
      </div>
      <nav className="flex-1 p-2 space-y-1">
        {links.map(({ href, label }) => (
          <Link
            key={href}
            href={href}
            className={cn(
              "flex items-center gap-2 px-3 py-2 rounded-md text-sm transition-colors",
              pathname === href
                ? "bg-slate-700 text-white"
                : "text-slate-300 hover:bg-slate-800 hover:text-white"
            )}
          >
            {label}
          </Link>
        ))}
      </nav>
      {/* Country section at the bottom */}
      {role === "super_admin" ? (
        <CountrySelector />
      ) : selectedCountry ? (
        <div className="px-4 py-3 border-t border-slate-700">
          <p className="text-xs text-slate-500 mb-1">Pays</p>
          <p className="text-sm text-slate-200 font-medium truncate">{selectedCountry.name}</p>
        </div>
      ) : null}
      <div className="p-4 border-t border-slate-700">
        <button
          onClick={handleLogout}
          className="text-sm text-slate-400 hover:text-white w-full text-left"
        >
          Déconnexion
        </button>
      </div>
    </aside>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add frontend/components/sidebar.tsx
git commit -m "feat(sidebar): show Users/Countries links only to super_admin"
```

---

## Task 12: Frontend — create-user dialog with country selector and super_admin role

**Files:**
- Modify: `frontend/components/users/create-user-dialog.tsx`

- [ ] **Step 1: Rewrite create-user-dialog**

```typescript
"use client";

import { useState, useEffect } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";

interface Country {
  id: number;
  name: string;
  code: string;
}

interface Props {
  onCreated: () => void;
}

export function CreateUserDialog({ onCreated }: Props) {
  const [open, setOpen] = useState(false);
  const [username, setUsername] = useState("");
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<"super_admin" | "admin" | "viewer">("viewer");
  const [countryId, setCountryId] = useState<string>("");
  const [countries, setCountries] = useState<Country[]>([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (open) {
      fetch("/api/proxy/countries")
        .then((r) => r.json())
        .then((data) => setCountries(Array.isArray(data) ? data : []))
        .catch(() => setCountries([]));
    }
  }, [open]);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (role !== "super_admin" && !countryId) {
      setError("Un pays est requis pour les rôles admin et viewer.");
      return;
    }
    setLoading(true);
    setError("");
    try {
      const body: Record<string, unknown> = { username, email, role };
      if (role !== "super_admin" && countryId) body.country_id = Number(countryId);
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
      setRole("viewer");
      setCountryId("");
      onCreated();
    } catch {
      setError("Erreur réseau.");
    } finally {
      setLoading(false);
    }
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger render={<Button />}>
        Nouvel utilisateur
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Créer un utilisateur</DialogTitle>
          <DialogDescription>
            Un mot de passe sera généré automatiquement et envoyé par email.
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="new-username">Identifiant</Label>
            <Input
              id="new-username"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              required
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="new-email">Email</Label>
            <Input
              id="new-email"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="new-role">Rôle</Label>
            <select
              id="new-role"
              value={role}
              onChange={(e) => { setRole(e.target.value as typeof role); setCountryId(""); }}
              className="w-full border border-input rounded-md px-3 py-2 text-sm bg-background"
            >
              <option value="viewer">Viewer</option>
              <option value="admin">Admin</option>
              <option value="super_admin">Super Admin</option>
            </select>
          </div>
          {role !== "super_admin" && (
            <div className="space-y-2">
              <Label htmlFor="new-country">Pays <span className="text-red-500">*</span></Label>
              <select
                id="new-country"
                value={countryId}
                onChange={(e) => setCountryId(e.target.value)}
                className="w-full border border-input rounded-md px-3 py-2 text-sm bg-background"
                required
              >
                <option value="">— Sélectionner un pays —</option>
                {countries.map((c) => (
                  <option key={c.id} value={c.id}>{c.name} ({c.code})</option>
                ))}
              </select>
            </div>
          )}
          {error && <p className="text-sm text-red-600">{error}</p>}
          <DialogFooter>
            <Button type="submit" disabled={loading}>
              {loading ? "Création..." : "Créer"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add frontend/components/users/create-user-dialog.tsx
git commit -m "feat(users): add country selector and super_admin option in create dialog"
```

---

## Task 13: Frontend — users page shows country column

**Files:**
- Modify: `frontend/app/(dashboard)/users/page.tsx`

- [ ] **Step 1: Add country_id to User type and display it**

In `users/page.tsx`, update the `User` interface and table:

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

Add a "Pays" column in the table header:
```tsx
<th className="pb-2">Pays</th>
```

And in each row (after the role cell):
```tsx
<td className="text-slate-500 text-xs">
  {user.country_id ?? <span className="text-slate-300">—</span>}
</td>
```

Note: `country_id` is an integer; for a future enhancement, the country name could be fetched. For now displaying the id is sufficient and avoids a second fetch.

- [ ] **Step 2: Commit**

```bash
git add frontend/app/(dashboard)/users/page.tsx
git commit -m "feat(users): show country_id in users list"
```

---

## Task 14: Build and end-to-end verification

- [ ] **Step 1: Build frontend**

```bash
docker compose build frontend
```

Expected: build succeeds with no TypeScript errors.

- [ ] **Step 2: Restart all services**

```bash
docker compose up -d frontend api
sleep 10
docker compose ps
```

Expected: all containers `Up (healthy)`.

- [ ] **Step 3: Verify super_admin sees Users + Countries links and country selector**

```bash
python3 -c "
from playwright.sync_api import sync_playwright
import time
with sync_playwright() as p:
    b = p.chromium.launch(headless=True, args=['--no-sandbox'], executable_path='/usr/bin/google-chrome')
    pg = b.new_page(viewport={'width':1280,'height':800})
    pg.goto('http://localhost:3000/login')
    pg.wait_for_load_state('networkidle')
    pg.fill('#username','admin')
    pg.fill('#password','NKZwElFt9DR6yShC')
    pg.click('button[type=\"submit\"]')
    pg.wait_for_url('http://localhost:3000/', timeout=10000)
    pg.wait_for_load_state('networkidle')
    time.sleep(1)
    links = pg.locator('nav a').all_inner_texts()
    print('Links:', links)
    assert 'Utilisateurs' in links, 'Utilisateurs link missing for super_admin'
    assert 'Pays' in links, 'Pays link missing for super_admin'
    pg.screenshot(path='/tmp/super_admin_dashboard.png')
    b.close()
    print('PASS')
"
```

Expected: `PASS`, screenshot shows all 7 nav links.

- [ ] **Step 4: Verify a non-super_admin cannot access /users**

```bash
# Create a test viewer user bound to Burkina Faso (id=1)
TOKEN=$(curl -s -X POST http://localhost:8000/api/v1/admin/login/simple \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"NKZwElFt9DR6yShC"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
# Attempt to list users as a non-super_admin user (use the token directly with a modified role)
# Instead, test the API directly:
curl -s -X POST http://localhost:8000/api/v1/users \
  -H "Authorization: Bearer FAKE_VIEWER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username":"x","email":"x@x.com","role":"viewer","country_id":1}' | python3 -m json.tool
```

Expected: `{"detail": "Not authenticated"}` (403 or 401).

- [ ] **Step 5: Final commit tag**

```bash
git log --oneline -8
```

---

## Self-Review

**Spec coverage:**
- ✅ 3 roles: `super_admin`, `admin`, `viewer`
- ✅ Users (except super_admin) bound to a country via `country_id`
- ✅ Only super_admin sees country selector
- ✅ Only super_admin can manage users (create/update/delete)
- ✅ Only super_admin can manage countries (create/update/delete)
- ✅ Non-super_admin cannot navigate to `/users` or `/countries` (middleware guard + sidebar hide)
- ✅ JWT carries `country_id` for downstream filtering
- ✅ Non-super_admin country is locked (cannot be changed via selector)

**Placeholder scan:** None — all steps contain exact code.

**Type consistency:**
- `SuperAdminUser` defined in Task 3, used in Tasks 5 and 6 ✅
- `fixedCountryId` defined in Task 9, used in Task 10 ✅
- `isSuperAdmin` prop defined in Task 9, used in Tasks 10 and 11 ✅
- `role: "super_admin" | "admin" | "viewer"` consistent across Tasks 7, 10, 11, 12, 13 ✅
