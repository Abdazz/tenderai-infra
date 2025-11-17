#!/bin/bash
# Script to update Apache2 configuration for TenderAI BF
# Run this on the production server after deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "🔧 Updating Apache2 configuration for TenderAI BF"
echo "=================================================="
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo "❌ Please run this script as a regular user (not root)"
    echo "   The script will use sudo when needed"
    exit 1
fi

# Check if Apache2 is installed
if ! command -v apache2 &> /dev/null; then
    echo "❌ Apache2 is not installed"
    exit 1
fi

# Enable required modules
echo "📦 Enabling required Apache2 modules..."
sudo a2enmod proxy proxy_http proxy_wstunnel ssl headers rewrite 2>/dev/null || true
echo "✅ Modules enabled"
echo ""

# Backup existing configuration if it exists
if [ -f /etc/apache2/sites-available/tender-ai.yulcom.net.conf ]; then
    BACKUP_FILE="/etc/apache2/sites-available/tender-ai.yulcom.net.conf.backup.$(date +%Y%m%d_%H%M%S)"
    echo "💾 Backing up existing configuration to:"
    echo "   $BACKUP_FILE"
    sudo cp /etc/apache2/sites-available/tender-ai.yulcom.net.conf "$BACKUP_FILE"
    echo "✅ Backup created"
    echo ""
fi

# Copy new configuration
echo "📝 Copying new Apache2 configuration..."
sudo cp "$PROJECT_DIR/infra/apache2/tender-ai.yulcom.net.conf" /etc/apache2/sites-available/tender-ai.yulcom.net.conf
echo "✅ Configuration copied"
echo ""

# Test configuration
echo "🔍 Testing Apache2 configuration..."
if sudo apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
    echo "✅ Configuration is valid"
    echo ""
else
    echo "❌ Configuration test failed!"
    sudo apache2ctl configtest
    exit 1
fi

# Reload Apache2
echo "🔄 Reloading Apache2..."
sudo systemctl reload apache2
echo "✅ Apache2 reloaded"
echo ""

# Check if site is enabled
if [ -L /etc/apache2/sites-enabled/tender-ai.yulcom.net.conf ]; then
    echo "✅ Site is already enabled"
else
    echo "⚠️  Site is not enabled yet. Run:"
    echo "   sudo a2ensite tender-ai.yulcom.net"
    echo "   sudo systemctl reload apache2"
fi
echo ""

# Check if Nginx Docker is running
echo "🐳 Checking Nginx Docker container..."
cd "$PROJECT_DIR"
if docker-compose ps nginx 2>/dev/null | grep -q "Up"; then
    echo "✅ Nginx Docker container is running"
    
    # Test connection to Nginx Docker
    echo ""
    echo "🔗 Testing connection to Nginx Docker..."
    if curl -sf http://localhost:8080/health > /dev/null 2>&1; then
        echo "✅ Nginx Docker is responding on localhost:8080"
    else
        echo "⚠️  Warning: Cannot connect to Nginx Docker on localhost:8080"
        echo "   Make sure the container is fully started"
    fi
else
    echo "⚠️  Warning: Nginx Docker container is not running"
    echo "   Start it with: docker-compose up -d nginx"
fi
echo ""

echo "=================================================="
echo "✅ Apache2 configuration update complete!"
echo ""
echo "Next steps:"
echo "1. Test internal access: curl -I http://localhost:8080/health"
echo "2. Test external access: curl -I https://tender-ai.yulcom.net/health"
echo ""
echo "View logs:"
echo "  Apache2: sudo tail -f /var/log/apache2/tender-ai.yulcom.net-ssl-error.log"
echo "  Nginx:   docker-compose logs -f nginx"
echo ""
