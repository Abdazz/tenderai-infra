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

# Check if Apache2 or httpd is installed
APACHE_CMD=""
if command -v apache2 &> /dev/null; then
    APACHE_CMD="apache2"
    APACHE_CTL="apache2ctl"
    APACHE_SERVICE="apache2"
    APACHE_CONF_DIR="/etc/apache2"
    SITES_AVAILABLE="sites-available"
    SITES_ENABLED="sites-enabled"
elif command -v httpd &> /dev/null; then
    APACHE_CMD="httpd"
    APACHE_CTL="apachectl"
    APACHE_SERVICE="httpd"
    APACHE_CONF_DIR="/etc/httpd"
    SITES_AVAILABLE="conf.d"
    SITES_ENABLED="conf.d"
else
    echo "❌ Apache2/httpd is not installed"
    echo ""
    echo "To install Apache2:"
    echo "  Ubuntu/Debian: sudo apt update && sudo apt install apache2"
    echo "  CentOS/RHEL:   sudo yum install httpd"
    exit 1
fi

echo "✅ Found: $APACHE_CMD"
echo ""

# Enable required modules
echo "📦 Enabling required Apache modules..."
if [ "$APACHE_CMD" = "apache2" ]; then
    sudo a2enmod proxy proxy_http proxy_wstunnel ssl headers rewrite 2>/dev/null || true
    echo "✅ Modules enabled"
else
    echo "ℹ️  For httpd, ensure these modules are enabled in httpd.conf:"
    echo "   - mod_proxy, mod_proxy_http, mod_proxy_wstunnel"
    echo "   - mod_ssl, mod_headers, mod_rewrite"
fi
echo ""

# Backup existing configuration if it exists
CONF_FILE="$APACHE_CONF_DIR/$SITES_AVAILABLE/tender-ai.yulcom.net.conf"
if [ -f "$CONF_FILE" ]; then
    BACKUP_FILE="${CONF_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "💾 Backing up existing configuration to:"
    echo "   $BACKUP_FILE"
    sudo cp "$CONF_FILE" "$BACKUP_FILE"
    echo "✅ Backup created"
    echo ""
fi

# Copy new configuration
echo "📝 Copying new Apache configuration..."
sudo cp "$PROJECT_DIR/infra/apache2/tender-ai.yulcom.net.conf" "$CONF_FILE"
echo "✅ Configuration copied to: $CONF_FILE"
echo ""

# Test configuration
echo "🔍 Testing Apache configuration..."
if sudo $APACHE_CTL configtest 2>&1 | grep -q "Syntax OK"; then
    echo "✅ Configuration is valid"
    echo ""
else
    echo "❌ Configuration test failed!"
    sudo $APACHE_CTL configtest
    exit 1
fi

# Reload Apache
echo "🔄 Reloading Apache..."
sudo systemctl reload $APACHE_SERVICE
echo "✅ Apache reloaded"
echo ""

# Check if site is enabled (Apache2 only)
if [ "$APACHE_CMD" = "apache2" ]; then
    if [ -L "/etc/apache2/sites-enabled/tender-ai.yulcom.net.conf" ]; then
        echo "✅ Site is already enabled"
    else
        echo "⚠️  Site is not enabled yet. Run:"
        echo "   sudo a2ensite tender-ai.yulcom.net"
        echo "   sudo systemctl reload apache2"
    fi
else
    echo "ℹ️  For httpd, configuration is automatically active in conf.d/"
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
    if curl -sf http://localhost:18080/health > /dev/null 2>&1; then
        echo "✅ Nginx Docker is responding on localhost:18080"
    else
        echo "⚠️  Warning: Cannot connect to Nginx Docker on localhost:18080"
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
echo "1. Test internal access: curl -I http://localhost:18080/health"
echo "2. Test external access: curl -I https://tender-ai.yulcom.net/health"
echo ""
echo "View logs:"
echo "  Apache2: sudo tail -f /var/log/apache2/tender-ai.yulcom.net-ssl-error.log"
echo "  Nginx:   docker-compose logs -f nginx"
echo ""
