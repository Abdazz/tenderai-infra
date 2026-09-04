# Auth & User Management — Design Spec

**Date:** 2026-05-19
**Status:** Approved
**Scope:** Replace Gradio UI with Next.js, add authentication, add two-role user management with auto-generated passwords sent by email.

---

## 1. Context

The current Gradio UI (`ui/app.py`) has no real authentication — it auto-logs in with admin credentials at startup. Users are hardcoded in `api/routers/admin.py:58-66`. The Gradio framework is not suited for an evolving admin interface.

## 2. Goals

- Replace Gradio with a Next.js frontend
- Implement a login page (custom, integrated in the app)
- Add two roles: **admin** (full access) and **viewer** (dashboard + reports only, no pipeline launch, no user management)
- Persist users in PostgreSQL
- When an admin creates a user, a password is auto-generated and sent by email
- First login forces a password change

## 3. Architecture

```
Browser
  └── Next.js :3000  (new `frontend` Docker container)
        └── REST API calls → FastAPI :8000  (existing `api` container)
                               └── PostgreSQL (existing, new `users` table)
                               └── SMTP (existing client, sends credentials)
```

- The `ui` container (Gradio :7860) is **removed** from `docker-compose.yml` and `docker-compose.override.prod.yml`.
- Nginx is reconfigured to proxy the `frontend` container at `:3000` instead of `ui` at `:7860`.
- The Next.js app calls FastAPI exclusively — no direct DB access from the frontend.
- JWT is stored in an **httpOnly cookie** (not localStorage) to prevent XSS.
- The role (`admin` | `viewer`) is encoded in the JWT payload.

## 4. Database

New Alembic migration adds a `users` table:

| Column | Type | Notes |
|---|---|---|
| `id` | UUID, PK | |
| `username` | VARCHAR(64), unique, not null | |
| `email` | VARCHAR(255), unique, not null | Receives generated password |
| `hashed_password` | VARCHAR(255), not null | bcrypt |
| `role` | ENUM(`admin`, `viewer`), not null | |
| `is_active` | BOOLEAN, default true | |
| `password_reset_required` | BOOLEAN, default true | Forces change on first login |
| `created_at` | TIMESTAMP, default now | |
| `last_login_at` | TIMESTAMP, nullable | Updated on each login |

**Seed on migration:** one admin user is created from the existing env vars `TENDERAI_ADMIN_USERNAME` and `TENDERAI_ADMIN_PASSWORD`. `password_reset_required` is set to `false` for this seeded user (password is already known).

The hardcoded `ADMIN_USERS` dict in `api/routers/admin.py:58-66` is deleted.

## 5. Backend API

### Modified endpoints

| Method | Route | Change |
|---|---|---|
| `POST` | `/api/v1/admin/login/simple` | Read from `users` table instead of hardcoded dict |
| `GET` | `/api/v1/admin/me` | Include `role` and `password_reset_required` in response |

### New endpoints

All new endpoints are under `/api/v1/users`. All require `RequireAdmin` except `change-password`.

| Method | Route | Auth | Description |
|---|---|---|---|
| `GET` | `/api/v1/users` | Admin | List all users |
| `POST` | `/api/v1/users` | Admin | Create user, generate password, send email |
| `PATCH` | `/api/v1/users/{id}` | Admin | Update role or `is_active` |
| `DELETE` | `/api/v1/users/{id}` | Admin | Delete user |
| `POST` | `/api/v1/users/{id}/reset-password` | Admin | Regenerate password, send email |
| `POST` | `/api/v1/admin/change-password` | Any | Change own password |

> Note: `change-password` lives under the existing `/admin` router to avoid adding a new router.

### Role enforcement

Two FastAPI dependencies are added in `api/dependencies.py`:
- `RequireAuthenticated` — any valid JWT
- `RequireAdmin` — valid JWT with `role == admin`

**Protection rule:** an admin cannot delete or deactivate their own account (enforced server-side).

### Password generation

```python
import secrets
password = secrets.token_urlsafe(12)  # ~16 url-safe characters
```

The plaintext password is used once to send the email, then discarded. Only the bcrypt hash is stored.

## 6. Frontend (Next.js)

**Stack:** Next.js 14 (App Router), shadcn/ui, Tailwind CSS, TypeScript.

### Page structure

```
app/
├── (auth)/
│   ├── login/page.tsx              # Login page (public)
│   └── change-password/page.tsx   # Forced password change (authenticated)
├── (dashboard)/
│   ├── layout.tsx                  # Sidebar + JWT check middleware
│   ├── page.tsx                    # Dashboard: system status + recent runs
│   ├── reports/page.tsx            # Reports list + download
│   ├── sources/page.tsx            # Active sources
│   ├── settings/page.tsx           # App configuration (read-only display)
│   ├── logs/page.tsx               # Recent logs
│   └── users/page.tsx              # User management (admin only)
└── middleware.ts                   # JWT validation on every protected route
```

### Auth flow

1. Next.js middleware checks for a valid JWT cookie on every request to `/(dashboard)`.
2. Missing or expired → redirect to `/login`.
3. On successful login, the Next.js `/api/auth/login` route handler calls FastAPI, receives the JWT, and sets it as an httpOnly cookie — the browser never sees the raw token.
4. `password_reset_required == true` → redirect to `/change-password` before any other page.
5. After password change, `password_reset_required` is set to `false` server-side.

### Role-based access

- `/users` route: returns HTTP 403 if `role !== admin`; the sidebar entry "Utilisateurs" is hidden for viewers.
- "Run Now" button: hidden for viewers (enforced both client-side and server-side via the API).
- All other pages are accessible to both roles.

### Key shadcn/ui components

- `DataTable` — runs, sources, users lists
- `Dialog` — create/edit user form
- `Badge` — role and status indicators
- `Sidebar` — responsive navigation, filtered by role

## 7. User creation flow

```
Admin fills form: username, email, role
        ↓
POST /api/v1/users
        ↓
FastAPI generates password: secrets.token_urlsafe(12)
        ↓
Stores user in DB (bcrypt hash, password_reset_required=True)
        ↓
Sends email via existing SMTP client
        ↓
Returns 201 (password is NOT returned in the API response)
        ↓
User logs in → redirected to /change-password
```

### Email template

```
Subject: Vos accès TenderAI BF

Bonjour [username],

Un compte a été créé pour vous sur TenderAI BF.

Identifiant : [username]
Mot de passe : [generated_password]
Accès        : [FRONTEND_URL]

Vous devrez changer ce mot de passe à votre première connexion.

Cordialement,
TenderAI BF
```

**Password reset** follows the same flow: new password generated, emailed, `password_reset_required` set back to `True`.

## 8. Docker changes

- **Remove:** `ui` service (Gradio) from `docker-compose.yml` and `docker-compose.override.prod.yml`
- **Add:** `frontend` service (Next.js, built from `infra/Dockerfile.frontend`)
- **Update:** Nginx config — proxy `/` to `frontend:3000` instead of `ui:7860`
- **Add env var:** `FRONTEND_URL` (used in email template and CORS config)

## 9. Out of scope

- OAuth / SSO (Google, etc.)
- Email verification on signup
- Rate limiting on login endpoint
- Audit log of admin actions
