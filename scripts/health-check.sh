#!/bin/bash
# N8N Production Health Check Script
# Comprehensive system health verification

set -euo pipefail

# Load common utilities and health check functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/health-checks.sh"

# Configuration
LOG_FILE="${PROJECT_ROOT}/volumes/logs/health-check.log"

# Health check results
CHECKS_PASSED=0
CHECKS_FAILED=0
WARNINGS=0

# Load environment
if [ -f "${PROJECT_ROOT}/.env" ]; then
    source "${PROJECT_ROOT}/.env"
fi

# Initialize common environment
init_common
change_to_project_root

# Use standardized health check function from lib/health-checks.sh
# The perform_health_check function provides consistent interface and error handling

# Header with improved styling
print_script_header "N8N Production Health Check" "Comprehensive system health verification"

# 1. Docker Services Check
echo -e "\n${BLUE}1. Docker Services${NC}"
echo "-------------------"

# Check if Docker is running
if perform_health_check "Docker daemon" "check_docker_daemon"; then
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# Check if docker compose is available  
if perform_health_check "Docker Compose" "check_docker_compose"; then
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# Check each service using improved service detection
for service in postgres n8n nginx redis; do
    if perform_health_check "${service} container" "check_service_running $service"; then
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
done

# 2. Application Health
echo -e "\n${BLUE}2. Application Health${NC}"
echo "---------------------"

# Use standardized health check functions from library
if perform_health_check "N8N health endpoint" "check_n8n_health_endpoint"; then
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

result=$(perform_health_check "N8N metrics endpoint" "check_n8n_metrics_endpoint" false)
case $? in
    0) CHECKS_PASSED=$((CHECKS_PASSED + 1)) ;;
    2) WARNINGS=$((WARNINGS + 1)) ;;
esac

# Check N8N version safely
if is_service_running "n8n"; then
    N8N_VERSION=$(docker_exec_safe n8n n8n --version 2>/dev/null | tr -d '\r' || echo "unknown")
else
    N8N_VERSION="service not running"
fi
echo "N8N Version: ${N8N_VERSION}"

# 3. Database Health
echo -e "\n${BLUE}3. Database Health${NC}"
echo "------------------"

# Use standardized database health check
if perform_health_check "PostgreSQL connection" "check_postgresql_connection"; then
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# Database size check
if is_service_running "postgres"; then
    postgres_user="${POSTGRES_USER:-n8n_admin}"
    DB_SIZE=$(docker_exec_safe postgres psql -U "$postgres_user" -d "${POSTGRES_DB:-n8n}" -t -c "SELECT pg_size_pretty(pg_database_size('${POSTGRES_DB:-n8n}'));" 2>/dev/null | tr -d ' \r\n' || echo "unknown")
else
    DB_SIZE="service not running"
fi
echo "Database size: ${DB_SIZE}"

# Check for long-running queries
if is_service_running "postgres"; then
    postgres_user="${POSTGRES_USER:-n8n_admin}"
    LONG_QUERIES=$(docker_exec_safe postgres psql -U "$postgres_user" -d "${POSTGRES_DB:-n8n}" -t -c "SELECT count(*) FROM pg_stat_activity WHERE state != 'idle' AND query_start < now() - interval '5 minutes';" 2>/dev/null | tr -d ' \r\n' || echo "0")
    if [ "${LONG_QUERIES}" -gt 0 ]; then
        echo -e "${YELLOW}${WARNING} Warning: ${LONG_QUERIES} long-running queries detected${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo "Skipping long-running queries check (PostgreSQL not running)"
fi

# 4. Redis Health (if enabled)
if [ "${ENABLE_REDIS_CACHE:-true}" = "true" ]; then
    echo -e "\n${BLUE}4. Redis Health${NC}"
    echo "---------------"
    
    # Use standardized Redis health check
    if perform_health_check "Redis connection" "check_redis_connection"; then
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
    
    # Get Redis memory usage
    if is_service_running "redis"; then
        redis_password=$(read_secret "redis_password")
        REDIS_MEMORY=$(docker_exec_safe redis redis-cli --pass "$redis_password" INFO memory 2>/dev/null | grep used_memory_human | cut -d: -f2 | tr -d '\r' || echo "unknown")
    else
        REDIS_MEMORY="service not running"
    fi
    echo "Redis memory usage: ${REDIS_MEMORY}"
fi

# 5. Web Server Health
echo -e "\n${BLUE}5. Web Server Health${NC}"
echo "--------------------"

# Use standardized Nginx health check
if perform_health_check "Nginx configuration" "check_nginx_configuration"; then
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# Check HTTPS endpoint (if accessible)
if [ -n "${N8N_HOST:-}" ]; then
    result=$(perform_health_check "HTTPS endpoint" "check_https_endpoint" false)
    case $? in
        0) CHECKS_PASSED=$((CHECKS_PASSED + 1)) ;;
        2) WARNINGS=$((WARNINGS + 1)) ;;
    esac
fi

# 6. System Resources
echo -e "\n${BLUE}6. System Resources${NC}"
echo "-------------------"

# Disk space
DISK_USAGE=$(df -h "${PROJECT_ROOT}" | awk 'NR==2 {print $5}' | sed 's/%//')
echo -n "Disk usage: ${DISK_USAGE}% "
if [ "${DISK_USAGE}" -gt 90 ]; then
    echo -e "${RED}(Critical)${NC}"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
elif [ "${DISK_USAGE}" -gt 80 ]; then
    echo -e "${YELLOW}(Warning)${NC}"
    WARNINGS=$((WARNINGS + 1))
else
    echo -e "${GREEN}(OK)${NC}"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
fi

# Memory usage
MEMORY_STATS=$(docker stats --no-stream --format "table {{.Container}}\t{{.MemUsage}}\t{{.MemPerc}}" | grep -E 'n8n|postgres|redis|nginx' || true)
echo -e "\nContainer Memory Usage:"
echo "${MEMORY_STATS}"

# 7. SSL Certificate (if Nginx is running)
echo -e "\n${BLUE}7. SSL Certificate${NC}"
echo "------------------"

if docker compose ps nginx | grep -q "Up"; then
    # Check certificate expiration
    CERT_FILE="${PROJECT_ROOT}/nginx/ssl/fullchain.pem"
    if [ -f "${CERT_FILE}" ]; then
        EXPIRY_DATE=$(openssl x509 -enddate -noout -in "${CERT_FILE}" | cut -d= -f2)
        EXPIRY_EPOCH=$(date -d "${EXPIRY_DATE}" +%s)
        CURRENT_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))
        
        echo -n "SSL certificate expires in ${DAYS_LEFT} days "
        if [ "${DAYS_LEFT}" -lt 7 ]; then
            echo -e "${RED}(Critical - Renew immediately!)${NC}"
            CHECKS_FAILED=$((CHECKS_FAILED + 1))
        elif [ "${DAYS_LEFT}" -lt 30 ]; then
            echo -e "${YELLOW}(Warning - Renew soon)${NC}"
            WARNINGS=$((WARNINGS + 1))
        else
            echo -e "${GREEN}(OK)${NC}"
            CHECKS_PASSED=$((CHECKS_PASSED + 1))
        fi
    else
        echo -e "${YELLOW}SSL certificate file not found${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# 8. Backup Status
echo -e "\n${BLUE}8. Backup Status${NC}"
echo "----------------"

BACKUP_DIR="${PROJECT_ROOT}/volumes/backups"
if [ -d "${BACKUP_DIR}" ]; then
    LATEST_BACKUP=$(ls -t "${BACKUP_DIR}" | grep -E '^[0-9]{8}_[0-9]{6}$' | head -1 || echo "")
    if [ -n "${LATEST_BACKUP}" ]; then
        BACKUP_AGE=$(( ($(date +%s) - $(stat -c %Y "${BACKUP_DIR}/${LATEST_BACKUP}")) / 3600 ))
        echo -n "Last backup: ${LATEST_BACKUP} (${BACKUP_AGE} hours ago) "
        
        if [ "${BACKUP_AGE}" -gt 48 ]; then
            echo -e "${RED}(Overdue)${NC}"
            CHECKS_FAILED=$((CHECKS_FAILED + 1))
        elif [ "${BACKUP_AGE}" -gt 25 ]; then
            echo -e "${YELLOW}(Due soon)${NC}"
            WARNINGS=$((WARNINGS + 1))
        else
            echo -e "${GREEN}(OK)${NC}"
            CHECKS_PASSED=$((CHECKS_PASSED + 1))
        fi
    else
        echo -e "${RED}No backups found!${NC}"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
else
    echo -e "${RED}Backup directory not found!${NC}"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# 9. Monitoring Stack (if enabled)
if [ "${ENABLE_MONITORING:-true}" = "true" ]; then
    echo -e "\n${BLUE}9. Monitoring Stack${NC}"
    echo "-------------------"
    
    # Use standardized monitoring health checks
    result=$(perform_health_check "Prometheus" "check_prometheus_health" false)
    case $? in
        0) CHECKS_PASSED=$((CHECKS_PASSED + 1)) ;;
        2) WARNINGS=$((WARNINGS + 1)) ;;
    esac
    
    result=$(perform_health_check "Grafana" "check_grafana_health" false)
    case $? in
        0) CHECKS_PASSED=$((CHECKS_PASSED + 1)) ;;
        2) WARNINGS=$((WARNINGS + 1)) ;;
    esac
    
    result=$(perform_health_check "Loki" "check_loki_health" false)
    case $? in
        0) CHECKS_PASSED=$((CHECKS_PASSED + 1)) ;;
        2) WARNINGS=$((WARNINGS + 1)) ;;
    esac
fi

# Summary
echo -e "\n${BLUE}Health Check Summary${NC}"
echo "===================="
echo -e "Checks passed: ${GREEN}${CHECKS_PASSED}${NC}"
echo -e "Checks failed: ${RED}${CHECKS_FAILED}${NC}"
echo -e "Warnings: ${YELLOW}${WARNINGS}${NC}"

# Overall status
if [ "${CHECKS_FAILED}" -eq 0 ]; then
    if [ "${WARNINGS}" -eq 0 ]; then
        echo -e "\nOverall status: ${GREEN}HEALTHY${NC}"
        EXIT_CODE=0
    else
        echo -e "\nOverall status: ${YELLOW}HEALTHY WITH WARNINGS${NC}"
        EXIT_CODE=0
    fi
else
    echo -e "\nOverall status: ${RED}UNHEALTHY${NC}"
    EXIT_CODE=1
fi

# Log summary
log_info "Health check completed: Passed=${CHECKS_PASSED}, Failed=${CHECKS_FAILED}, Warnings=${WARNINGS}"

# Create status file for external monitoring using safer service checks
cat > "${PROJECT_ROOT}/health-status.json" << EOF
{
  "timestamp": "$(get_readable_date)",
  "status": $([ ${EXIT_CODE} -eq 0 ] && echo '"healthy"' || echo '"unhealthy"'),
  "checks": {
    "passed": ${CHECKS_PASSED},
    "failed": ${CHECKS_FAILED},
    "warnings": ${WARNINGS}
  },
  "services": {
    "n8n": $(is_service_running "n8n" && echo '"up"' || echo '"down"'),
    "postgres": $(is_service_running "postgres" && echo '"up"' || echo '"down"'),
    "nginx": $(is_service_running "nginx" && echo '"up"' || echo '"down"'),
    "redis": $(is_service_running "redis" && echo '"up"' || echo '"down"')
  },
  "script_version": "${COMMON_LIB_VERSION}"
}
EOF

# Final script completion
print_script_footer "N8N Health Check"

exit ${EXIT_CODE}