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

# Comprehensive AppArmor security validation
validate_apparmor_security() {
    info "Comprehensive AppArmor Security Validation:"
    
    local apparmor_checks_passed=0
    local apparmor_checks_total=8
    local apparmor_critical_failed=false
    
    # Check 1: AppArmor kernel support
    if grep -q "apparmor" /sys/kernel/security/lsm 2>/dev/null; then
        log_success "✓ AppArmor kernel support enabled"
        ((apparmor_checks_passed++))
    else
        log_error "✗ AppArmor kernel support not available"
        apparmor_critical_failed=true
    fi
    
    # Check 2: AppArmor service status
    if systemctl is-active apparmor >/dev/null 2>&1; then
        log_success "✓ AppArmor service is active"
        ((apparmor_checks_passed++))
    else
        log_error "✗ AppArmor service is not active"
        apparmor_critical_failed=true
    fi
    
    # Check 3: AppArmor profile interface availability
    if [ -f /proc/thread-self/attr/apparmor/exec ]; then
        log_success "✓ AppArmor profile interface available"
        ((apparmor_checks_passed++))
    else
        log_error "✗ AppArmor profile interface not available"
        echo "    This causes the Docker error: 'write /proc/thread-self/attr/apparmor/exec: no such file or directory'"
        apparmor_critical_failed=true
    fi
    
    # Check 4: Required AppArmor utilities
    if command -v aa-status >/dev/null 2>&1 && command -v apparmor_parser >/dev/null 2>&1; then
        log_success "✓ AppArmor utilities available"
        ((apparmor_checks_passed++))
    else
        log_error "✗ AppArmor utilities missing"
        apparmor_critical_failed=true
    fi
    
    # Check 5: N8N specific profiles loaded
    local n8n_profiles=("n8n_app_profile" "n8n_postgres_profile" "n8n_nginx_profile" "n8n_redis_profile")
    local profiles_loaded=0
    
    if command -v aa-status >/dev/null 2>&1; then
        local aa_output
        aa_output=$(aa-status 2>/dev/null || echo "")
        
        for profile in "${n8n_profiles[@]}"; do
            if echo "$aa_output" | grep -q "^   $profile"; then
                ((profiles_loaded++))
            fi
        done
        
        if [ $profiles_loaded -eq ${#n8n_profiles[@]} ]; then
            log_success "✓ All N8N AppArmor profiles loaded ($profiles_loaded/${#n8n_profiles[@]})"
            ((apparmor_checks_passed++))
        else
            log_error "✗ N8N AppArmor profiles incomplete ($profiles_loaded/${#n8n_profiles[@]} loaded)"
        fi
    else
        log_error "✗ Cannot check profile status (aa-status unavailable)"
    fi
    
    # Check 6: Container AppArmor configuration
    local container_profiles_correct=0
    local containers_with_apparmor=("n8n-postgres" "n8n-app" "n8n-nginx" "n8n-redis")
    
    for container in "${containers_with_apparmor[@]}"; do
        if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
            local apparmor_profile
            apparmor_profile=$(docker inspect "$container" --format '{{range .HostConfig.SecurityOpt}}{{if (index . | hasPrefix "apparmor=")}}{{.}}{{end}}{{end}}' 2>/dev/null || echo "")
            
            if [ -n "$apparmor_profile" ]; then
                log "    $container: $apparmor_profile"
                ((container_profiles_correct++))
            else
                warn "    $container: No AppArmor profile configured"
            fi
        fi
    done
    
    if [ $container_profiles_correct -gt 0 ]; then
        log_success "✓ Container AppArmor configuration ($container_profiles_correct containers configured)"
        ((apparmor_checks_passed++))
    else
        log_error "✗ No containers have AppArmor profiles configured"
    fi
    
    # Check 7: AppArmor denial monitoring
    if journalctl --since "1 hour ago" 2>/dev/null | grep -q "apparmor.*DENIED" 2>/dev/null; then
        warn "⚠ Recent AppArmor denials detected in logs"
        echo "    Check with: journalctl --since '1 hour ago' | grep apparmor"
    else
        log_success "✓ No recent AppArmor denials"
        ((apparmor_checks_passed++))
    fi
    
    # Check 8: Production readiness
    if [ "$apparmor_critical_failed" = false ] && [ $profiles_loaded -eq ${#n8n_profiles[@]} ] && [ $container_profiles_correct -gt 0 ]; then
        log_success "✓ AppArmor production ready"
        ((apparmor_checks_passed++))
    else
        log_error "✗ AppArmor not production ready"
    fi
    
    # AppArmor summary
    echo ""
    echo -e "${BLUE}AppArmor Security Summary:${NC}"
    echo -e "  Checks passed: ${GREEN}$apparmor_checks_passed${NC}/$apparmor_checks_total"
    echo -e "  Profiles loaded: ${GREEN}$profiles_loaded${NC}/${#n8n_profiles[@]}"
    echo -e "  Containers configured: ${GREEN}$container_profiles_correct${NC}/${#containers_with_apparmor[@]}"
    
    if [ "$apparmor_critical_failed" = true ]; then
        echo ""
        echo -e "${RED}CRITICAL AppArmor Issue Detected:${NC}"
        echo "This prevents containers from starting with AppArmor profiles."
        echo ""
        echo -e "${YELLOW}SOLUTION:${NC}"
        echo "Run the AppArmor setup script to resolve all issues and load profiles:"
        echo -e "${CYAN}  sudo ${SCRIPT_DIR}/setup-apparmor.sh${NC}"
        echo ""
        
        # Track as critical failure
        VALIDATION_FAILED=$((VALIDATION_FAILED + 1))
        return 1
    elif [ $apparmor_checks_passed -lt $apparmor_checks_total ]; then
        echo ""
        echo -e "${YELLOW}AppArmor configuration needs attention.${NC}"
        VALIDATION_WARNINGS=$((VALIDATION_WARNINGS + 1))
        return 1
    else
        echo ""
        echo -e "${GREEN}AppArmor security is properly configured.${NC}"
        VALIDATION_PASSED=$((VALIDATION_PASSED + 1))
        return 0
    fi
}

# Execute AppArmor validation
validate_apparmor_security

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