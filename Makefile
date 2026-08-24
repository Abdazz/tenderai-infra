.PHONY: help up down logs deploy deploy-staging backup

help: ## Show this help message
	@echo "TenderAI BF Infra - Makefile Commands"
	@echo "======================================"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

up: ## Start full stack (requires ../tenderai-backend and ../tenderai-frontend siblings)
	docker-compose up -d

down: ## Stop full stack
	docker-compose down

logs: ## Show logs from all services
	docker-compose logs -f

rebuild: ## Rebuild and restart full stack
	docker-compose down
	docker-compose build --no-cache
	docker-compose up -d

health: ## Check service health
	@curl -f http://localhost:8000/health || echo "API not responding"
	@curl -f http://localhost:3000 || echo "Frontend not responding"

ps: ## Show running containers
	docker-compose ps

deploy: ## Deploy to production (main branch)
	./scripts/deploy.sh main deploy

deploy-staging: ## Deploy to staging
	./scripts/deploy.sh develop deploy

deploy-status: ## Show deployment status
	./scripts/deploy.sh main status

deploy-logs: ## Show deployment logs (default: api)
	./scripts/deploy.sh main logs api

backup: ## Create database backup
	./scripts/deploy.sh main backup

clean-docker: ## Clean up Docker resources
	docker-compose down -v --remove-orphans
	docker system prune -f
