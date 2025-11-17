#!/bin/bash
# Diagnostic script for TenderAI BF deployment
# Run this on the production server to troubleshoot issues

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "🔍 TenderAI BF Diagnostic Report"
echo "================================="
echo ""

# Check if running as regular user
if [ "$EUID" -eq 0 ]; then
    echo "❌ Please run this script as a regular user (not root)"
    exit 1
fi

cd "$PROJECT_DIR"

echo "📊 System Information:"
echo "  Date: $(date)"
echo "  User: $(whoami)"
echo "  Hostname: $(hostname)"
echo "  OS: $(lsb_release -d 2>/dev/null | cut -f2 || uname -s)"
echo ""

echo "🐳 Docker Status:"
echo "  Docker version: $(docker --version 2>/dev/null || echo 'Not found')"
echo "  Docker Compose version: $(docker-compose --version 2>/dev/null || echo 'Not found')"
echo ""

echo "🐳 Docker Containers:"
docker-compose ps
echo ""

echo "🌐 Network Status:"
echo "  Port 80 (Apache2): $(sudo netstat -tlnp 2>/dev/null | grep :80 | head -1 || echo 'Not listening')"
echo "  Port 443 (Apache2): $(sudo netstat -tlnp 2>/dev/null | grep :443 | head -1 || echo 'Not listening')"
echo "  Port 18080 (Nginx HTTP): $(sudo netstat -tlnp 2>/dev/null | grep :18080 | head -1 || echo 'Not listening')"
echo "  Port 18443 (Nginx HTTPS): $(sudo netstat -tlnp 2>/dev/null | grep :18443 | head -1 || echo 'Not listening')"
echo ""

echo "🔒 SSL Certificates:"
if [ -f "/etc/letsencrypt/live/tender-ai.yulcom.net/fullchain.pem" ]; then
    echo "  ✅ Certificate exists"
    echo "  Expires: $(openssl x509 -in /etc/letsencrypt/live/tender-ai.yulcom.net/fullchain.pem -noout -enddate 2>/dev/null | cut -d= -f2 || echo 'Unknown')"
else
    echo "  ❌ Certificate not found at /etc/letsencrypt/live/tender-ai.yulcom.net/fullchain.pem"
fi
echo ""

echo "🌐 Connectivity Tests:"
echo "  Testing Nginx Docker (internal)..."
if curl -k -s https://localhost:18443/health > /dev/null 2>&1; then
    echo "  ✅ Nginx Docker (18443) responds"
else
    echo "  ❌ Nginx Docker (18443) not responding"
    echo "     Trying HTTP fallback..."
    if curl -s http://localhost:18080/health > /dev/null 2>&1; then
        echo "     ⚠️  Nginx HTTP (18080) responds but HTTPS (18443) doesn't"
    else
        echo "     ❌ Neither HTTP nor HTTPS responding"
    fi
fi

echo "  Testing Apache2 proxy (external)..."
if curl -s -I https://tender-ai.yulcom.net/health 2>/dev/null | grep -q "200\|301\|302"; then
    echo "  ✅ External access works"
else
    echo "  ❌ External access fails"
fi
echo ""

echo "📝 Recent Logs:"
echo "  Apache2 errors (last 10 lines):"
sudo tail -10 /var/log/apache2/tender-ai.yulcom.net-ssl-error.log 2>/dev/null || echo "    Log file not found"
echo ""

echo "  Nginx Docker logs (last 10 lines):"
docker-compose logs --tail=10 nginx 2>/dev/null || echo "    No logs available"
echo ""

echo "🔧 Apache2 Configuration:"
echo "  Config test: $(sudo apache2ctl configtest 2>&1 | tail -1)"
echo "  Enabled modules: $(sudo apache2ctl -M 2>/dev/null | grep -E "(proxy|ssl|rewrite|headers)" | wc -l) relevant modules enabled"
echo ""

echo "💡 Recommendations:"
if ! curl -k -s https://localhost:18443/health > /dev/null 2>&1; then
    echo "  - Nginx Docker container may not be running or healthy"
    echo "  - Check: docker-compose ps nginx"
    echo "  - Restart: docker-compose restart nginx"
fi

if ! curl -s -I https://tender-ai.yulcom.net/health 2>/dev/null | grep -q "200\|301\|302"; then
    echo "  - Apache2 proxy configuration may have issues"
    echo "  - Check logs: sudo tail -f /var/log/apache2/tender-ai.yulcom.net-ssl-error.log"
    echo "  - Verify modules: sudo a2enmod proxy proxy_http proxy_wstunnel ssl headers rewrite proxy_connect"
    echo "  - Reload Apache2: sudo systemctl reload apache2"
fi

if [ ! -f "/etc/letsencrypt/live/tender-ai.yulcom.net/fullchain.pem" ]; then
    echo "  - SSL certificates missing - run certbot"
    echo "  - Command: sudo certbot --apache -d tender-ai.yulcom.net"
fi

echo ""
echo "================================="
echo "End of diagnostic report"