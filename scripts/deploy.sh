#!/bin/bash

# TenderAI BF - Production Deployment Script
# This script helps deploy the application on production/staging servers

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DEPLOY_DIR="/opt/tenderai-bf"
REPO_URL="https://github.com/Abdazz/Tender-AI.git"
BRANCH="${1:-main}"
REGISTRY="ghcr.io/abdazz"

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}==>${NC} $1\n"
}

check_requirements() {
    log_step "Checking requirements"
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null; then
        log_error "Docker Compose is not installed. Please install Docker Compose first."
        exit 1
    fi
    
    if ! command -v git &> /dev/null; then
        log_error "Git is not installed. Please install Git first."
        exit 1
    fi
    
    log_info "All requirements met ✓"
}

setup_deploy_dir() {
    log_step "Setting up deployment directory"
    
    if [ ! -d "$DEPLOY_DIR" ]; then
        log_info "Creating deployment directory: $DEPLOY_DIR"
        sudo mkdir -p "$DEPLOY_DIR"
        sudo chown $USER:$USER "$DEPLOY_DIR"
        
        log_info "Cloning repository..."
        git clone "$REPO_URL" "$DEPLOY_DIR"
        cd "$DEPLOY_DIR"
        git checkout "$BRANCH"
    else
        log_info "Deployment directory exists. Pulling latest changes..."
        cd "$DEPLOY_DIR"
        git fetch origin
        git checkout "$BRANCH"
        git pull origin "$BRANCH"
    fi
    
    log_info "Repository updated ✓"
}

check_env_file() {
    log_step "Checking environment configuration"
    
    if [ ! -f "$DEPLOY_DIR/.env" ]; then
        log_warn ".env file not found!"
        if [ -f "$DEPLOY_DIR/.env.example" ]; then
            log_info "Copying .env.example to .env"
            cp "$DEPLOY_DIR/.env.example" "$DEPLOY_DIR/.env"
            log_warn "Please edit .env file with your production configuration."
            log_warn "Run: nano $DEPLOY_DIR/.env"
            echo ""
            read -p "Press Enter after editing .env file..."
        else
            log_error "No .env.example found. Cannot proceed."
            exit 1
        fi
    else
        log_info ".env file exists ✓"
        
        # Check if ENVIRONMENT is set to production
        if grep -q "ENVIRONMENT=development" "$DEPLOY_DIR/.env" 2>/dev/null; then
            log_warn "ENVIRONMENT is set to 'development' in .env"
            read -p "Change to 'production'? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                sed -i 's/ENVIRONMENT=development/ENVIRONMENT=production/' "$DEPLOY_DIR/.env"
                log_info "ENVIRONMENT updated to production ✓"
            fi
        fi
    fi
}

setup_production_override() {
    log_step "Setting up production configuration"
    
    if [ -f "$DEPLOY_DIR/docker-compose.override.prod.yml" ]; then
        log_info "Copying production override file..."
        cp "$DEPLOY_DIR/docker-compose.override.prod.yml" "$DEPLOY_DIR/docker-compose.override.yml"
        log_info "Production override activated ✓"
    else
        log_warn "docker-compose.override.prod.yml not found, will use default configuration"
    fi
}

login_registry() {
    log_step "Logging in to GitHub Container Registry"
    
    if [ -z "$GITHUB_TOKEN" ]; then
        log_warn "GITHUB_TOKEN environment variable not set."
        log_info "You can get a token from: https://github.com/settings/tokens"
        read -p "Enter your GitHub Personal Access Token (or press Enter to skip): " -s token
        echo
        if [ -n "$token" ]; then
            export GITHUB_TOKEN=$token
            echo "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_ACTOR:-abdazz}" --password-stdin
            log_info "Registry login successful ✓"
        else
            log_warn "Skipping registry login. Will build images locally."
            return 1
        fi
    else
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_ACTOR:-abdazz}" --password-stdin
        log_info "Registry login successful ✓"
    fi
}

pull_images() {
    log_step "Pulling latest Docker images"
    
    cd "$DEPLOY_DIR"
    
    # Try to pull images, but don't fail if not available
    if docker-compose pull api ui worker 2>/dev/null; then
        log_info "Images pulled successfully ✓"
    else
        log_warn "Could not pull images from registry. Will build locally."
        return 1
    fi
}

start_dependencies() {
    log_step "Starting dependencies (PostgreSQL, MinIO)"
    
    cd "$DEPLOY_DIR"
    docker-compose up -d postgres minio createbuckets
    
    log_info "Waiting for database to be ready..."
    sleep 10
    
    log_info "Dependencies started ✓"
}

run_migrations() {
    log_step "Running database migrations"
    
    cd "$DEPLOY_DIR"
    
    # Ensure postgres is running
    if ! docker-compose ps postgres | grep -q "Up"; then
        log_info "Starting postgres service..."
        docker-compose up -d postgres
        sleep 10
    fi
    
    # Run migrations
    docker-compose run --rm api alembic upgrade head
    
    log_info "Migrations completed ✓"
}

deploy_services() {
    log_step "Deploying application services"
    
    cd "$DEPLOY_DIR"
    
    # Start all services (or restart if already running)
    docker-compose up -d api ui worker
    
    log_info "Services deployed ✓"
}

health_check() {
    log_step "Running health checks"
    
    log_info "Waiting for services to start..."
    sleep 30
    
    # Check API health
    local api_url="http://localhost:${API_PORT:-8000}/health"
    if curl -f "$api_url" &> /dev/null; then
        log_info "API health check: ✓"
    else
        log_error "API health check failed!"
        log_info "Showing API logs:"
        docker-compose logs --tail=50 api
        return 1
    fi
    
    # Check UI health
    local ui_url="http://localhost:${UI_PORT:-7860}"
    if curl -f "$ui_url" &> /dev/null; then
        log_info "UI health check: ✓"
    else
        log_warn "UI health check failed (may take longer to start)"
    fi
    
    log_info "Health checks completed ✓"
}

cleanup() {
    log_step "Cleaning up old Docker resources"
    
    docker image prune -f
    
    log_info "Cleanup completed ✓"
}

show_status() {
    log_step "Deployment Status"
    
    cd "$DEPLOY_DIR"
    docker-compose ps
    
    echo ""
    log_info "🚀 Deployment completed successfully!"
    echo ""
    log_info "Access points:"
    log_info "  - API: http://localhost:${API_PORT:-8000}"
    log_info "  - API Docs: http://localhost:${API_PORT:-8000}/docs"
    log_info "  - UI: http://localhost:${UI_PORT:-7860}"
    log_info "  - MinIO Console: http://localhost:${MINIO_CONSOLE_PORT:-9001}"
    echo ""
}

backup_database() {
    log_step "Creating database backup"
    
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_dir="$DEPLOY_DIR/backups"
    backup_file="$backup_dir/db_backup_$timestamp.sql"
    
    mkdir -p "$backup_dir"
    
    cd "$DEPLOY_DIR"
    
    # Check if postgres is running
    if ! docker-compose ps postgres | grep -q "Up"; then
        log_error "PostgreSQL is not running. Cannot create backup."
        return 1
    fi
    
    docker-compose exec -T postgres pg_dump -U ${DATABASE_USER:-tenderai} ${DATABASE_NAME:-tenderai_bf} > "$backup_file"
    
    # Compress backup
    gzip "$backup_file"
    
    log_info "Database backup created: ${backup_file}.gz ✓"
    
    # Keep only last 10 backups
    ls -t "$backup_dir"/db_backup_*.sql.gz | tail -n +11 | xargs -r rm
    log_info "Old backups cleaned (keeping last 10)"
}

rollback() {
    log_step "Rolling back to previous version"
    
    cd "$DEPLOY_DIR"
    
    # Show recent commits
    echo "Recent commits:"
    git log --oneline -n 10
    echo ""
    
    read -p "Enter commit hash to rollback to: " commit_hash
    
    if [ -z "$commit_hash" ]; then
        log_error "No commit hash provided. Rollback cancelled."
        exit 1
    fi
    
    # Confirm rollback
    read -p "⚠️  This will rollback the code and restart services. Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "Rollback cancelled."
        exit 0
    fi
    
    # Backup current database
    backup_database
    
    # Checkout previous version
    git checkout "$commit_hash"
    
    # Setup production override
    setup_production_override
    
    # Redeploy
    if login_registry; then
        pull_images || log_warn "Using local images"
    fi
    
    run_migrations
    deploy_services
    health_check
    
    log_info "✓ Rollback completed successfully!"
}

view_logs() {
    local service="${1:-api}"
    
    cd "$DEPLOY_DIR"
    
    log_info "Showing logs for: $service"
    log_info "Press Ctrl+C to exit"
    echo ""
    
    docker-compose logs -f --tail=100 "$service"
}

# Main deployment flow
main() {
    log_info "╔════════════════════════════════════════╗"
    log_info "║   TenderAI BF - Deployment Script     ║"
    log_info "╚════════════════════════════════════════╝"
    echo ""
    log_info "Branch: $BRANCH"
    log_info "Deploy directory: $DEPLOY_DIR"
    echo ""
    
    check_requirements
    setup_deploy_dir
    check_env_file
    setup_production_override
    
    # Ask for confirmation
    read -p "Continue with deployment? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "Deployment cancelled."
        exit 0
    fi
    
    # Backup before deployment if DB exists
    if [ -d "$DEPLOY_DIR" ] && docker-compose ps postgres 2>/dev/null | grep -q "Up"; then
        read -p "Create database backup before deployment? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            backup_database
        fi
    fi
    
    # Try to pull images from registry
    if login_registry; then
        pull_images || log_warn "Will build images locally"
    else
        log_warn "Skipping image pull, will build locally"
    fi
    
    start_dependencies
    run_migrations
    deploy_services
    health_check
    cleanup
    show_status
}

# Parse command
command="${2:-deploy}"

case "$command" in
    deploy)
        main
        ;;
    rollback)
        rollback
        ;;
    backup)
        backup_database
        ;;
    status)
        cd "$DEPLOY_DIR" 2>/dev/null || { log_error "Deploy directory not found: $DEPLOY_DIR"; exit 1; }
        docker-compose ps
        ;;
    logs)
        view_logs "${3:-api}"
        ;;
    restart)
        log_info "Restarting services..."
        cd "$DEPLOY_DIR"
        docker-compose restart "${3:-}"
        log_info "Services restarted ✓"
        ;;
    stop)
        log_info "Stopping services..."
        cd "$DEPLOY_DIR"
        docker-compose stop
        log_info "Services stopped ✓"
        ;;
    *)
        echo "TenderAI BF - Deployment Script"
        echo ""
        echo "Usage: $0 [branch] [command] [options]"
        echo ""
        echo "Commands:"
        echo "  deploy          Deploy the application (default)"
        echo "  rollback        Rollback to a previous version"
        echo "  backup          Create database backup"
        echo "  status          Show deployment status"
        echo "  logs [service]  Show logs (default: api)"
        echo "  restart [svc]   Restart services (or specific service)"
        echo "  stop            Stop all services"
        echo ""
        echo "Examples:"
        echo "  $0 main deploy              # Deploy from main branch"
        echo "  $0 develop deploy           # Deploy from develop branch"
        echo "  $0 main rollback            # Rollback to previous version"
        echo "  $0 main logs api            # View API logs"
        echo "  $0 main logs ui             # View UI logs"
        echo "  $0 main backup              # Create database backup"
        echo "  $0 main restart api         # Restart API service"
        echo ""
        exit 1
        ;;
esac
