# Multi-Env Docker Compose Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unifier la configuration Docker pour prod et staging sur le même VPS via un seul `docker-compose.server.yml` paramétré par des fichiers `.env.prod` / `.env.staging`, avec des containers isolés (`prod_api`, `staging_api`, etc.) et un nginx dont le `server_name` est injecté dynamiquement via template.

**Architecture:** Un seul `docker-compose.server.yml` remplace `docker-compose.override.prod.yml` et `docker-compose.override.staging.yml`. Les variables d'orchestration (nom de l'env, tag d'image, ports, domaine) viennent du fichier `.env.prod` ou `.env.staging` passé via `--env-file`. Le nginx officiel traite `infra/nginx/templates/default.conf.template` avec `envsubst` au démarrage du container pour injecter `${DOMAIN}` dans le `server_name`.

**Tech Stack:** Docker Compose v2, nginx:alpine (template mechanism), GitHub Actions.

---

## Fichiers touchés

| Action | Fichier |
|--------|---------|
| **Créer** | `docker-compose.server.yml` |
| **Créer** | `infra/nginx/templates/default.conf.template` |
| **Modifier** | `infra/nginx/nginx.conf` |
| **Créer** | `.env.prod.example` |
| **Créer** | `.env.staging.example` |
| **Modifier** | `.github/workflows/ci-cd.yml` (jobs prod + staging) |
| **Supprimer** | `docker-compose.override.prod.yml` |
| **Supprimer** | `docker-compose.override.staging.yml` |
| **Supprimer** | `infra/nginx/nginx.staging.conf` |

---

### Task 1 : Créer `docker-compose.server.yml` (override unifié)

**Files:**
- Create: `docker-compose.server.yml`

- [ ] **Step 1 : Créer le fichier**

```yaml
# docker-compose.server.yml
#
# Override unifié pour production et staging sur le même hôte.
# Utiliser avec : docker compose --env-file .env.prod  (ou .env.staging)
#
# Variables requises dans le fichier .env.* :
#   ENV_NAME             — préfixe des containers  (prod / staging)
#   COMPOSE_PROJECT_NAME — namespace Docker         (tenderai-prod / tenderai-staging)
#   DOMAIN               — domaine public           (tender-ai.yulcom.net / staging.tender-ai.yulcom.net)
#   NGINX_HTTP_PORT      — port HTTP côté hôte      (18080 / 19080)
#   NGINX_HTTPS_PORT     — port HTTPS côté hôte     (18443 / 19443)
#   IMAGE_TAG            — tag d'image Docker        (latest / staging)
#   ENVIRONMENT          — valeur de ENVIRONMENT     (production / staging)

version: '3.8'

services:
  nginx:
    image: nginx:alpine
    container_name: ${ENV_NAME}_nginx
    ports:
      - "127.0.0.1:${NGINX_HTTP_PORT}:80"
      - "127.0.0.1:${NGINX_HTTPS_PORT}:443"
    volumes:
      - ./infra/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./infra/nginx/templates:/etc/nginx/templates:ro
      - /etc/letsencrypt/live/${DOMAIN}/fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - /etc/letsencrypt/live/${DOMAIN}/privkey.pem:/etc/nginx/ssl/privkey.pem:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - nginx-logs:/var/log/nginx
    environment:
      - DOMAIN=${DOMAIN}
      - NGINX_ENVSUBST_TEMPLATE_VARS=DOMAIN
    depends_on:
      - api
      - frontend
    restart: unless-stopped
    networks:
      - tenderai-network

  api:
    image: ghcr.io/abdazz/tenderai-bf-api:${IMAGE_TAG}
    container_name: ${ENV_NAME}_api
    environment:
      - ENVIRONMENT=${ENVIRONMENT}
    volumes:
      - ./settings.yaml:/app/settings.yaml:ro
      - ./logs:/app/logs
      - api-cache:/app/cache
      - ./alembic:/app/alembic
    command: ["uvicorn", "tenderai_bf.api.main:app", "--host", "0.0.0.0", "--port", "8000"]

  frontend:
    image: ghcr.io/abdazz/tenderai-bf-frontend:${IMAGE_TAG}
    container_name: ${ENV_NAME}_frontend
    environment:
      - ENVIRONMENT=${ENVIRONMENT}

  worker:
    image: ghcr.io/abdazz/tenderai-bf-worker:${IMAGE_TAG}
    container_name: ${ENV_NAME}_worker
    command: ["python", "-m", "tenderai_bf.cli", "run-scheduler"]
    environment:
      - ENVIRONMENT=${ENVIRONMENT}
    volumes:
      - ./settings.yaml:/app/settings.yaml:ro
      - ./logs:/app/logs
      - worker-cache:/app/cache
      - worker-temp:/tmp/ocr
      - chroma-data:/app/data/chroma_db

  postgres:
    container_name: ${ENV_NAME}_postgres

  minio:
    container_name: ${ENV_NAME}_minio
```

- [ ] **Step 2 : Valider la syntaxe Docker Compose**

```bash
docker compose -f docker-compose.yml -f docker-compose.server.yml \
  --env-file .env.prod.example config --quiet
```

Expected: pas d'erreur de parsing (warning sur variables manquantes si `.env.prod.example` n'existe pas encore — c'est normal, on le crée à la Task 3).

- [ ] **Step 3 : Commit**

```bash
git add docker-compose.server.yml
git commit -m "feat(infra): add unified docker-compose.server.yml parameterized by env file"
```

---

### Task 2 : Refactoriser la config nginx (static + template)

**Files:**
- Modify: `infra/nginx/nginx.conf`
- Create: `infra/nginx/templates/default.conf.template`

**Contexte :** Le nginx Docker officiel exécute `envsubst` sur tout fichier `.conf.template` dans `/etc/nginx/templates/` et place le résultat dans `/etc/nginx/conf.d/`. En définissant `NGINX_ENVSUBST_TEMPLATE_VARS=DOMAIN`, seul `${DOMAIN}` est remplacé — les variables nginx (`$host`, `$remote_addr`, etc.) ne sont pas touchées.

- [ ] **Step 1 : Modifier `infra/nginx/nginx.conf`** — retirer les blocs `upstream` et `server`, ajouter `include /etc/nginx/conf.d/*.conf;`

Remplacer tout le contenu par :

```nginx
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    client_max_body_size 100M;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml font/truetype font/opentype application/vnd.ms-fontobject image/svg+xml;

    limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=general_limit:10m rate=30r/s;

    include /etc/nginx/conf.d/*.conf;
}
```

- [ ] **Step 2 : Créer `infra/nginx/templates/default.conf.template`**

```bash
mkdir -p infra/nginx/templates
```

Créer le fichier avec ce contenu :

```nginx
upstream api_backend {
    server api:8000 max_fails=3 fail_timeout=30s;
    keepalive 32;
}

upstream frontend_backend {
    server frontend:3000 max_fails=3 fail_timeout=30s;
    keepalive 32;
}

server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;

    location /api/v1/ {
        limit_req zone=api_limit burst=20 nodelay;
        proxy_pass http://api_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }

    location /health {
        proxy_pass http://api_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        access_log off;
    }

    location /docs {
        limit_req zone=general_limit burst=10 nodelay;
        proxy_pass http://api_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        limit_req zone=general_limit burst=20 nodelay;
        proxy_pass http://frontend_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }

    location /_next/static/ {
        proxy_pass http://frontend_backend;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
```

- [ ] **Step 3 : Valider la syntaxe nginx localement**

```bash
docker run --rm \
  -v "$(pwd)/infra/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -e DOMAIN=tender-ai.yulcom.net \
  -e NGINX_ENVSUBST_TEMPLATE_VARS=DOMAIN \
  nginx:alpine nginx -t 2>&1 || true
```

Expected: `nginx: the configuration file /etc/nginx/nginx.conf syntax is ok` (les blocs server sont maintenant dans conf.d/ au runtime — une erreur "no server" est normale ici, la validation réelle se fait au démarrage du container).

- [ ] **Step 4 : Commit**

```bash
git add infra/nginx/nginx.conf infra/nginx/templates/default.conf.template
git commit -m "feat(infra): split nginx config into static global + envsubst template for domain"
```

---

### Task 3 : Créer les fichiers d'exemple `.env.prod.example` et `.env.staging.example`

**Files:**
- Create: `.env.prod.example`
- Create: `.env.staging.example`

**Contexte :** Ces fichiers documentent les variables d'orchestration Docker. Les secrets applicatifs restent dans `.env` (qui continue d'être géré comme avant via `env_file: .env` dans docker-compose.yml et les `sed` de la CI/CD).

- [ ] **Step 1 : Créer `.env.prod.example`**

```bash
# Variables d'orchestration Docker pour la production.
# Copier en .env.prod sur le serveur avant le premier déploiement.
# Les secrets applicatifs (DATABASE_URL, JWT_SECRET, etc.) restent dans .env.

ENV_NAME=prod
COMPOSE_PROJECT_NAME=tenderai-prod
DOMAIN=tender-ai.yulcom.net
NGINX_HTTP_PORT=18080
NGINX_HTTPS_PORT=18443
IMAGE_TAG=latest
ENVIRONMENT=production
```

- [ ] **Step 2 : Créer `.env.staging.example`**

```bash
# Variables d'orchestration Docker pour le staging.
# Copier en .env.staging sur le serveur avant le premier déploiement.
# Les secrets applicatifs (DATABASE_URL, JWT_SECRET, etc.) restent dans .env.

ENV_NAME=staging
COMPOSE_PROJECT_NAME=tenderai-staging
DOMAIN=staging.tender-ai.yulcom.net
NGINX_HTTP_PORT=19080
NGINX_HTTPS_PORT=19443
IMAGE_TAG=staging
ENVIRONMENT=staging
```

- [ ] **Step 3 : Vérifier que `.env.prod` et `.env.staging` sont dans `.gitignore`**

```bash
grep -E "^\.env\.(prod|staging)$" .gitignore
```

Si absent, les ajouter :
```bash
echo ".env.prod" >> .gitignore
echo ".env.staging" >> .gitignore
```

- [ ] **Step 4 : Commit**

```bash
git add .env.prod.example .env.staging.example .gitignore
git commit -m "feat(infra): add .env.prod.example and .env.staging.example for server orchestration vars"
```

---

### Task 4 : Mettre à jour le job `deploy-production` dans la CI/CD

**Files:**
- Modify: `.github/workflows/ci-cd.yml` (job `deploy-production`, lignes ~139-334)

**Changements :** remplacer `cp docker-compose.override.prod.yml docker-compose.override.yml` par `cp docker-compose.server.yml docker-compose.override.yml`, ajouter `--env-file .env.prod` à tous les appels `docker compose`, mettre à jour la vérification d'image pour utiliser `IMAGE_TAG` du fichier env.

- [ ] **Step 1 : Remplacer le bloc de setup dans le script SSH de production**

Localiser et remplacer dans `.github/workflows/ci-cd.yml` :

```yaml
            # Setup production environment - comment out port mappings in .env
            echo "📝 Configuring production environment..."
            # Copy production override (no port exposures)
            cp docker-compose.override.prod.yml docker-compose.override.yml
```

Par :

```yaml
            # Setup production environment - comment out port mappings in .env
            echo "📝 Configuring production environment..."
            # Copy unified server override (parameterized via .env.prod)
            cp docker-compose.server.yml docker-compose.override.yml
```

- [ ] **Step 2 : Ajouter `source .env.prod` et `--env-file .env.prod` à tous les appels docker compose dans le job production**

Localiser le bloc après le login registry dans le script SSH production et remplacer :

```yaml
            # Set environment to production
            export ENVIRONMENT=production
            
            # Stop all services first (--remove-orphans stops renamed/deleted services like old tenderai-ui)
            echo "🛑 Stopping existing services..."
            docker compose down --remove-orphans || true
```

Par :

```yaml
            # Load orchestration variables (ENV_NAME, IMAGE_TAG, COMPOSE_PROJECT_NAME, etc.)
            set -a; source .env.prod; set +a
            
            # Stop all services first (--remove-orphans stops renamed/deleted services)
            echo "🛑 Stopping existing services..."
            docker compose --env-file .env.prod down --remove-orphans || true
```

- [ ] **Step 3 : Mettre à jour la vérification d'image et les `docker compose pull/up/run` en production**

Remplacer la vérification d'image :

```yaml
            # Verify the api image is available (abort if never built)
            if ! docker image inspect ghcr.io/abdazz/tenderai-bf-api:latest > /dev/null 2>&1; then
              echo "❌ API image not found locally or in registry."
              echo "   Trigger a build first: push a commit with '[build]' in the message,"
              echo "   push a 'v*' tag, or run the workflow manually with skip_build=false."
              exit 1
            fi
            echo "✅ API image available: \$(docker image inspect ghcr.io/abdazz/tenderai-bf-api:latest --format '{{.Id}}' | cut -c1-19)"
            if ! docker image inspect ghcr.io/abdazz/tenderai-bf-frontend:latest > /dev/null 2>&1; then
              echo "❌ Frontend image not found. Run workflow manually with skip_build=false."
              exit 1
            fi
```

Par :

```yaml
            # Verify images are available (tag comes from .env.prod IMAGE_TAG)
            if ! docker image inspect ghcr.io/abdazz/tenderai-bf-api:\${IMAGE_TAG} > /dev/null 2>&1; then
              echo "❌ API image (tag: \${IMAGE_TAG}) not found. Trigger a build first."
              exit 1
            fi
            echo "✅ API image available: \$(docker image inspect ghcr.io/abdazz/tenderai-bf-api:\${IMAGE_TAG} --format '{{.Id}}' | cut -c1-19)"
            if ! docker image inspect ghcr.io/abdazz/tenderai-bf-frontend:\${IMAGE_TAG} > /dev/null 2>&1; then
              echo "❌ Frontend image (tag: \${IMAGE_TAG}) not found. Run workflow manually with skip_build=false."
              exit 1
            fi
```

Remplacer chaque `docker compose` (sans `--env-file`) dans le job production par `docker compose --env-file .env.prod` :

- `docker compose pull api frontend worker` → `docker compose --env-file .env.prod pull api frontend worker`
- `docker compose up -d postgres minio createbuckets` → `docker compose --env-file .env.prod up -d postgres minio createbuckets`
- `docker compose exec -T postgres pg_isready ...` → `docker compose --env-file .env.prod exec -T postgres pg_isready ...`
- `docker compose exec -T minio curl ...` → `docker compose --env-file .env.prod exec -T minio curl ...`
- `docker compose run --no-deps --rm api alembic upgrade head` → `docker compose --env-file .env.prod run --no-deps --rm api alembic upgrade head`
- `docker compose run --no-deps --rm api tenderai create-admin` → `docker compose --env-file .env.prod run --no-deps --rm api tenderai create-admin`
- `docker compose run --no-deps --rm api tenderai seed-sources` → `docker compose --env-file .env.prod run --no-deps --rm api tenderai seed-sources`
- `docker compose up -d api frontend worker nginx` → `docker compose --env-file .env.prod up -d api frontend worker nginx`
- `docker compose exec -T api curl -sf http://localhost:8000/health` → `docker compose --env-file .env.prod exec -T api curl -sf http://localhost:8000/health`
- `docker compose ps api` → `docker compose --env-file .env.prod ps api`
- `docker compose logs --tail=... api` → `docker compose --env-file .env.prod logs --tail=... api`
- `docker compose logs --tail=... postgres` → `docker compose --env-file .env.prod logs --tail=... postgres`
- `docker compose logs --tail=... minio` → `docker compose --env-file .env.prod logs --tail=... minio`

Faire de même dans le step `Health check` du job production :

```yaml
      - name: Health check
        env:
          SSH_PORT: ${{ secrets.PRODUCTION_SSH_PORT || 22 }}
          SSH_USER: ${{ secrets.PRODUCTION_USER }}
          SSH_HOST: ${{ secrets.PRODUCTION_HOST }}
          DEPLOY_PATH: ${{ secrets.PRODUCTION_DEPLOY_PATH || '/opt/tenderai-bf' }}
        run: |
          ssh -p "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}" \
            DEPLOY_PATH="${DEPLOY_PATH}" \
            'bash -s' << 'HEALTHEOF'
            cd "${DEPLOY_PATH}"
            set -a; source .env.prod; set +a
            echo '=== Final container status ==='
            docker compose --env-file .env.prod ps
            for i in $(seq 1 6); do
              if docker compose --env-file .env.prod exec -T api curl -sf http://localhost:8000/health > /dev/null 2>&1; then
                echo "✅ API OK (attempt $i)"
                exit 0
              fi
              if [ $i -eq 6 ]; then
                echo "❌ API down after $((i * 10))s — last logs:"
                docker compose --env-file .env.prod logs --tail=50 api
                exit 1
              fi
              echo "  Attempt $i: API not ready, waiting 10s..."
              sleep 10
            done
          HEALTHEOF
```

- [ ] **Step 4 : Commit**

```bash
git add .github/workflows/ci-cd.yml
git commit -m "feat(ci): use docker-compose.server.yml and --env-file .env.prod in production deploy"
```

---

### Task 5 : Mettre à jour le job `deploy-staging` dans la CI/CD

**Files:**
- Modify: `.github/workflows/ci-cd.yml` (job `deploy-staging`)

**Changements :** même pattern que la Task 4 mais pour staging — `cp docker-compose.server.yml`, `--env-file .env.staging`, `source .env.staging`.

- [ ] **Step 1 : Remplacer le setup du job staging**

Localiser dans le job `deploy-staging` et remplacer :

```yaml
            cd \${DEPLOY_PATH}

            # Pull latest code
            git pull origin staging

            # Copy staging override (ports 19080/19443, staging container names)
            cp docker-compose.override.staging.yml docker-compose.override.yml

            # Setup staging environment
            if [ -f ".env" ]; then
              sed -i 's/^POSTGRES_PORT=/#POSTGRES_PORT=/' .env
              sed -i 's/^MINIO_PORT=/#MINIO_PORT=/' .env
              sed -i 's/^MINIO_CONSOLE_PORT=/#MINIO_CONSOLE_PORT=/' .env
              sed -i 's/^API_PORT=/#API_PORT=/' .env
              sed -i 's/^UI_PORT=/#UI_PORT=/' .env
              # Inject security credentials from GitHub Secrets
              sed -i "s|^TENDERAI_JWT_SECRET=.*|TENDERAI_JWT_SECRET=${TENDERAI_JWT_SECRET}|" .env
              sed -i "s|^TENDERAI_ADMIN_PASSWORD=.*|TENDERAI_ADMIN_PASSWORD=${TENDERAI_ADMIN_PASSWORD}|" .env
            fi

            # Login to GitHub Container Registry
            echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin

            # Isolate staging compose project from production (separate network/volume namespaces)
            export COMPOSE_PROJECT_NAME=tenderai-staging
            export ENVIRONMENT=staging
```

Par :

```yaml
            cd \${DEPLOY_PATH}

            # Pull latest code
            git pull origin staging

            # Copy unified server override (parameterized via .env.staging)
            cp docker-compose.server.yml docker-compose.override.yml

            # Inject security credentials from GitHub Secrets into .env
            if [ -f ".env" ]; then
              sed -i 's/^POSTGRES_PORT=/#POSTGRES_PORT=/' .env
              sed -i 's/^MINIO_PORT=/#MINIO_PORT=/' .env
              sed -i 's/^MINIO_CONSOLE_PORT=/#MINIO_CONSOLE_PORT=/' .env
              sed -i 's/^API_PORT=/#API_PORT=/' .env
              sed -i 's/^UI_PORT=/#UI_PORT=/' .env
              sed -i "s|^TENDERAI_JWT_SECRET=.*|TENDERAI_JWT_SECRET=${TENDERAI_JWT_SECRET}|" .env
              sed -i "s|^TENDERAI_ADMIN_PASSWORD=.*|TENDERAI_ADMIN_PASSWORD=${TENDERAI_ADMIN_PASSWORD}|" .env
            fi

            # Login to GitHub Container Registry
            echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin

            # Load orchestration variables (ENV_NAME, IMAGE_TAG, COMPOSE_PROJECT_NAME, etc.)
            set -a; source .env.staging; set +a
```

- [ ] **Step 2 : Remplacer tous les `docker compose` du job staging par `docker compose --env-file .env.staging`**

- `docker compose down --remove-orphans` → `docker compose --env-file .env.staging down --remove-orphans`
- `docker compose pull api frontend worker` → `docker compose --env-file .env.staging pull api frontend worker`
- `docker compose up -d postgres minio createbuckets` → `docker compose --env-file .env.staging up -d postgres minio createbuckets`
- `docker compose exec -T postgres pg_isready ...` → `docker compose --env-file .env.staging exec -T postgres pg_isready ...`
- `docker compose exec -T minio curl ...` → `docker compose --env-file .env.staging exec -T minio curl ...`
- `docker compose run --no-deps --rm api alembic upgrade head` → `docker compose --env-file .env.staging run --no-deps --rm api alembic upgrade head`
- `docker compose run --no-deps --rm api tenderai create-admin` → `docker compose --env-file .env.staging run --no-deps --rm api tenderai create-admin`
- `docker compose run --no-deps --rm api tenderai seed-sources` → `docker compose --env-file .env.staging run --no-deps --rm api tenderai seed-sources`
- `docker compose up -d api frontend worker nginx` → `docker compose --env-file .env.staging up -d api frontend worker nginx`

- [ ] **Step 3 : Commit**

```bash
git add .github/workflows/ci-cd.yml
git commit -m "feat(ci): use docker-compose.server.yml and --env-file .env.staging in staging deploy"
```

---

### Task 6 : Supprimer les fichiers obsolètes

**Files:**
- Delete: `docker-compose.override.prod.yml`
- Delete: `docker-compose.override.staging.yml`
- Delete: `infra/nginx/nginx.staging.conf`

- [ ] **Step 1 : Supprimer les fichiers**

```bash
git rm docker-compose.override.prod.yml
git rm docker-compose.override.staging.yml
git rm infra/nginx/nginx.staging.conf
```

- [ ] **Step 2 : Vérifier qu'aucune référence résiduelle ne subsiste**

```bash
grep -r "docker-compose.override.prod.yml\|docker-compose.override.staging.yml\|nginx.staging.conf" \
  --include="*.yml" --include="*.yaml" --include="*.sh" --include="*.md" .
```

Expected: aucun résultat.

- [ ] **Step 3 : Commit**

```bash
git commit -m "chore(infra): remove obsolete per-env override and nginx conf files"
```

---

### Task 7 : Setup manuel sur le serveur (one-time)

Cette tâche est exécutée **manuellement** par l'administrateur, pas par la CI. Elle n'est à faire qu'une fois par environnement.

- [ ] **Step 1 : Créer `.env.prod` sur le serveur de production**

```bash
sudo -u tender-ai bash -c "
  cp /opt/tenderai-bf/.env.prod.example /opt/tenderai-bf/.env.prod
  # Vérifier que les valeurs sont correctes
  cat /opt/tenderai-bf/.env.prod
"
```

- [ ] **Step 2 : Créer `.env.staging` sur le serveur de staging**

```bash
sudo -u tender-ai bash -c "
  cp /opt/tenderai-bf-staging/.env.staging.example /opt/tenderai-bf-staging/.env.staging
  cat /opt/tenderai-bf-staging/.env.staging
"
```

- [ ] **Step 3 : Vérifier le fonctionnement du template nginx en local (optionnel)**

```bash
# Test du mécanisme envsubst — doit afficher la config avec le bon domaine
docker run --rm \
  -e DOMAIN=tender-ai.yulcom.net \
  -e NGINX_ENVSUBST_TEMPLATE_VARS=DOMAIN \
  -v "$(pwd)/infra/nginx/templates:/etc/nginx/templates:ro" \
  nginx:alpine \
  /bin/sh -c "
    envsubst '\${DOMAIN}' < /etc/nginx/templates/default.conf.template | grep server_name
  "
```

Expected:
```
    server_name tender-ai.yulcom.net;
    server_name tender-ai.yulcom.net;
```

---

## Récapitulatif des variables par environnement

| Variable | Production | Staging |
|---|---|---|
| `ENV_NAME` | `prod` | `staging` |
| `COMPOSE_PROJECT_NAME` | `tenderai-prod` | `tenderai-staging` |
| `DOMAIN` | `tender-ai.yulcom.net` | `staging.tender-ai.yulcom.net` |
| `NGINX_HTTP_PORT` | `18080` | `19080` |
| `NGINX_HTTPS_PORT` | `18443` | `19443` |
| `IMAGE_TAG` | `latest` | `staging` |
| `ENVIRONMENT` | `production` | `staging` |
