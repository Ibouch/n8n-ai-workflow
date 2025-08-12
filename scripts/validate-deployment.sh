#!/bin/bash
# N8N Deployment Validation Script
# Verifies security configuration and service health

set -euo pipefail

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/health-checks.sh"

# Initialize common environment
init_common
change_to_project_root

print_script_header "N8N Security Deployment Validation" "Comprehensive security and configuration verification"

# Validation results tracking
VALIDATION_PASSED=0
VALIDATION_FAILED=0
VALIDATION_WARNINGS=0

# Enhanced validation function
validate_check() {
    local check_name="$1"
    local check_function="$2"
    local is_critical="${3:-true}"
    
    echo -n "Validating ${check_name}... "
    
    if eval "$check_function" >/dev/null 2>&1; then
        echo -e "${GREEN}${CHECKMARK} PASS${NC}"
        VALIDATION_PASSED=$((VALIDATION_PASSED + 1))
        return 0
    else
        if [ "$is_critical" = "true" ]; then
            echo -e "${RED}${CROSS} FAIL${NC}"
            VALIDATION_FAILED=$((VALIDATION_FAILED + 1))
        else
            echo -e "${YELLOW}${WARNING} WARN${NC}"
            VALIDATION_WARNINGS=$((VALIDATION_WARNINGS + 1))
        fi
        return 1
    fi
}

# 1. Docker Environment Validation
info "Docker Environment:"
validate_check "Docker daemon" "check_docker_daemon"
validate_check "Docker Compose" "check_docker_compose"
validate_check "Docker Compose configuration" "check_compose_config"

# 2. Project Structure Validation
info "Project Structure:"
validate_check "Project structure" "validate_project_structure"
validate_check "Secrets configuration" "validate_secrets"

# 3. Environment Validation
info "Environment Variables:"
validate_check "N8N environment" "validate_n8n_env" false

# Additional secret validation
secret_count=$(find "${SECRETS_DIR}" -name "*.txt" 2>/dev/null | wc -l)
if [ "$secret_count" -ge 9 ]; then
    log_success "Secrets are properly configured ($secret_count files found)"
else
    warn "Some secrets may be missing (found $secret_count, expected 9)"
    VALIDATION_WARNINGS=$((VALIDATION_WARNINGS + 1))
fi

# 4. Service Status Validation
info "Service Status:"
for service in postgres n8n nginx redis; do
    validate_check "$service service" "check_service_running $service" false
done

# 5. Health Check Validation
info "Application Health:"
validate_check "N8N health endpoint" "check_n8n_health_endpoint" false
validate_check "PostgreSQL connection" "check_postgresql_connection" false
validate_check "Redis connection" "check_redis_connection" false
validate_check "Nginx configuration" "check_nginx_configuration" false

# Check container security configuration
info "Validating container security..."

# Check for non-root users (helper)
check_container_user() {
    local container="$1"
    local expected_user="$2"
    if docker compose ps -q "$container" >/dev/null 2>&1; then
        local actual_user=$(docker inspect "$(docker compose ps -q "$container" 2>/dev/null)" --format '{{.Config.User}}' 2>/dev/null || echo "")
        if [ "$actual_user" = "$expected_user" ]; then
            log "$container running as non-root user ($actual_user)"
        else
            warn "$container user configuration: expected '$expected_user', got '$actual_user'"
        fi
    fi
}

check_container_user "postgres" "70:70"
check_container_user "n8n" "1000:1000"
check_container_user "nginx" "101:101"
check_container_user "redis" "999:999"

# Check read-only filesystems
info "Checking read-only filesystem configuration..."
readonly_services=("postgres" "n8n" "nginx" "redis")
for service in "${readonly_services[@]}"; do
    if docker compose ps -q "$service" >/dev/null 2>&1; then
        readonly_status=$(docker inspect "$(docker compose ps -q "$service" 2>/dev/null)" --format '{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null || echo "false")
        if [ "$readonly_status" = "true" ]; then
            log "$service has read-only filesystem enabled"
        else
            warn "$service does not have read-only filesystem enabled"
        fi
    fi
done

# Check security options
info "Checking security options..."
for service in "${readonly_services[@]}"; do
    if docker compose ps -q "$service" >/dev/null 2>&1; then
        security_opts=$(docker inspect "$(docker compose ps -q "$service" 2>/dev/null)" --format '{{range .HostConfig.SecurityOpt}}{{.}} {{end}}' 2>/dev/null || echo "")
        if echo "$security_opts" | grep -q "no-new-privileges"; then
            log "$service has no-new-privileges enabled"
        else
            warn "$service missing no-new-privileges option"
        fi
    fi
done

# Check network configuration
info "Validating network configuration..."
networks=$(docker network ls --format "{{.Name}}" | grep -E "(n8n-frontend|n8n-backend)" | wc -l)
if [ "$networks" -ge 2 ]; then
    log "Network segmentation is configured ($networks networks found)"
else
    warn "Network segmentation may not be properly configured"
fi

# Check SSL certificates (if nginx is running)
if docker compose ps nginx 2>/dev/null | grep -q "Up"; then
    info "Checking SSL configuration..."
    if [ -f "nginx/ssl/fullchain.pem" ] && [ -f "nginx/ssl/key.pem" ]; then
        log "SSL certificates are present"
        
        # Check certificate validity (expires > 30d)
        if openssl x509 -in nginx/ssl/fullchain.pem -noout -checkend 2592000 >/dev/null 2>&1; then
            cert_days="valid"
        else
            cert_days="expiring"
        fi
        if [ "$cert_days" = "valid" ]; then
            log "SSL certificate is valid for >30 days"
        else
            warn "SSL certificate expires within 30 days"
        fi
    else
        warn "SSL certificates not found in nginx/ssl/"
    fi
fi

# Check monitoring (if production compose is running)
if docker compose -f compose.yml -f compose.prod.yml ps prometheus 2>/dev/null | grep -q "Up"; then
    info "Checking monitoring stack..."
    log "Prometheus is running"
    
    if docker compose -f compose.yml -f compose.prod.yml ps grafana 2>/dev/null | grep -q "Up"; then
        log "Grafana is running"
    fi
    
    if docker compose -f compose.yml -f compose.prod.yml ps alertmanager 2>/dev/null | grep -q "Up"; then
        log "Alertmanager is running"
    fi
fi

# Check AppArmor profiles (if available)
if command -v aa-status >/dev/null 2>&1; then
    info "Checking AppArmor profiles..."
    if aa-status 2>/dev/null | grep -E "(n8n-profile|postgres-profile|nginx-profile)" >/dev/null; then
        log "AppArmor profiles are loaded"
    else
        warn "AppArmor profiles not found (run sudo ./scripts/setup-security.sh)"
    fi
fi

# Final validation summary
echo ""
echo -e "${BLUE}=== Security Validation Summary ===${NC}"
echo "====================================="
echo -e "Validations passed: ${GREEN}$VALIDATION_PASSED${NC}"
echo -e "Validations failed: ${RED}$VALIDATION_FAILED${NC}"
echo -e "Warnings: ${YELLOW}$VALIDATION_WARNINGS${NC}"

# Overall security score
total_checks=$((VALIDATION_PASSED + VALIDATION_FAILED + VALIDATION_WARNINGS))
if [ $total_checks -gt 0 ]; then
    security_score=$(( (VALIDATION_PASSED * 100) / total_checks ))
    echo -e "Security Score: ${security_score}%"
fi

# Overall status
if [ $VALIDATION_FAILED -eq 0 ]; then
    if [ $VALIDATION_WARNINGS -eq 0 ]; then
        echo -e "\nOverall Status: ${GREEN}SECURE${NC}"
        exit_code=0
    else
        echo -e "\nOverall Status: ${YELLOW}SECURE WITH WARNINGS${NC}"
        exit_code=0
    fi
else
    echo -e "\nOverall Status: ${RED}SECURITY ISSUES DETECTED${NC}"
    exit_code=1
fi

# Create validation report
create_validation_report() {
    cat > "${PROJECT_ROOT}/validation-report.json" << EOF
{
  "timestamp": "$(get_readable_date)",
  "validation_summary": {
    "passed": $VALIDATION_PASSED,
    "failed": $VALIDATION_FAILED,
    "warnings": $VALIDATION_WARNINGS,
    "security_score": ${security_score:-0}
  },
  "docker_environment": {
    "docker_version": "$(docker --version 2>/dev/null | cut -d' ' -f3 || echo 'unknown')",
    "compose_version": "$(docker compose --version 2>/dev/null | cut -d' ' -f3 || echo 'unknown')"
  },
  "services": {
    "n8n": "$(is_service_running "n8n" && echo "running" || echo "stopped")",
    "postgres": "$(is_service_running "postgres" && echo "running" || echo "stopped")",
    "nginx": "$(is_service_running "nginx" && echo "running" || echo "stopped")",
    "redis": "$(is_service_running "redis" && echo "running" || echo "stopped")"
  },
  "secrets_count": $secret_count,
  "script_version": "${COMMON_LIB_VERSION}"
}
EOF
}

create_validation_report

echo ""
info "Next steps:"
if [ $VALIDATION_FAILED -gt 0 ]; then
    echo "  ${CROSS} CRITICAL: Fix the failed validation checks immediately"
fi
if [ $VALIDATION_WARNINGS -gt 0 ]; then
    echo "  ${WARNING} Review and address warnings when possible"
fi
echo "  1. Test application functionality: https://\${N8N_HOST:-localhost}"
echo "  2. Review monitoring dashboards (if running)"
echo "  3. Set up automated backups and monitoring"
echo "  4. Monitor security logs regularly"
echo "  5. Keep system and container images updated"

info "Validation report saved to: ${PROJECT_ROOT}/validation-report.json"

echo ""
echo -e "${BLUE}🛡️ Security is a continuous process - keep monitoring and updating!${NC}"

print_script_footer "N8N Security Validation"

exit $exit_code