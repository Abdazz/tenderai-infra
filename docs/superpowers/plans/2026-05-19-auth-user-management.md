# Auth & User Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Gradio UI with Next.js and implement a full authentication + two-role user management system (admin/viewer) with auto-generated passwords sent by email.

**Architecture:** FastAPI backend gains a `users` PostgreSQL table (Alembic migration), new CRUD endpoints under `/api/v1/users`, and updated JWT payloads that include `role`. A new Next.js 14 (App Router) frontend replaces Gradio: it stores JWT in an httpOnly cookie via a route handler, enforces role-based access via Next.js middleware, and includes a dedicated Users admin page. Docker replaces the `ui` (Gradio) container with a `frontend` (Next.js) container; Nginx is updated accordingly.

**Tech Stack:** Python 3.11, FastAPI, SQLAlchemy, `python-jose`, `passlib[bcrypt]`, `secrets` (backend) — Next.js 14 App Router, TypeScript, shadcn/ui, Tailwind CSS (frontend) — PostgreSQL, Alembic, Docker, Nginx.

**Spec:** `docs/superpowers/specs/2026-05-19-auth-user-management-design.md`

---

## File Map

### Backend (created / modified)
| Path | Action | Responsibility |
|---|---|---|
| `src/tenderai_bf/models.py` | Modify | Add `User` model + `UserRole` enum string |
| `alembic/versions/<rev>_add_users_table.py` | Create | Migration: users table + seed admin |
| `src/tenderai_bf/api/dependencies.py` | Modify | Add `role` to JWT, add `RequireAdmin` |
| `src/tenderai_bf/api/routers/admin.py` | Modify | Auth against DB, remove hardcoded dict, add `change-password` |
| `src/tenderai_bf/api/routers/users.py` | Create | CRUD endpoints for user management |
| `src/tenderai_bf/api/main.py` | Modify | Register users router |
| `src/tenderai_bf/email/__init__.py` | Modify | Add `send_credentials_email()` |
| `tests/api/test_auth.py` | Create | Auth endpoint tests |
| `tests/api/test_users.py` | Create | User CRUD tests |

### Frontend (new directory)
| Path | Action | Responsibility |
|---|---|---|
| `frontend/` | Create | Next.js project root |
| `frontend/middleware.ts` | Create | JWT cookie validation on every protected route |
| `frontend/lib/api.ts` | Create | Typed fetch wrapper for FastAPI calls |
| `frontend/lib/auth.ts` | Create | Token decode + role helpers |
| `frontend/app/api/auth/login/route.ts` | Create | Server route: calls FastAPI, sets httpOnly cookie |
| `frontend/app/api/auth/logout/route.ts` | Create | Server route: clears cookie |
| `frontend/app/(auth)/login/page.tsx` | Create | Login page |
| `frontend/app/(auth)/change-password/page.tsx` | Create | Forced password change page |
| `frontend/app/(dashboard)/layout.tsx` | Create | Sidebar + auth guard |
| `frontend/app/(dashboard)/page.tsx` | Create | Dashboard: status + recent runs |
| `frontend/app/(dashboard)/reports/page.tsx` | Create | Reports list + download |
| `frontend/app/(dashboard)/sources/page.tsx` | Create | Active sources table |
| `frontend/app/(dashboard)/settings/page.tsx` | Create | Config display |
| `frontend/app/(dashboard)/logs/page.tsx` | Create | Log viewer |
| `frontend/app/(dashboard)/users/page.tsx` | Create | User management (admin only) |
| `frontend/components/sidebar.tsx` | Create | Navigation sidebar filtered by role |
| `frontend/components/users/create-user-dialog.tsx` | Create | Create user form dialog |
| `frontend/components/data-table.tsx` | Create | Reusable table component |

### Infrastructure (modified)
| Path | Action | Responsibility |
|---|---|---|
| `infra/Dockerfile.frontend` | Create | Next.js container build |
| `docker-compose.yml` | Modify | Remove `ui`, add `frontend` |
| `docker-compose.override.prod.yml` | Modify | Production frontend image |
| `docker-compose.override.dev.yml` | Modify | Dev frontend with hot reload |
| `infra/nginx/nginx.conf` | Modify | Proxy `/` to `frontend:3000` instead of `ui:7860` |

---

## Phase 1 — User Model & Migration

### Task 1: Add User model

**Files:**
- Modify: `src/tenderai_bf/models.py`
- Create: `tests/api/test_auth.py`

- [ ] **Step 1: Add User model to models.py**

Append at the end of `src/tenderai_bf/models.py`:

```python
class User(Base):
    """Application users with role-based access."""

    __tablename__ = "users"

    id = Column(String(36), primary_key=True, index=True)  # UUID
    username = Column(String(64), nullable=False, unique=True, index=True)
    email = Column(String(255), nullable=False, unique=True, index=True)
    hashed_password = Column(String(255), nullable=False)
    role = Column(String(10), nullable=False, default="viewer")  # "admin" | "viewer"
    is_active = Column(Boolean, nullable=False, default=True)
    password_reset_required = Column(Boolean, nullable=False, default=True)
    created_at = Column(DateTime, nullable=False, default=func.now())
    last_login_at = Column(DateTime, nullable=True)

    def __repr__(self) -> str:
        return f"<User(username='{self.username}', role='{self.role}')>"
```

- [ ] **Step 2: Write failing test for User model**

Create `tests/api/__init__.py` (empty) and `tests/api/test_auth.py`:

```python
"""Tests for auth endpoints."""
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from tenderai_bf.models import User, Base


@pytest.fixture(scope="function")
def db_session():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    Session = sessionmaker(bind=engine)
    session = Session()
    yield session
    session.close()
    Base.metadata.drop_all(engine)


def test_user_model_creation(db_session):
    user = User(
        id="test-uuid-1234",
        username="testuser",
        email="test@example.com",
        hashed_password="hashed",
        role="viewer",
    )
    db_session.add(user)
    db_session.commit()

    fetched = db_session.query(User).filter_by(username="testuser").first()
    assert fetched is not None
    assert fetched.role == "viewer"
    assert fetched.is_active is True
    assert fetched.password_reset_required is True


def test_user_role_admin(db_session):
    user = User(
        id="test-uuid-5678",
        username="adminuser",
        email="admin@example.com",
        hashed_password="hashed",
        role="admin",
    )
    db_session.add(user)
    db_session.commit()

    fetched = db_session.query(User).filter_by(username="adminuser").first()
    assert fetched.role == "admin"
```

- [ ] **Step 3: Run test to verify it fails**

```bash
poetry run pytest tests/api/test_auth.py -v --no-cov
```

Expected: FAIL — `User` not yet imported or table doesn't exist in SQLite.

- [ ] **Step 4: Run test to verify it passes**

After saving the model:

```bash
poetry run pytest tests/api/test_auth.py -v --no-cov
```

Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add src/tenderai_bf/models.py tests/api/__init__.py tests/api/test_auth.py
git commit -m "feat: add User model with role-based access"
```

---

### Task 2: Create Alembic migration and seed admin

**Files:**
- Create: `alembic/versions/<rev>_add_users_table.py` (generated then edited)

- [ ] **Step 1: Generate migration skeleton**

```bash
poetry run alembic revision --autogenerate -m "add_users_table"
```

Note the generated filename (e.g., `alembic/versions/abc123_add_users_table.py`).

- [ ] **Step 2: Review and complete the migration**

Open the generated file. Replace its `upgrade()` and `downgrade()` with:

```python
import uuid
import os
from passlib.context import CryptContext
import sqlalchemy as sa
from alembic import op

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("username", sa.String(64), nullable=False, unique=True),
        sa.Column("email", sa.String(255), nullable=False, unique=True),
        sa.Column("hashed_password", sa.String(255), nullable=False),
        sa.Column("role", sa.String(10), nullable=False, server_default="viewer"),
        sa.Column("is_active", sa.Boolean, nullable=False, server_default="1"),
        sa.Column("password_reset_required", sa.Boolean, nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime, server_default=sa.func.now()),
        sa.Column("last_login_at", sa.DateTime, nullable=True),
    )
    op.create_index("ix_users_username", "users", ["username"])
    op.create_index("ix_users_email", "users", ["email"])

    # Seed initial admin from env vars
    admin_username = os.environ.get("TENDERAI_ADMIN_USERNAME", "admin")
    admin_password = os.environ.get("TENDERAI_ADMIN_PASSWORD", "")
    admin_email = os.environ.get("TENDERAI_ADMIN_EMAIL", f"{admin_username}@tenderai.bf")

    if admin_password:
        op.execute(
            sa.text(
                "INSERT INTO users (id, username, email, hashed_password, role, "
                "is_active, password_reset_required) VALUES "
                "(:id, :username, :email, :hashed_password, 'admin', 1, 0)"
            ).bindparams(
                id=str(uuid.uuid4()),
                username=admin_username,
                email=admin_email,
                hashed_password=pwd_context.hash(admin_password),
            )
        )


def downgrade() -> None:
    op.drop_index("ix_users_email", "users")
    op.drop_index("ix_users_username", "users")
    op.drop_table("users")
```

- [ ] **Step 3: Run migration locally (requires running postgres)**

```bash
make migrate
```

Expected: `Running upgrade ... -> <rev>, add_users_table`

- [ ] **Step 4: Commit**

```bash
git add alembic/versions/
git commit -m "feat: add users table migration with admin seed"
```

---

## Phase 2 — Auth System Update

### Task 3: Update dependencies.py — role in JWT + RequireAdmin

**Files:**
- Modify: `src/tenderai_bf/api/dependencies.py`

- [ ] **Step 1: Update `get_current_user` to include role, add `RequireAdmin`**

Replace the content of `src/tenderai_bf/api/dependencies.py` with:

```python
"""FastAPI dependencies and utilities."""

from typing import Annotated, Optional

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from passlib.context import CryptContext
from sqlalchemy.orm import Session

from ..config import settings
from ..db import get_db
from ..logging import get_logger

logger = get_logger(__name__)

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/v1/admin/login", auto_error=False)
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

SECRET_KEY = settings.monitoring.jwt_secret_key
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 60 * 24  # 24 hours


async def get_current_user(token: Annotated[str, Depends(oauth2_scheme)]) -> Optional[dict]:
    """Decode JWT and return user dict. Returns None if token missing or invalid."""
    if not token:
        return None
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        username: str = payload.get("sub")
        if username is None:
            return None
        return {
            "username": username,
            "email": payload.get("email"),
            "role": payload.get("role", "viewer"),
            "password_reset_required": payload.get("password_reset_required", False),
        }
    except JWTError as e:
        logger.error("Invalid JWT token", error=str(e))
        return None


async def require_auth(current_user: Annotated[dict, Depends(get_current_user)]) -> dict:
    """Require a valid JWT. Raises 401 if missing or invalid."""
    if current_user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Not authenticated",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return current_user


async def require_admin(current_user: Annotated[dict, Depends(require_auth)]) -> dict:
    """Require admin role. Raises 403 if authenticated but not admin."""
    if current_user.get("role") != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin access required",
        )
    return current_user


def create_access_token(data: dict, expires_delta: Optional[int] = None) -> str:
    """Create JWT access token."""
    from datetime import datetime, timedelta

    to_encode = data.copy()
    expire = datetime.utcnow() + timedelta(
        minutes=expires_delta if expires_delta else ACCESS_TOKEN_EXPIRE_MINUTES
    )
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)


# Type aliases
DatabaseSession = Annotated[Session, Depends(get_db)]
CurrentUser = Annotated[Optional[dict], Depends(get_current_user)]
AuthenticatedUser = Annotated[dict, Depends(require_auth)]
AdminUser = Annotated[dict, Depends(require_admin)]
```

- [ ] **Step 2: Run existing tests to verify nothing broke**

```bash
poetry run pytest tests/ -v --no-cov -m "not slow and not integration"
```

Expected: All previously passing tests still pass.

- [ ] **Step 3: Commit**

```bash
git add src/tenderai_bf/api/dependencies.py
git commit -m "feat: add role to JWT payload and RequireAdmin dependency"
```

---

### Task 4: Update admin.py — DB auth + change-password

**Files:**
- Modify: `src/tenderai_bf/api/routers/admin.py`

- [ ] **Step 1: Rewrite admin.py**

Replace the full content of `src/tenderai_bf/api/routers/admin.py`:

```python
"""Admin and authentication endpoints."""

import secrets
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm
from pydantic import BaseModel, EmailStr
from sqlalchemy.orm import Session

from ...config import settings
from ...logging import get_logger
from ...models import User
from ..dependencies import (
    ACCESS_TOKEN_EXPIRE_MINUTES,
    AdminUser,
    AuthenticatedUser,
    DatabaseSession,
    create_access_token,
    get_password_hash,
    verify_password,
)

logger = get_logger(__name__)
router = APIRouter()


class LoginRequest(BaseModel):
    username: str
    password: str


class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    role: str
    password_reset_required: bool


class UserResponse(BaseModel):
    username: str
    email: Optional[str] = None
    role: str
    is_active: bool
    password_reset_required: bool


class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str


class EmailTestRequest(BaseModel):
    to_address: Optional[EmailStr] = None
    subject: Optional[str] = None
    body: Optional[str] = None


def _authenticate_user(db: Session, username: str, password: str) -> Optional[User]:
    """Look up user in DB and verify password. Returns User or None."""
    user = db.query(User).filter(User.username == username, User.is_active == True).first()
    if not user:
        return None
    if not verify_password(password, user.hashed_password):
        return None
    return user


def _build_token(user: User) -> LoginResponse:
    token = create_access_token(
        data={
            "sub": user.username,
            "email": user.email,
            "role": user.role,
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


@router.post("/login", response_model=LoginResponse)
async def login(form_data: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(DatabaseSession.dependency)):
    user = _authenticate_user(db, form_data.username, form_data.password)
    if not user:
        logger.error("Failed login attempt", username=form_data.username)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect username or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    user.last_login_at = datetime.utcnow()
    db.commit()
    logger.info("User logged in", username=user.username)
    return _build_token(user)


@router.post("/login/simple", response_model=LoginResponse)
async def login_simple(request: LoginRequest, db: DatabaseSession):
    user = _authenticate_user(db, request.username, request.password)
    if not user:
        logger.error("Failed login attempt", username=request.username)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Incorrect username or password")
    user.last_login_at = datetime.utcnow()
    db.commit()
    logger.info("User logged in", username=user.username)
    return _build_token(user)


@router.get("/me", response_model=UserResponse)
async def get_current_user_info(user: AuthenticatedUser):
    return UserResponse(
        username=user["username"],
        email=user.get("email"),
        role=user.get("role", "viewer"),
        is_active=True,
        password_reset_required=user.get("password_reset_required", False),
    )


@router.post("/change-password")
async def change_password(
    request: ChangePasswordRequest,
    current_user: AuthenticatedUser,
    db: DatabaseSession,
):
    """Change the authenticated user's own password."""
    user = db.query(User).filter(User.username == current_user["username"]).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if not verify_password(request.current_password, user.hashed_password):
        raise HTTPException(status_code=400, detail="Current password is incorrect")
    if len(request.new_password) < 8:
        raise HTTPException(status_code=400, detail="Password must be at least 8 characters")
    user.hashed_password = get_password_hash(request.new_password)
    user.password_reset_required = False
    db.commit()
    logger.info("Password changed", username=user.username)
    return {"status": "success", "message": "Password changed successfully"}


@router.post("/test-email")
async def test_email(request: EmailTestRequest, user: AuthenticatedUser):
    from ...email import send_email
    try:
        to_address = request.to_address or settings.email.to_address
        subject = request.subject or "Test Email from TenderAI BF"
        body = request.body or (
            "Ceci est un email de test depuis TenderAI BF.\n\n"
            "Si vous recevez cet email, la configuration SMTP fonctionne correctement.\n\n"
            "Cordialement,\nTenderAI BF"
        )
        success = send_email(to_address=to_address, subject=subject, body=body)
        if not success:
            raise Exception("Email sending failed")
        logger.info("Test email sent", to_address=to_address, sent_by=user["username"])
        return {"status": "success", "message": f"Test email sent to {to_address}", "to_address": to_address}
    except Exception as e:
        logger.error("Failed to send test email", error=str(e))
        raise HTTPException(status_code=500, detail=f"Failed to send test email: {str(e)}")


@router.post("/clear-cache")
async def clear_cache(user: AuthenticatedUser):
    from ...utils.robots import _robots_checker
    _robots_checker.clear_cache()
    logger.info("Caches cleared", cleared_by=user["username"])
    return {"status": "success", "message": "Caches cleared successfully", "caches_cleared": ["robots_txt"]}


@router.get("/settings")
async def get_settings_info(user: AuthenticatedUser):
    return {
        "app_name": settings.app_name,
        "app_version": settings.app_version,
        "environment": settings.environment,
        "scheduler": {
            "enabled": settings.scheduler.enabled,
            "cron_schedule": settings.scheduler.cron_schedule,
            "timezone": settings.scheduler.timezone,
        },
    }


@router.post("/reload-config")
async def reload_config(user: AuthenticatedUser):
    logger.info("Config reload requested", requested_by=user["username"])
    return {"status": "success", "message": "Configuration reload requested (may require app restart for full effect)"}
```

> **Note:** The `DatabaseSession` dependency is used as `db: DatabaseSession` (type alias). For the `/login` OAuth2 route, use `db: Session = Depends(get_db)` directly since `OAuth2PasswordRequestForm` conflicts with `DatabaseSession` alias syntax — adjust the import.

- [ ] **Step 2: Fix the `/login` route to use `get_db` directly**

In the `login` endpoint, replace the signature to avoid the alias conflict:

```python
from ...db import get_db

@router.post("/login", response_model=LoginResponse)
async def login(
    form_data: OAuth2PasswordRequestForm = Depends(),
    db: Session = Depends(get_db),
):
    ...
```

- [ ] **Step 3: Run tests**

```bash
poetry run pytest tests/api/test_auth.py -v --no-cov
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/tenderai_bf/api/routers/admin.py
git commit -m "feat: authenticate users from DB, add change-password endpoint"
```

---

## Phase 3 — User Management API

### Task 5: Add send_credentials_email to email module

**Files:**
- Modify: `src/tenderai_bf/email/__init__.py`

- [ ] **Step 1: Add credential email helper**

Append to `src/tenderai_bf/email/__init__.py`:

```python
def send_credentials_email(
    to_address: str,
    username: str,
    password: str,
    frontend_url: str,
    is_reset: bool = False,
) -> bool:
    """Send auto-generated credentials to a new or reset user."""
    action = "réinitialisé" if is_reset else "créé"
    subject = f"Vos accès TenderAI BF — mot de passe {action}"
    body = (
        f"Bonjour {username},\n\n"
        f"Un compte a été {action} pour vous sur TenderAI BF.\n\n"
        f"Identifiant : {username}\n"
        f"Mot de passe : {password}\n"
        f"Accès        : {frontend_url}\n\n"
        "Vous devrez changer ce mot de passe à votre prochaine connexion.\n\n"
        "Cordialement,\nTenderAI BF"
    )
    return send_email(to_address=to_address, subject=subject, body=body)
```

- [ ] **Step 2: Run existing email tests**

```bash
poetry run pytest tests/ -k "email" -v --no-cov
```

Expected: All passing.

- [ ] **Step 3: Commit**

```bash
git add src/tenderai_bf/email/__init__.py
git commit -m "feat: add send_credentials_email helper"
```

---

### Task 6: Create users.py router and register it

**Files:**
- Create: `src/tenderai_bf/api/routers/users.py`
- Create: `tests/api/test_users.py`
- Modify: `src/tenderai_bf/api/main.py`

- [ ] **Step 1: Write failing tests for user CRUD**

Create `tests/api/test_users.py`:

```python
"""Tests for user management endpoints."""
import uuid
import pytest
from unittest.mock import patch
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from tenderai_bf.api.main import app
from tenderai_bf.db import get_db
from tenderai_bf.models import Base, User
from tenderai_bf.api.dependencies import get_password_hash


@pytest.fixture(scope="function")
def db_engine():
    engine = create_engine("sqlite:///:memory:")
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
def admin_token(client, db_session):
    """Create an admin user and return its JWT token."""
    admin = User(
        id=str(uuid.uuid4()),
        username="admin",
        email="admin@test.com",
        hashed_password=get_password_hash("adminpass123"),
        role="admin",
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(admin)
    db_session.commit()

    resp = client.post("/api/v1/admin/login/simple", json={"username": "admin", "password": "adminpass123"})
    assert resp.status_code == 200
    return resp.json()["access_token"]


def test_list_users_requires_admin(client, admin_token):
    resp = client.get("/api/v1/users", headers={"Authorization": f"Bearer {admin_token}"})
    assert resp.status_code == 200
    assert isinstance(resp.json()["users"], list)


def test_list_users_forbidden_for_viewer(client, db_session):
    viewer = User(
        id=str(uuid.uuid4()),
        username="viewer1",
        email="viewer@test.com",
        hashed_password=get_password_hash("viewerpass123"),
        role="viewer",
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(viewer)
    db_session.commit()

    resp = client.post("/api/v1/admin/login/simple", json={"username": "viewer1", "password": "viewerpass123"})
    token = resp.json()["access_token"]

    resp = client.get("/api/v1/users", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 403


@patch("tenderai_bf.api.routers.users.send_credentials_email", return_value=True)
def test_create_user_sends_email(mock_email, client, admin_token):
    resp = client.post(
        "/api/v1/users",
        json={"username": "newuser", "email": "new@test.com", "role": "viewer"},
        headers={"Authorization": f"Bearer {admin_token}"},
    )
    assert resp.status_code == 201
    assert resp.json()["username"] == "newuser"
    assert mock_email.called


def test_deactivate_user(client, admin_token, db_session):
    user = User(
        id=str(uuid.uuid4()),
        username="todeactivate",
        email="deact@test.com",
        hashed_password=get_password_hash("pass123"),
        role="viewer",
        is_active=True,
        password_reset_required=False,
    )
    db_session.add(user)
    db_session.commit()

    resp = client.patch(
        f"/api/v1/users/{user.id}",
        json={"is_active": False},
        headers={"Authorization": f"Bearer {admin_token}"},
    )
    assert resp.status_code == 200
    assert resp.json()["is_active"] is False


def test_admin_cannot_deactivate_self(client, admin_token, db_session):
    admin = db_session.query(User).filter_by(username="admin").first()
    resp = client.patch(
        f"/api/v1/users/{admin.id}",
        json={"is_active": False},
        headers={"Authorization": f"Bearer {admin_token}"},
    )
    assert resp.status_code == 400
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
poetry run pytest tests/api/test_users.py -v --no-cov
```

Expected: FAIL — router not created yet.

- [ ] **Step 3: Create users.py router**

Create `src/tenderai_bf/api/routers/users.py`:

```python
"""User management endpoints (admin only)."""

import os
import secrets
import uuid
from typing import List, Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, EmailStr
from sqlalchemy.orm import Session

from ...email import send_credentials_email
from ...logging import get_logger
from ...models import User
from ..dependencies import AdminUser, AuthenticatedUser, DatabaseSession, get_password_hash

logger = get_logger(__name__)
router = APIRouter()

FRONTEND_URL = os.environ.get("FRONTEND_URL", "http://localhost:3000")


class UserCreateRequest(BaseModel):
    username: str
    email: EmailStr
    role: str  # "admin" | "viewer"


class UserUpdateRequest(BaseModel):
    role: Optional[str] = None
    is_active: Optional[bool] = None


class UserOut(BaseModel):
    id: str
    username: str
    email: str
    role: str
    is_active: bool
    password_reset_required: bool

    class Config:
        from_attributes = True


@router.get("", response_model=dict)
async def list_users(current_user: AdminUser, db: DatabaseSession):
    users = db.query(User).order_by(User.created_at.desc()).all()
    return {"users": [UserOut.model_validate(u) for u in users]}


@router.post("", response_model=UserOut, status_code=201)
async def create_user(request: UserCreateRequest, current_user: AdminUser, db: DatabaseSession):
    if request.role not in ("admin", "viewer"):
        raise HTTPException(status_code=400, detail="role must be 'admin' or 'viewer'")

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
    current_user: AdminUser,
    db: DatabaseSession,
):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    # Prevent admin from deactivating themselves
    if user.username == current_user["username"] and request.is_active is False:
        raise HTTPException(status_code=400, detail="You cannot deactivate your own account")

    if request.role is not None:
        if request.role not in ("admin", "viewer"):
            raise HTTPException(status_code=400, detail="role must be 'admin' or 'viewer'")
        user.role = request.role

    if request.is_active is not None:
        user.is_active = request.is_active

    db.commit()
    db.refresh(user)
    logger.info("User updated", user_id=user_id, updated_by=current_user["username"])
    return UserOut.model_validate(user)


@router.delete("/{user_id}", status_code=204)
async def delete_user(user_id: str, current_user: AdminUser, db: DatabaseSession):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if user.username == current_user["username"]:
        raise HTTPException(status_code=400, detail="You cannot delete your own account")
    db.delete(user)
    db.commit()
    logger.info("User deleted", user_id=user_id, deleted_by=current_user["username"])


@router.post("/{user_id}/reset-password", response_model=UserOut)
async def reset_password(user_id: str, current_user: AdminUser, db: DatabaseSession):
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

- [ ] **Step 4: Register router in main.py**

In `src/tenderai_bf/api/main.py`, add:

```python
from .routers import users as users_router
# ... in the section where other routers are included:
app.include_router(users_router.router, prefix="/api/v1/users", tags=["users"])
```

- [ ] **Step 5: Run tests**

```bash
poetry run pytest tests/api/test_users.py -v --no-cov
```

Expected: PASS — 5 tests.

- [ ] **Step 6: Commit**

```bash
git add src/tenderai_bf/api/routers/users.py src/tenderai_bf/api/main.py tests/api/test_users.py
git commit -m "feat: add user management API (CRUD + password reset)"
```

---

## Phase 4 — Frontend Setup

### Task 7: Scaffold Next.js project

**Files:**
- Create: `frontend/` directory with full Next.js project

- [ ] **Step 1: Initialize Next.js**

```bash
cd /path/to/rfp-watch-ai
npx create-next-app@14 frontend \
  --typescript \
  --tailwind \
  --eslint \
  --app \
  --no-src-dir \
  --import-alias "@/*"
cd frontend
```

- [ ] **Step 2: Install shadcn/ui**

```bash
npx shadcn@latest init
```

When prompted:
- Style: Default
- Base color: Slate
- CSS variables: Yes

- [ ] **Step 3: Install required shadcn components**

```bash
npx shadcn@latest add button input label card table dialog badge form
```

- [ ] **Step 4: Install additional dependencies**

```bash
npm install jose axios
npm install --save-dev @types/node
```

- [ ] **Step 5: Create `.env.local` for development**

Create `frontend/.env.local`:

```
NEXT_PUBLIC_API_URL=http://localhost:8000
NEXT_PUBLIC_FRONTEND_URL=http://localhost:3000
JWT_SECRET=same_value_as_TENDERAI_JWT_SECRET
```

- [ ] **Step 6: Commit**

```bash
cd ..
git add frontend/
git commit -m "feat: scaffold Next.js 14 project with shadcn/ui"
```

---

### Task 8: API client and auth utilities

**Files:**
- Create: `frontend/lib/api.ts`
- Create: `frontend/lib/auth.ts`

- [ ] **Step 1: Create typed API client**

Create `frontend/lib/api.ts`:

```typescript
const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

async function request<T>(
  path: string,
  options: RequestInit = {},
  token?: string
): Promise<T> {
  const headers: HeadersInit = {
    "Content-Type": "application/json",
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...options.headers,
  };
  const res = await fetch(`${API_URL}${path}`, { ...options, headers });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new ApiError(res.status, body.detail ?? res.statusText);
  }
  if (res.status === 204) return {} as T;
  return res.json();
}

export interface LoginResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  role: "admin" | "viewer";
  password_reset_required: boolean;
}

export interface UserOut {
  id: string;
  username: string;
  email: string;
  role: "admin" | "viewer";
  is_active: boolean;
  password_reset_required: boolean;
}

export interface RunItem {
  run_id: string;
  status: string;
  started_at: string;
  finished_at?: string;
  duration_seconds?: number;
  stats?: { relevant_items: number };
}

export const api = {
  login: (username: string, password: string) =>
    request<LoginResponse>("/api/v1/admin/login/simple", {
      method: "POST",
      body: JSON.stringify({ username, password }),
    }),

  me: (token: string) =>
    request<{ username: string; email: string; role: string; password_reset_required: boolean }>(
      "/api/v1/admin/me",
      {},
      token
    ),

  changePassword: (token: string, current_password: string, new_password: string) =>
    request("/api/v1/admin/change-password", {
      method: "POST",
      body: JSON.stringify({ current_password, new_password }),
    }, token),

  // Users
  listUsers: (token: string) =>
    request<{ users: UserOut[] }>("/api/v1/users", {}, token),

  createUser: (token: string, data: { username: string; email: string; role: string }) =>
    request<UserOut>("/api/v1/users", { method: "POST", body: JSON.stringify(data) }, token),

  updateUser: (token: string, id: string, data: { role?: string; is_active?: boolean }) =>
    request<UserOut>(`/api/v1/users/${id}`, { method: "PATCH", body: JSON.stringify(data) }, token),

  deleteUser: (token: string, id: string) =>
    request(`/api/v1/users/${id}`, { method: "DELETE" }, token),

  resetPassword: (token: string, id: string) =>
    request<UserOut>(`/api/v1/users/${id}/reset-password`, { method: "POST" }, token),

  // Runs
  getRuns: (token: string, page = 1, pageSize = 10) =>
    request<{ runs: RunItem[] }>(`/api/v1/runs?page=${page}&page_size=${pageSize}`, {}, token),

  triggerRun: (token: string) =>
    request("/api/v1/runs/trigger", { method: "POST", body: JSON.stringify({ triggered_by: "ui" }) }, token),

  // Health
  getHealth: () => request<{ status: string; components: Record<string, { status: string }> }>("/health"),

  // Sources
  getSources: (token: string) =>
    request<{ sources: unknown[] }>("/api/v1/sources?enabled_only=false", {}, token),
};
```

- [ ] **Step 2: Create auth utilities**

Create `frontend/lib/auth.ts`:

```typescript
import { jwtDecode } from "jose/dist/browser/index";

export interface JWTPayload {
  sub: string;
  email: string;
  role: "admin" | "viewer";
  password_reset_required: boolean;
  exp: number;
}

export function decodeToken(token: string): JWTPayload | null {
  try {
    return jwtDecode<JWTPayload>(token);
  } catch {
    return null;
  }
}

export function isTokenExpired(token: string): boolean {
  const payload = decodeToken(token);
  if (!payload) return true;
  return payload.exp * 1000 < Date.now();
}

export function getRole(token: string): "admin" | "viewer" | null {
  const payload = decodeToken(token);
  return payload?.role ?? null;
}
```

- [ ] **Step 3: Commit**

```bash
git add frontend/lib/
git commit -m "feat: add typed API client and auth utilities"
```

---

## Phase 5 — Frontend Auth Flow

### Task 9: Next.js route handlers (cookie management)

**Files:**
- Create: `frontend/app/api/auth/login/route.ts`
- Create: `frontend/app/api/auth/logout/route.ts`

- [ ] **Step 1: Create login route handler**

Create `frontend/app/api/auth/login/route.ts`:

```typescript
import { NextRequest, NextResponse } from "next/server";
import { api } from "@/lib/api";

export async function POST(request: NextRequest) {
  const { username, password } = await request.json();

  try {
    const data = await api.login(username, password);
    const response = NextResponse.json({
      role: data.role,
      password_reset_required: data.password_reset_required,
    });
    response.cookies.set("auth_token", data.access_token, {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "lax",
      maxAge: data.expires_in,
      path: "/",
    });
    return response;
  } catch (err: unknown) {
    const status = (err as { status?: number }).status ?? 500;
    const message = (err as Error).message ?? "Login failed";
    return NextResponse.json({ error: message }, { status });
  }
}
```

- [ ] **Step 2: Create logout route handler**

Create `frontend/app/api/auth/logout/route.ts`:

```typescript
import { NextResponse } from "next/server";

export async function POST() {
  const response = NextResponse.json({ success: true });
  response.cookies.delete("auth_token");
  return response;
}
```

- [ ] **Step 3: Commit**

```bash
git add frontend/app/api/
git commit -m "feat: add login/logout route handlers with httpOnly cookie"
```

---

### Task 10: Next.js middleware for route protection

**Files:**
- Create: `frontend/middleware.ts`

- [ ] **Step 1: Create middleware**

Create `frontend/middleware.ts`:

```typescript
import { NextRequest, NextResponse } from "next/server";
import { jwtVerify } from "jose";

const PUBLIC_PATHS = ["/login", "/api/auth/login", "/api/auth/logout"];
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

    // Force password change
    if (payload.password_reset_required && pathname !== "/change-password") {
      return NextResponse.redirect(new URL("/change-password", request.url));
    }

    // Admin-only route
    if (pathname.startsWith("/users") && payload.role !== "admin") {
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

- [ ] **Step 2: Add JWT_SECRET to .env.local**

Ensure `frontend/.env.local` has:
```
JWT_SECRET=<same value as TENDERAI_JWT_SECRET env var>
```

- [ ] **Step 3: Commit**

```bash
git add frontend/middleware.ts
git commit -m "feat: add Next.js middleware for JWT route protection"
```

---

### Task 11: Login page and change-password page

**Files:**
- Create: `frontend/app/(auth)/login/page.tsx`
- Create: `frontend/app/(auth)/change-password/page.tsx`
- Create: `frontend/app/(auth)/layout.tsx`

- [ ] **Step 1: Create auth layout**

Create `frontend/app/(auth)/layout.tsx`:

```tsx
export default function AuthLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen flex items-center justify-center bg-slate-50">
      <div className="w-full max-w-md">{children}</div>
    </div>
  );
}
```

- [ ] **Step 2: Create login page**

Create `frontend/app/(auth)/login/page.tsx`:

```tsx
"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

export default function LoginPage() {
  const router = useRouter();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError("");
    try {
      const res = await fetch("/api/auth/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username, password }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error ?? "Identifiants incorrects");
        return;
      }
      if (data.password_reset_required) {
        router.push("/change-password");
      } else {
        router.push("/");
      }
    } catch {
      setError("Erreur de connexion. Vérifiez votre réseau.");
    } finally {
      setLoading(false);
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-2xl">TenderAI BF</CardTitle>
        <CardDescription>Connectez-vous à votre espace</CardDescription>
      </CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="username">Identifiant</Label>
            <Input
              id="username"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              required
              autoFocus
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="password">Mot de passe</Label>
            <Input
              id="password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />
          </div>
          {error && <p className="text-sm text-red-600">{error}</p>}
          <Button type="submit" className="w-full" disabled={loading}>
            {loading ? "Connexion..." : "Se connecter"}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
```

- [ ] **Step 3: Create change-password page**

Create `frontend/app/(auth)/change-password/page.tsx`:

```tsx
"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

export default function ChangePasswordPage() {
  const router = useRouter();
  const [currentPassword, setCurrentPassword] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (newPassword !== confirm) {
      setError("Les mots de passe ne correspondent pas");
      return;
    }
    if (newPassword.length < 8) {
      setError("Le mot de passe doit contenir au moins 8 caractères");
      return;
    }
    setLoading(true);
    setError("");
    try {
      const res = await fetch("/api/v1/admin/change-password", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body: JSON.stringify({ current_password: currentPassword, new_password: newPassword }),
      });
      if (!res.ok) {
        const data = await res.json();
        setError(data.detail ?? "Erreur lors du changement de mot de passe");
        return;
      }
      router.push("/");
    } catch {
      setError("Erreur réseau. Réessayez.");
    } finally {
      setLoading(false);
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Changer votre mot de passe</CardTitle>
        <CardDescription>Vous devez définir un nouveau mot de passe avant de continuer.</CardDescription>
      </CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="current">Mot de passe actuel</Label>
            <Input id="current" type="password" value={currentPassword} onChange={(e) => setCurrentPassword(e.target.value)} required />
          </div>
          <div className="space-y-2">
            <Label htmlFor="new">Nouveau mot de passe</Label>
            <Input id="new" type="password" value={newPassword} onChange={(e) => setNewPassword(e.target.value)} required />
          </div>
          <div className="space-y-2">
            <Label htmlFor="confirm">Confirmer le mot de passe</Label>
            <Input id="confirm" type="password" value={confirm} onChange={(e) => setConfirm(e.target.value)} required />
          </div>
          {error && <p className="text-sm text-red-600">{error}</p>}
          <Button type="submit" className="w-full" disabled={loading}>
            {loading ? "Changement..." : "Changer le mot de passe"}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
```

- [ ] **Step 4: Commit**

```bash
git add frontend/app/\(auth\)/
git commit -m "feat: add login and change-password pages"
```

---

## Phase 6 — Dashboard Layout & Pages

### Task 12: Sidebar and dashboard layout

**Files:**
- Create: `frontend/components/sidebar.tsx`
- Create: `frontend/app/(dashboard)/layout.tsx`

- [ ] **Step 1: Create sidebar component**

Create `frontend/components/sidebar.tsx`:

```tsx
"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { cn } from "@/lib/utils";

const baseLinks = [
  { href: "/", label: "Dashboard", icon: "📊" },
  { href: "/reports", label: "Rapports", icon: "📄" },
  { href: "/sources", label: "Sources", icon: "🌐" },
  { href: "/settings", label: "Paramètres", icon: "⚙️" },
  { href: "/logs", label: "Logs", icon: "📝" },
];

const adminLinks = [
  { href: "/users", label: "Utilisateurs", icon: "👥" },
];

interface SidebarProps {
  role: "admin" | "viewer";
  username: string;
}

export function Sidebar({ role, username }: SidebarProps) {
  const pathname = usePathname();
  const router = useRouter();
  const links = role === "admin" ? [...baseLinks, ...adminLinks] : baseLinks;

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
        {links.map(({ href, label, icon }) => (
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
            <span>{icon}</span>
            {label}
          </Link>
        ))}
      </nav>
      <div className="p-4 border-t border-slate-700">
        <button
          onClick={handleLogout}
          className="text-sm text-slate-400 hover:text-white w-full text-left"
        >
          🚪 Déconnexion
        </button>
      </div>
    </aside>
  );
}
```

- [ ] **Step 2: Create dashboard layout**

Create `frontend/app/(dashboard)/layout.tsx`:

```tsx
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { jwtVerify } from "jose";
import { Sidebar } from "@/components/sidebar";

const JWT_SECRET = new TextEncoder().encode(process.env.JWT_SECRET ?? "");

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  const token = (await cookies()).get("auth_token")?.value;
  if (!token) redirect("/login");

  let payload: { sub: string; role: "admin" | "viewer" };
  try {
    const result = await jwtVerify(token, JWT_SECRET);
    payload = result.payload as typeof payload;
  } catch {
    redirect("/login");
  }

  return (
    <div className="flex min-h-screen">
      <Sidebar role={payload.role} username={payload.sub} />
      <main className="flex-1 p-6 bg-slate-50">{children}</main>
    </div>
  );
}
```

- [ ] **Step 3: Commit**

```bash
git add frontend/components/sidebar.tsx frontend/app/\(dashboard\)/layout.tsx
git commit -m "feat: add dashboard layout with role-aware sidebar"
```

---

### Task 13: Dashboard, Reports, Sources, Settings, Logs pages

**Files:**
- Create: `frontend/app/(dashboard)/page.tsx`
- Create: `frontend/app/(dashboard)/reports/page.tsx`
- Create: `frontend/app/(dashboard)/sources/page.tsx`
- Create: `frontend/app/(dashboard)/settings/page.tsx`
- Create: `frontend/app/(dashboard)/logs/page.tsx`

- [ ] **Step 1: Dashboard page**

Create `frontend/app/(dashboard)/page.tsx`:

```tsx
import { cookies } from "next/headers";
import { api } from "@/lib/api";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { jwtVerify } from "jose";

const JWT_SECRET = new TextEncoder().encode(process.env.JWT_SECRET ?? "");

async function getTokenAndRole() {
  const token = (await cookies()).get("auth_token")?.value ?? "";
  const { payload } = await jwtVerify(token, JWT_SECRET);
  return { token, role: payload.role as string };
}

export default async function DashboardPage() {
  const { token, role } = await getTokenAndRole();
  const [health, runsData] = await Promise.all([
    api.getHealth().catch(() => ({ status: "error", components: {} })),
    api.getRuns(token).catch(() => ({ runs: [] })),
  ]);

  const statusColor = health.status === "healthy" ? "bg-green-100 text-green-800" : "bg-red-100 text-red-800";

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">Dashboard</h1>
        {role === "admin" && (
          <form action="/api/runs/trigger" method="POST">
            <Button type="submit">🚀 Lancer maintenant</Button>
          </form>
        )}
      </div>

      <div className="grid grid-cols-3 gap-4">
        <Card>
          <CardHeader><CardTitle className="text-sm">Système</CardTitle></CardHeader>
          <CardContent>
            <span className={`px-2 py-1 rounded text-xs font-medium ${statusColor}`}>
              {health.status}
            </span>
          </CardContent>
        </Card>
        {Object.entries(health.components ?? {}).map(([name, comp]) => (
          <Card key={name}>
            <CardHeader><CardTitle className="text-sm capitalize">{name}</CardTitle></CardHeader>
            <CardContent>
              <Badge variant={(comp as { status: string }).status === "healthy" ? "default" : "destructive"}>
                {(comp as { status: string }).status}
              </Badge>
            </CardContent>
          </Card>
        ))}
      </div>

      <Card>
        <CardHeader><CardTitle>Runs récents</CardTitle></CardHeader>
        <CardContent>
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-slate-500 border-b">
                <th className="pb-2">ID</th>
                <th className="pb-2">Statut</th>
                <th className="pb-2">Démarré</th>
                <th className="pb-2">Durée</th>
                <th className="pb-2">Items</th>
              </tr>
            </thead>
            <tbody>
              {runsData.runs.map((run) => (
                <tr key={run.run_id} className="border-b last:border-0 py-2">
                  <td className="py-2 font-mono">{run.run_id.slice(0, 8)}…</td>
                  <td>
                    <Badge variant={run.status === "completed" ? "default" : run.status === "failed" ? "destructive" : "secondary"}>
                      {run.status}
                    </Badge>
                  </td>
                  <td>{run.started_at?.slice(0, 16) ?? "—"}</td>
                  <td>{run.duration_seconds ? `${run.duration_seconds.toFixed(1)}s` : "—"}</td>
                  <td>{run.stats?.relevant_items ?? 0}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </CardContent>
      </Card>
    </div>
  );
}
```

- [ ] **Step 2: Reports page**

Create `frontend/app/(dashboard)/reports/page.tsx`:

```tsx
import { cookies } from "next/headers";
import { api } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";

export default async function ReportsPage() {
  const token = (await cookies()).get("auth_token")?.value ?? "";
  const runsData = await api.getRuns(token, 1, 50).catch(() => ({ runs: [] }));
  const completed = runsData.runs.filter((r) => r.status === "completed");

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Rapports</h1>
      <Card>
        <CardHeader><CardTitle>Rapports disponibles</CardTitle></CardHeader>
        <CardContent>
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-slate-500 border-b">
                <th className="pb-2">Run ID</th>
                <th className="pb-2">Date</th>
                <th className="pb-2">Items</th>
                <th className="pb-2">Action</th>
              </tr>
            </thead>
            <tbody>
              {completed.map((run) => (
                <tr key={run.run_id} className="border-b last:border-0">
                  <td className="py-2 font-mono">{run.run_id.slice(0, 8)}…</td>
                  <td>{run.started_at?.slice(0, 16) ?? "—"}</td>
                  <td>{run.stats?.relevant_items ?? 0}</td>
                  <td>
                    <a
                      href={`${process.env.NEXT_PUBLIC_API_URL}/api/v1/reports/${run.run_id}/download`}
                      target="_blank"
                      className="text-blue-600 hover:underline text-xs"
                    >
                      📥 Télécharger
                    </a>
                  </td>
                </tr>
              ))}
              {completed.length === 0 && (
                <tr><td colSpan={4} className="py-4 text-slate-400 text-center">Aucun rapport disponible</td></tr>
              )}
            </tbody>
          </table>
        </CardContent>
      </Card>
    </div>
  );
}
```

- [ ] **Step 3: Sources page**

Create `frontend/app/(dashboard)/sources/page.tsx`:

```tsx
import { cookies } from "next/headers";
import { api } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";

export default async function SourcesPage() {
  const token = (await cookies()).get("auth_token")?.value ?? "";
  const data = await api.getSources(token).catch(() => ({ sources: [] }));

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Sources</h1>
      <Card>
        <CardHeader><CardTitle>Sources configurées</CardTitle></CardHeader>
        <CardContent>
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-slate-500 border-b">
                <th className="pb-2">Nom</th>
                <th className="pb-2">Parser</th>
                <th className="pb-2">Statut</th>
                <th className="pb-2">Dernière réussite</th>
              </tr>
            </thead>
            <tbody>
              {(data.sources as Array<Record<string, unknown>>).map((s, i) => (
                <tr key={i} className="border-b last:border-0">
                  <td className="py-2 font-medium">{String(s.name ?? "—")}</td>
                  <td className="font-mono text-xs">{String(s.parser ?? s.parser_type ?? "—")}</td>
                  <td>
                    <Badge variant={s.enabled ? "default" : "secondary"}>
                      {s.enabled ? "Actif" : "Inactif"}
                    </Badge>
                  </td>
                  <td className="text-slate-500">{s.last_success_at ? String(s.last_success_at).slice(0, 16) : "Jamais"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </CardContent>
      </Card>
    </div>
  );
}
```

- [ ] **Step 4: Settings page**

Create `frontend/app/(dashboard)/settings/page.tsx`:

```tsx
import { cookies } from "next/headers";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "";

export default async function SettingsPage() {
  const token = (await cookies()).get("auth_token")?.value ?? "";
  const res = await fetch(`${API_URL}/api/v1/admin/settings`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  }).catch(() => null);
  const settings = res?.ok ? await res.json() : {};

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Paramètres</h1>
      <Card>
        <CardHeader><CardTitle>Configuration actuelle</CardTitle></CardHeader>
        <CardContent>
          <pre className="text-xs bg-slate-100 p-4 rounded overflow-auto">
            {JSON.stringify(settings, null, 2)}
          </pre>
        </CardContent>
      </Card>
    </div>
  );
}
```

- [ ] **Step 5: Logs page**

Create `frontend/app/(dashboard)/logs/page.tsx`:

```tsx
import { cookies } from "next/headers";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { readFileSync } from "fs";

export default async function LogsPage() {
  let logs = "Logs non disponibles dans ce contexte.";
  try {
    const raw = readFileSync("/app/logs/tenderai.log", "utf-8");
    const lines = raw.split("\n");
    logs = lines.slice(-200).join("\n");
  } catch {}

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Logs système</h1>
      <Card>
        <CardHeader><CardTitle>200 dernières lignes</CardTitle></CardHeader>
        <CardContent>
          <pre className="text-xs bg-slate-900 text-slate-100 p-4 rounded overflow-auto h-[600px]">
            {logs}
          </pre>
        </CardContent>
      </Card>
    </div>
  );
}
```

- [ ] **Step 6: Commit**

```bash
git add frontend/app/\(dashboard\)/
git commit -m "feat: add dashboard, reports, sources, settings and logs pages"
```

---

## Phase 7 — User Management UI

### Task 14: Users page with create and reset dialogs

**Files:**
- Create: `frontend/app/(dashboard)/users/page.tsx`
- Create: `frontend/components/users/create-user-dialog.tsx`

- [ ] **Step 1: Create user dialog component**

Create `frontend/components/users/create-user-dialog.tsx`:

```tsx
"use client";

import { useState } from "react";
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

interface Props {
  onCreated: () => void;
}

export function CreateUserDialog({ onCreated }: Props) {
  const [open, setOpen] = useState(false);
  const [username, setUsername] = useState("");
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<"admin" | "viewer">("viewer");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError("");
    try {
      const res = await fetch("/api/v1/users", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body: JSON.stringify({ username, email, role }),
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
      onCreated();
    } catch {
      setError("Erreur réseau.");
    } finally {
      setLoading(false);
    }
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button>➕ Nouvel utilisateur</Button>
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
            <Label htmlFor="username">Identifiant</Label>
            <Input id="username" value={username} onChange={(e) => setUsername(e.target.value)} required />
          </div>
          <div className="space-y-2">
            <Label htmlFor="email">Email</Label>
            <Input id="email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
          </div>
          <div className="space-y-2">
            <Label htmlFor="role">Rôle</Label>
            <select
              id="role"
              value={role}
              onChange={(e) => setRole(e.target.value as "admin" | "viewer")}
              className="w-full border rounded-md px-3 py-2 text-sm"
            >
              <option value="viewer">Viewer</option>
              <option value="admin">Admin</option>
            </select>
          </div>
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

- [ ] **Step 2: Create users page**

Create `frontend/app/(dashboard)/users/page.tsx`:

```tsx
"use client";

import { useEffect, useState } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { CreateUserDialog } from "@/components/users/create-user-dialog";

interface User {
  id: string;
  username: string;
  email: string;
  role: "admin" | "viewer";
  is_active: boolean;
  password_reset_required: boolean;
}

export default function UsersPage() {
  const [users, setUsers] = useState<User[]>([]);
  const [loading, setLoading] = useState(true);

  async function loadUsers() {
    setLoading(true);
    try {
      const res = await fetch("/api/v1/users", { credentials: "include" });
      if (res.ok) {
        const data = await res.json();
        setUsers(data.users);
      }
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { loadUsers(); }, []);

  async function toggleActive(user: User) {
    await fetch(`/api/v1/users/${user.id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      credentials: "include",
      body: JSON.stringify({ is_active: !user.is_active }),
    });
    loadUsers();
  }

  async function resetPassword(user: User) {
    if (!confirm(`Réinitialiser le mot de passe de ${user.username} ?`)) return;
    await fetch(`/api/v1/users/${user.id}/reset-password`, {
      method: "POST",
      credentials: "include",
    });
    alert("Nouveau mot de passe envoyé par email.");
  }

  async function deleteUser(user: User) {
    if (!confirm(`Supprimer l'utilisateur ${user.username} ?`)) return;
    await fetch(`/api/v1/users/${user.id}`, { method: "DELETE", credentials: "include" });
    loadUsers();
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">Utilisateurs</h1>
        <CreateUserDialog onCreated={loadUsers} />
      </div>

      <Card>
        <CardHeader><CardTitle>Liste des utilisateurs</CardTitle></CardHeader>
        <CardContent>
          {loading ? (
            <p className="text-slate-400 text-sm">Chargement…</p>
          ) : (
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-slate-500 border-b">
                  <th className="pb-2">Utilisateur</th>
                  <th className="pb-2">Email</th>
                  <th className="pb-2">Rôle</th>
                  <th className="pb-2">Statut</th>
                  <th className="pb-2">Actions</th>
                </tr>
              </thead>
              <tbody>
                {users.map((user) => (
                  <tr key={user.id} className="border-b last:border-0">
                    <td className="py-3 font-medium">{user.username}</td>
                    <td className="text-slate-500">{user.email}</td>
                    <td>
                      <Badge variant={user.role === "admin" ? "default" : "secondary"}>
                        {user.role}
                      </Badge>
                    </td>
                    <td>
                      <Badge variant={user.is_active ? "default" : "destructive"}>
                        {user.is_active ? "Actif" : "Inactif"}
                      </Badge>
                    </td>
                    <td className="space-x-2">
                      <Button size="sm" variant="outline" onClick={() => toggleActive(user)}>
                        {user.is_active ? "Désactiver" : "Activer"}
                      </Button>
                      <Button size="sm" variant="outline" onClick={() => resetPassword(user)}>
                        🔑 Reset MDP
                      </Button>
                      <Button size="sm" variant="destructive" onClick={() => deleteUser(user)}>
                        Supprimer
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
```

- [ ] **Step 3: Commit**

```bash
git add frontend/app/\(dashboard\)/users/ frontend/components/users/
git commit -m "feat: add user management page with create and reset dialogs"
```

---

## Phase 8 — Infrastructure

### Task 15: Dockerfile.frontend and docker-compose updates

**Files:**
- Create: `infra/Dockerfile.frontend`
- Modify: `docker-compose.yml`
- Modify: `docker-compose.override.prod.yml`
- Modify: `docker-compose.override.dev.yml` (if it exists)

- [ ] **Step 1: Create Dockerfile.frontend**

Create `infra/Dockerfile.frontend`:

```dockerfile
FROM node:20-alpine AS deps
WORKDIR /app
COPY frontend/package.json frontend/package-lock.json* ./
RUN npm ci

FROM node:20-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY frontend/ .
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
RUN addgroup -S nextjs && adduser -S nextjs -G nextjs
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nextjs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nextjs /app/.next/static ./.next/static
USER nextjs
EXPOSE 3000
CMD ["node", "server.js"]
```

- [ ] **Step 2: Add `output: "standalone"` to next.config.ts**

Edit `frontend/next.config.ts`:

```typescript
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",
};

export default nextConfig;
```

- [ ] **Step 3: Update docker-compose.yml — replace `ui` with `frontend`**

In `docker-compose.yml`:
- Delete the entire `ui:` service block
- Add:

```yaml
  frontend:
    build:
      context: .
      dockerfile: infra/Dockerfile.frontend
    container_name: tenderai-frontend
    env_file: .env
    environment:
      - NEXT_PUBLIC_API_URL=http://api:8000
      - NEXT_PUBLIC_FRONTEND_URL=${FRONTEND_URL:-http://localhost:3000}
      - JWT_SECRET=${TENDERAI_JWT_SECRET}
    depends_on:
      - api
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000"]
      interval: 30s
      timeout: 10s
      retries: 3
    restart: unless-stopped
    networks:
      - tenderai-network
```

- [ ] **Step 4: Update docker-compose.override.prod.yml**

Replace the `ui` service block with:

```yaml
  frontend:
    image: ghcr.io/abdazz/tenderai-bf-frontend:latest
    build:
      context: .
      dockerfile: infra/Dockerfile.frontend
    environment:
      - ENVIRONMENT=production
    deploy:
      resources:
        limits:
          cpus: '1'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 256M
```

- [ ] **Step 5: Commit**

```bash
git add infra/Dockerfile.frontend docker-compose.yml docker-compose.override.prod.yml frontend/next.config.ts
git commit -m "feat: add Dockerfile.frontend and replace Gradio with Next.js in docker-compose"
```

---

### Task 16: Update Nginx and add FRONTEND_URL env var

**Files:**
- Modify: `infra/nginx/nginx.conf`
- Modify: `.env.example` (if exists)

- [ ] **Step 1: Update Nginx to proxy to frontend**

In `infra/nginx/nginx.conf`, find the block proxying to `ui:7860` and replace with:

```nginx
location / {
    proxy_pass http://frontend:3000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_cache_bypass $http_upgrade;
}
```

Keep the `/api/` block pointing to `api:8000` unchanged.

- [ ] **Step 2: Add FRONTEND_URL to .env.example**

In `.env.example`, add:

```
FRONTEND_URL=https://tender-ai.yulcom.net
TENDERAI_ADMIN_EMAIL=admin@yulcom.com
```

- [ ] **Step 3: Full stack test**

```bash
make up
# wait for containers to be healthy
curl -s http://localhost:18080/login | grep -i "TenderAI"
```

Expected: HTML containing the login page.

- [ ] **Step 4: Final commit**

```bash
git add infra/nginx/nginx.conf .env.example
git commit -m "feat: update Nginx to proxy Next.js frontend, add FRONTEND_URL env var"
```

---

## Self-review notes (for agentic workers)

- The `DatabaseSession` type alias in `dependencies.py` is `Annotated[Session, Depends(get_db)]`. Use `db: DatabaseSession` in route functions — except for the OAuth2 `/login` route where you must use `db: Session = Depends(get_db)` directly due to FastAPI dependency resolution ordering.
- `UserOut.model_validate(u)` requires SQLAlchemy model instances — `from_attributes = True` is set in `UserOut.Config`.
- The JWT `SECRET_KEY` in `dependencies.py` reads `settings.monitoring.jwt_secret_key` (mapped from env var `TENDERAI_JWT_SECRET`). The Next.js middleware reads the same value from `process.env.JWT_SECRET`. Both must match.
- `send_credentials_email` is mocked in tests with `@patch("tenderai_bf.api.routers.users.send_credentials_email")` — do not rename the import.
- The `/api/v1/admin/change-password` endpoint is called directly from the frontend browser using `credentials: "include"` (the cookie is sent automatically). The API receives the JWT from the cookie through the Nginx proxy — ensure Nginx forwards the `Cookie` header.
