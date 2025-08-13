#!/bin/bash
# ==============================================================================
# VALIDATION LIBRARY FOR N8N INFRASTRUCTURE SCRIPTS
# ==============================================================================
# Comprehensive validation functions for configuration, dependencies, and environment
# Source this file: source "${SCRIPT_DIR}/lib/validation.sh"

# Note: This file depends on common.sh being loaded first

# ==============================================================================
# DEPENDENCY VALIDATION
# ==============================================================================

# Validate critical system dependencies
validate_system_dependencies() {
    local missing_deps=()
    
    # Essential system tools
    local required_commands=(
        "docker"
        # Prefer the integrated Docker Compose (docker compose). Keep docker-compose for legacy hosts.
        "docker"
        "openssl"
        "tar"
        "gzip"
        "curl"
        "wget"
        "find"
        "grep"
        "awk"
        "sed"
    )
    
    log_info "Validating system dependencies..."
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        error_exit "Missing required system dependencies: ${missing_deps[*]}"
    fi
    
    log_success "All required system dependencies are available"
}

# Validate Docker environment
validate_docker_environment() {
    log_info "Validating Docker environment..."
    
    # Check Docker daemon
    if ! docker info >/dev/null 2>&1; then
        error_exit "Docker daemon is not running or not accessible"
    fi
    
    # Check Docker version (minimum 20.10.0)
    local docker_version
    docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")
    
    if ! version_compare "$docker_version" "20.10.0"; then
        warn "Docker version $docker_version is older than recommended (20.10.0+)"
    fi
    
    # Check Docker Compose availability and version (minimum 2.0.0)
    if docker compose version >/dev/null 2>&1; then
        local compose_version
        compose_version=$(docker compose version --short 2>/dev/null || echo "0.0.0")
        if ! version_compare "$compose_version" "2.0.0"; then
            warn "Docker Compose version $compose_version is older than recommended (2.0.0+)"
        fi
    elif command -v docker-compose >/dev/null 2>&1; then
        warn "Legacy docker-compose detected. Please migrate to 'docker compose' v2+"
    else
        error_exit "Docker Compose not available. Install Docker Compose v2 (docker compose)"
    fi
    
    # Check Docker permissions
    if ! docker ps >/dev/null 2>&1; then
        error_exit "Cannot access Docker. Check permissions or run as root/with sudo"
    fi
    
    log_success "Docker environment validation passed"
}

# Version comparison function (returns 0 if version1 >= version2)
version_compare() {
    local version1="$1"
    local version2="$2"
    
    # Convert versions to comparable numbers
    local ver1_num ver2_num
    ver1_num=$(echo "$version1" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}' | sed 's/^0*//')
    ver2_num=$(echo "$version2" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}' | sed 's/^0*//')
    
    [ "${ver1_num:-0}" -ge "${ver2_num:-0}" ]
}

# ==============================================================================
# CONFIGURATION VALIDATION
# ==============================================================================

# Validate Docker Compose configuration files
validate_compose_configuration() {
    log_info "Validating Docker Compose configuration..."
    
    local compose_files=("compose.yml")
    [ -f "compose.prod.yml" ] && compose_files+=("compose.prod.yml")
    
    # Check if compose files exist
    for file in "${compose_files[@]}"; do
        if [ ! -f "$file" ]; then
            error_exit "Required Compose file not found: $file"
        fi
    done
    
    # Validate compose configuration syntax
    if ! docker compose config --quiet 2>/dev/null; then
        error_exit "Docker Compose configuration validation failed"
    fi
    
    # Check for required services
    local required_services=("postgres" "n8n" "nginx" "redis")
    for service in "${required_services[@]}"; do
        if ! docker compose config --services | grep -q "^${service}$"; then
            error_exit "Required service '$service' not found in compose configuration"
        fi
    done
    
    log_success "Docker Compose configuration is valid"
}

# Validate environment variables
validate_environment_variables() {
    log_info "Validating environment variables..."
    
    local missing_vars=()
    local recommended_vars=()
    
    # Critical environment variables
    local required_vars=(
        "POSTGRES_DB"
    )
    
    # Recommended environment variables for production deployment
    local optional_vars=(
        "N8N_HOST"
        "N8N_PROTOCOL"
        "WEBHOOK_URL"
        "N8N_EDITOR_BASE_URL"
        "SMTP_HOST"
        "SMTP_PORT"
        "SMTP_USERNAME"
        "SMTP_FROM"
        "ALERT_EMAIL_TO"
        "BACKUP_RETENTION_DAYS"
        "ENABLE_REDIS_CACHE"
        "ENABLE_MONITORING"
    )
    
    # Check required variables
    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            missing_vars+=("$var")
        fi
    done
    
    # Check recommended variables
    for var in "${optional_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            recommended_vars+=("$var")
        fi
    done
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        error_exit "Missing required environment variables: ${missing_vars[*]}"
    fi
    
    if [ ${#recommended_vars[@]} -gt 0 ]; then
        warn "Missing recommended environment variables: ${recommended_vars[*]}"
    fi
    
    log_success "Environment variables validation completed"
}

# Validate secrets configuration with optional validation level
# Usage: validate_secrets_configuration [level]
# level: "basic" (existence only) or "comprehensive" (default: permissions, strength, etc.)
validate_secrets_configuration() {
    local validation_level="${1:-comprehensive}"
    
    if [ "$validation_level" = "basic" ]; then
        log_info "Validating secrets existence..."
    else
        log_info "Validating secrets configuration..."
    fi
    
    if [ ! -d "$SECRETS_DIR" ]; then
        error_exit "Secrets directory not found: $SECRETS_DIR. Run ./scripts/generate-secrets.sh"
    fi
    
    # Align required secrets with generate-secrets.sh and compose files
    local required_secrets=(
        "postgres_password"
        "n8n_password"
        "n8n_encryption_key"
        "redis_password"
        "grafana_password"
        "smtp_password"
    )
    
    local missing_secrets=()
    local weak_secrets=()
    
    for secret in "${required_secrets[@]}"; do
        local secret_file="${SECRETS_DIR}/${secret}.txt"
        
        if [ ! -f "$secret_file" ]; then
            missing_secrets+=("$secret")
            continue
        fi
        
        # Skip additional validation if basic mode
        if [ "$validation_level" = "basic" ]; then
            continue
        fi
        
        # Check file permissions (comprehensive mode only)
        local perms
        perms=$(stat -c "%a" "$secret_file" 2>/dev/null || echo "000")
        if [ "$perms" != "600" ]; then
            warn "Secret file $secret has incorrect permissions: $perms (should be 600)"
        fi
        
        # Check secret strength (comprehensive mode only)
        local secret_value
        secret_value=$(cat "$secret_file")
        
        if [ ${#secret_value} -lt 12 ]; then
            weak_secrets+=("$secret (too short)")
        fi
    done
    
    if [ ${#missing_secrets[@]} -gt 0 ]; then
        error_exit "Missing required secrets: ${missing_secrets[*]}. Run ./scripts/generate-secrets.sh"
    fi
    
    # Additional validation for comprehensive mode only
    if [ "$validation_level" != "basic" ]; then
        if [ ${#weak_secrets[@]} -gt 0 ]; then
            warn "Weak secrets detected: ${weak_secrets[*]}. Consider regenerating with --force"
        fi
        
        # Check secrets directory permissions
        local secrets_dir_perms
        secrets_dir_perms=$(stat -c "%a" "$SECRETS_DIR" 2>/dev/null || echo "000")
        if [ "$secrets_dir_perms" != "700" ]; then
            warn "Secrets directory has incorrect permissions: $secrets_dir_perms (should be 700)"
        fi
        
        log_success "Secrets configuration validation completed"
    else
        log_success "All required secrets are present"
    fi
}

# ==============================================================================
# NETWORK AND SECURITY VALIDATION
# ==============================================================================

# Validate network configuration
validate_network_configuration() {
    log_info "Validating network configuration..."
    
    # Check if required networks exist in compose
    local networks
    networks=$(docker compose config --format json | jq -r '.networks | keys[]' 2>/dev/null || echo "")
    
    if ! echo "$networks" | grep -q "n8n-backend"; then
        error_exit "Required network 'n8n-backend' not found in compose configuration"
    fi
    
    if ! echo "$networks" | grep -q "n8n-frontend"; then
        error_exit "Required network 'n8n-frontend' not found in compose configuration"
    fi
    
    # Check port conflicts
    local used_ports=(80 443 5678 5432 6379 9090 3000 9093 3100 9080 9100 8080)
    local conflicting_ports=()
    
    for port in "${used_ports[@]}"; do
        if (command -v ss >/dev/null 2>&1 && ss -tuln | grep -q ":$port ") || \
           (command -v lsof >/dev/null 2>&1 && lsof -i :"$port" >/dev/null 2>&1) || \
           (netstat -an 2>/dev/null | grep -E "\.$port\s" >/dev/null 2>&1); then
            if ! docker compose ps | grep -q ":$port->"; then
                conflicting_ports+=("$port")
            fi
        fi
    done
    
    if [ ${#conflicting_ports[@]} -gt 0 ]; then
        warn "Ports already in use by other processes: ${conflicting_ports[*]}"
    fi
    
    log_success "Network configuration validation completed"
}

# Validate SSL/TLS configuration
validate_ssl_configuration() {
    log_info "Validating SSL/TLS configuration..."
    
    local ssl_dir="${PROJECT_ROOT}/nginx/ssl"
    local cert_file="${ssl_dir}/fullchain.pem"
    local key_file="${ssl_dir}/key.pem"
    
    if [ ! -d "$ssl_dir" ]; then
        warn "SSL directory not found: $ssl_dir"
        return 0
    fi
    
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        warn "SSL certificate files not found. HTTPS will not work."
        return 0
    fi
    
    # Check certificate validity
    if ! openssl x509 -in "$cert_file" -noout -checkend 2592000 2>/dev/null; then
        warn "SSL certificate expires within 30 days"
    fi
    
    # Check certificate and key match
    local cert_hash key_hash
    cert_hash=$(openssl x509 -noout -modulus -in "$cert_file" 2>/dev/null | openssl md5 | cut -d' ' -f2)
    key_hash=$(openssl rsa -noout -modulus -in "$key_file" 2>/dev/null | openssl md5 | cut -d' ' -f2)
    
    if [ "$cert_hash" != "$key_hash" ]; then
        error_exit "SSL certificate and private key do not match"
    fi
    
    log_success "SSL/TLS configuration validation completed"
}

# ==============================================================================
# SECURITY VALIDATION
# ==============================================================================

# Validate security configurations
validate_security_configuration() {
    log_info "Validating security configuration..."
    
    # Check for security profiles
    local security_dir="${PROJECT_ROOT}/security"
    if [ ! -d "$security_dir" ]; then
        warn "Security directory not found: $security_dir"
    else
        # Check for seccomp profile
        if [ ! -f "${security_dir}/seccomp-profile.json" ]; then
            warn "Seccomp profile not found"
        fi
        
        # Check for AppArmor profiles
        local apparmor_dir="${security_dir}/apparmor-profiles"
        if [ ! -d "$apparmor_dir" ]; then
            warn "AppArmor profiles directory not found"
        fi
    fi
    
    # Validate AppArmor environment when available
    if command -v aa-status >/dev/null 2>&1; then
        if systemctl is-active apparmor >/dev/null 2>&1; then
            log_success "AppArmor service is active"
        else
            warn "AppArmor service not active"
        fi

        if [ -f /proc/thread-self/attr/apparmor/exec ]; then
            log_success "AppArmor profile interface available"
        else
            warn "AppArmor profile interface not available: run sudo ./scripts/setup-apparmor.sh"
        fi
    else
        log_debug "AppArmor tools not found; skipping AppArmor validation"
    fi

    # Check Docker daemon security configuration (optional)
    local docker_config="/etc/docker/daemon.json"
    if [ -f "$docker_config" ]; then
        if grep -q '"no-new-privileges": true' "$docker_config"; then
            log_success "Docker daemon has no-new-privileges enabled"
        else
            log_info "Docker daemon security: Consider enabling no-new-privileges in $docker_config"
            log_info "  Run: sudo ./scripts/setup-security.sh --docker-daemon"
        fi

        if grep -q '"seccomp-profile"' "$docker_config"; then
            log_success "Docker daemon seccomp-profile configured"
        else
            log_info "Docker daemon security: Consider setting a seccomp-profile in $docker_config"
            log_info "  Run: sudo ./scripts/setup-security.sh --docker-daemon"
        fi
    else
        log_debug "Docker daemon configuration not found (optional for basic operation)"
        log_debug "  For enhanced security, run: sudo ./scripts/setup-security.sh --docker-daemon"
    fi
    
    log_success "Security configuration validation completed"
}

# ==============================================================================
# RESOURCE VALIDATION
# ==============================================================================

# Validate system resources
validate_system_resources() {
    log_info "Validating system resources..."
    
    # Check available memory (minimum 4GB recommended)
    local total_memory_kb
    total_memory_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_memory_gb=$((total_memory_kb / 1024 / 1024))
    
    if [ "$total_memory_gb" -lt 4 ]; then
        warn "System has ${total_memory_gb}GB RAM. Minimum 4GB recommended for production."
    fi
    
    # Check disk space
    local available_gb
    available_gb=$(df -BG "$PROJECT_ROOT" | awk 'NR==2 {print $4}' | sed 's/G//')
    
    if [ "$available_gb" -lt 10 ]; then
        warn "Available disk space: ${available_gb}GB. Minimum 10GB recommended."
    fi
    
    # Check CPU cores
    local cpu_cores
    cpu_cores=$(nproc)
    
    if [ "$cpu_cores" -lt 2 ]; then
        warn "System has $cpu_cores CPU core(s). Minimum 2 cores recommended for production."
    fi
    
    log_success "System resources validation completed"
}

# ==============================================================================
# COMPREHENSIVE VALIDATION RUNNER
# ==============================================================================

# Run all validation checks
run_comprehensive_validation() {
    local validation_failed=false
    
    echo -e "${BLUE}=== N8N Infrastructure Validation ===${NC}"
    echo
    
    # System-level validations
    echo -e "${BLUE}System Validation:${NC}"
    validate_system_dependencies || validation_failed=true
    validate_docker_environment || validation_failed=true
    validate_system_resources || validation_failed=true
    
    echo
    
    # Configuration validations
    echo -e "${BLUE}Configuration Validation:${NC}"
    validate_compose_configuration || validation_failed=true
    validate_environment_variables || validation_failed=true
    validate_secrets_configuration || validation_failed=true
    
    echo
    
    # Security validations
    echo -e "${BLUE}Security Validation:${NC}"
    validate_network_configuration || validation_failed=true
    validate_ssl_configuration || validation_failed=true
    validate_security_configuration || validation_failed=true
    
    echo
    
    if [ "$validation_failed" = "true" ]; then
        echo -e "${RED}${CROSS} Some validation checks failed${NC}"
        return 1
    else
        echo -e "${GREEN}${CHECKMARK} All validation checks passed${NC}"
        return 0
    fi
}

# Validate specific components
validate_component() {
    local component="$1"
    
    case "$component" in
        "docker")
            validate_docker_environment
            ;;
        "compose")
            validate_compose_configuration
            ;;
        "secrets")
            validate_secrets_configuration
            ;;
        "network")
            validate_network_configuration
            ;;
        "ssl")
            validate_ssl_configuration
            ;;
        "security")
            validate_security_configuration
            ;;
        "resources")
            validate_system_resources
            ;;
        "all")
            run_comprehensive_validation
            ;;
        *)
            error_exit "Unknown validation component: $component"
            ;;
    esac
}

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

# Create validation report
create_validation_report() {
    local output_file="${1:-${PROJECT_ROOT}/validation-report.json}"
    local validation_status="${2:-unknown}"
    
    cat > "$output_file" << EOF
{
  "timestamp": "$(get_readable_date)",
  "validation_status": "$validation_status",
  "system_info": {
    "docker_version": "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')",
    "compose_version": "$(docker compose version --short 2>/dev/null || echo 'unknown')",
    "total_memory_gb": $(grep MemTotal /proc/meminfo | awk '{print int($2/1024/1024)}'),
    "cpu_cores": $(nproc),
    "available_disk_gb": $(df -BG "$PROJECT_ROOT" | awk 'NR==2 {print int($4)}' | sed 's/G//')
  },
  "configuration": {
    "secrets_count": $(find "$SECRETS_DIR" -name "*.txt" 2>/dev/null | wc -l),
    "ssl_configured": $([ -f "${PROJECT_ROOT}/nginx/ssl/fullchain.pem" ] && echo "true" || echo "false"),
    "security_profiles": $([ -d "${PROJECT_ROOT}/security" ] && echo "true" || echo "false")
  },
  "script_version": "${COMMON_LIB_VERSION}"
}
EOF
}

# Export functions for use in other scripts
export -f validate_system_dependencies validate_docker_environment validate_compose_configuration
export -f validate_environment_variables validate_secrets_configuration validate_network_configuration
export -f validate_ssl_configuration validate_security_configuration validate_system_resources
export -f run_comprehensive_validation validate_component create_validation_report
export -f version_compare