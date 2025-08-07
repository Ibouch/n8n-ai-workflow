#!/bin/bash
# ==============================================================================
# UNIFIED HEALTH CHECK LIBRARY FOR N8N INFRASTRUCTURE
# ==============================================================================
# Centralized health check functions to eliminate duplication across scripts
# Source this file: source "${SCRIPT_DIR}/lib/health-checks.sh"

# Note: This file depends on common.sh being loaded first

# ==============================================================================
# HEALTH CHECK CONFIGURATION
# ==============================================================================

# Default timeouts and intervals
readonly DEFAULT_HEALTH_TIMEOUT=30
readonly DEFAULT_HEALTH_INTERVAL=5
readonly DEFAULT_HEALTH_RETRIES=5

# Service health check endpoints
readonly N8N_HEALTH_ENDPOINT="http://localhost:5678/healthz"
readonly N8N_METRICS_ENDPOINT="http://localhost:5678/metrics"
readonly PROMETHEUS_HEALTH_ENDPOINT="http://localhost:9090/-/healthy"
readonly GRAFANA_HEALTH_ENDPOINT="http://localhost:3000/api/health"
readonly LOKI_HEALTH_ENDPOINT="http://localhost:3100/ready"

# ==============================================================================
# CORE HEALTH CHECK FUNCTIONS
# ==============================================================================

# Generic health check function with consistent interface
perform_health_check() {
    local check_name="$1"
    local check_function="$2"
    local is_critical="${3:-true}"
    local timeout="${4:-$DEFAULT_HEALTH_TIMEOUT}"
    
    local start_time=$(date +%s)
    
    echo -n "Checking ${check_name}... "
    
    # Execute the health check with timeout
    if timeout "$timeout" bash -c "$check_function" >/dev/null 2>&1; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo -e "${GREEN}${CHECKMARK} OK${NC} (${duration}s)"
        return 0
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [ "$is_critical" = "true" ]; then
            echo -e "${RED}${CROSS} FAILED${NC} (${duration}s)"
            return 1
        else
            echo -e "${YELLOW}${WARNING} WARNING${NC} (${duration}s)"
            return 2
        fi
    fi
}

# ==============================================================================
# DOCKER AND SYSTEM HEALTH CHECKS
# ==============================================================================

# Check if Docker daemon is responsive
check_docker_daemon() {
    docker info >/dev/null 2>&1
}

# Check if Docker Compose is available and functional
check_docker_compose() {
    docker compose version >/dev/null 2>&1
}

# Check if a Docker service is running
check_service_running() {
    local service="$1"
    is_service_running "$service"
}

# Check if a Docker service is healthy (using health checks)
check_service_healthy() {
    local service="$1"
    is_service_healthy "$service"
}

# Check Docker Compose configuration validity
check_compose_config() {
    change_to_project_root
    docker compose config --quiet >/dev/null 2>&1
}

# ==============================================================================
# N8N APPLICATION HEALTH CHECKS
# ==============================================================================

# Check N8N health endpoint
check_n8n_health_endpoint() {
    if ! is_service_running "n8n"; then
        return 1
    fi
    
    docker_exec_safe n8n wget --no-verbose --tries=1 --spider "$N8N_HEALTH_ENDPOINT"
}

# Check N8N metrics endpoint
check_n8n_metrics_endpoint() {
    if ! is_service_running "n8n"; then
        return 1
    fi
    
    docker_exec_safe n8n wget --no-verbose --tries=1 --spider "$N8N_METRICS_ENDPOINT"
}

# Get N8N version information
get_n8n_version() {
    if is_service_running "n8n"; then
        docker_exec_safe n8n n8n --version 2>/dev/null | tr -d '\r' | head -1
    else
        echo "service not running"
    fi
}

# Check N8N workflow execution capability
check_n8n_workflow_execution() {
    if ! is_service_running "n8n"; then
        return 1
    fi
    
    # This is a basic check - in production you might want to test a simple workflow
    # For now, we just verify that the N8N API is responsive
    docker_exec_safe n8n wget --no-verbose --tries=1 --spider "${N8N_HEALTH_ENDPOINT}"
}

# ==============================================================================
# DATABASE HEALTH CHECKS
# ==============================================================================

# Check PostgreSQL connection
check_postgresql_connection() {
    if ! is_service_running "postgres"; then
        return 1
    fi
    
    local postgres_user
    postgres_user=$(read_secret "postgres_user")
    local postgres_db="${POSTGRES_DB:-n8n}"
    
    docker_exec_safe postgres pg_isready -U "$postgres_user" -d "$postgres_db"
}

# Get PostgreSQL version
get_postgresql_version() {
    if is_service_running "postgres"; then
        docker_exec_safe postgres postgres --version 2>/dev/null | cut -d' ' -f3 | tr -d '\r'
    else
        echo "service not running"
    fi
}

# Get database size
get_database_size() {
    if ! is_service_running "postgres"; then
        echo "service not running"
        return 1
    fi
    
    local postgres_user
    postgres_user=$(read_secret "postgres_user")
    local postgres_db="${POSTGRES_DB:-n8n}"
    
    docker_exec_safe postgres psql -U "$postgres_user" -d "$postgres_db" -t -c \
        "SELECT pg_size_pretty(pg_database_size('$postgres_db'));" 2>/dev/null | \
        tr -d ' \r\n' | head -1
}

# Check for long-running queries
check_long_running_queries() {
    if ! is_service_running "postgres"; then
        return 1
    fi
    
    local postgres_user
    postgres_user=$(read_secret "postgres_user")
    local postgres_db="${POSTGRES_DB:-n8n}"
    local threshold_minutes="${1:-5}"
    
    local long_queries
    long_queries=$(docker_exec_safe postgres psql -U "$postgres_user" -d "$postgres_db" -t -c \
        "SELECT count(*) FROM pg_stat_activity WHERE state != 'idle' AND query_start < now() - interval '$threshold_minutes minutes';" 2>/dev/null | \
        tr -d ' \r\n' | head -1)
    
    [ "$long_queries" -eq 0 ]
}

# ==============================================================================
# REDIS HEALTH CHECKS
# ==============================================================================

# Check Redis connection and responsiveness
check_redis_connection() {
    if ! is_service_running "redis"; then
        return 1
    fi
    
    local redis_password
    redis_password=$(read_secret "redis_password")
    
    docker_exec_safe redis redis-cli --pass "$redis_password" ping | grep -q "PONG"
}

# Get Redis memory usage
get_redis_memory_usage() {
    if ! is_service_running "redis"; then
        echo "service not running"
        return 1
    fi
    
    local redis_password
    redis_password=$(read_secret "redis_password")
    
    docker_exec_safe redis redis-cli --pass "$redis_password" INFO memory 2>/dev/null | \
        grep used_memory_human | cut -d: -f2 | tr -d '\r' | head -1
}

# Check Redis key count
get_redis_key_count() {
    if ! is_service_running "redis"; then
        echo "0"
        return 1
    fi
    
    local redis_password
    redis_password=$(read_secret "redis_password")
    
    docker_exec_safe redis redis-cli --pass "$redis_password" DBSIZE 2>/dev/null | tr -d '\r'
}

# ==============================================================================
# WEB SERVER HEALTH CHECKS
# ==============================================================================

# Check Nginx configuration validity
check_nginx_configuration() {
    if ! is_service_running "nginx"; then
        return 1
    fi
    
    docker_exec_safe nginx nginx -t
}

# Check HTTPS endpoint accessibility
check_https_endpoint() {
    local host="${1:-${N8N_HOST:-localhost}}"
    local expected_codes="${2:-200,301,302,401}"
    
    if [ -z "$host" ] || [ "$host" = "localhost" ]; then
        return 0  # Skip check for localhost
    fi
    
    local http_code
    http_code=$(curl -sSf -k "https://$host" -o /dev/null -w '%{http_code}' 2>/dev/null || echo "000")
    
    echo "$expected_codes" | grep -q "$http_code"
}

# ==============================================================================
# MONITORING STACK HEALTH CHECKS
# ==============================================================================

# Check Prometheus health
check_prometheus_health() {
    if ! is_service_running "prometheus"; then
        return 1
    fi
    
    docker_exec_safe prometheus wget --no-verbose --tries=1 --spider "$PROMETHEUS_HEALTH_ENDPOINT"
}

# Check Grafana health
check_grafana_health() {
    if ! is_service_running "grafana"; then
        return 1
    fi
    
    docker_exec_safe grafana wget --no-verbose --tries=1 --spider "$GRAFANA_HEALTH_ENDPOINT"
}

# Check Loki health
check_loki_health() {
    if ! is_service_running "loki"; then
        return 1
    fi
    
    docker_exec_safe loki wget --no-verbose --tries=1 --spider "$LOKI_HEALTH_ENDPOINT"
}

# ==============================================================================
# SYSTEM RESOURCE HEALTH CHECKS
# ==============================================================================

# Check disk space usage
check_disk_space_usage() {
    local path="${1:-$PROJECT_ROOT}"
    local warning_threshold="${2:-80}"
    local critical_threshold="${3:-90}"
    
    local usage_percent
    usage_percent=$(df "$path" | awk 'NR==2 {print $5}' | sed 's/%//')
    
    if [ "$usage_percent" -ge "$critical_threshold" ]; then
        return 1  # Critical
    elif [ "$usage_percent" -ge "$warning_threshold" ]; then
        return 2  # Warning
    else
        return 0  # OK
    fi
}

# Get disk space information
get_disk_space_info() {
    local path="${1:-$PROJECT_ROOT}"
    df -h "$path" | awk 'NR==2 {printf "Used: %s (%s) | Available: %s", $3, $5, $4}'
}

# Check memory usage of containers
check_container_memory_usage() {
    docker stats --no-stream --format "table {{.Container}}\t{{.MemUsage}}\t{{.MemPerc}}" | \
        grep -E 'n8n|postgres|redis|nginx' || echo "No containers found"
}

# ==============================================================================
# SSL/TLS CERTIFICATE HEALTH CHECKS
# ==============================================================================

# Check SSL certificate validity and expiration
check_ssl_certificate() {
    local cert_file="${1:-${PROJECT_ROOT}/nginx/ssl/fullchain.pem}"
    local warning_days="${2:-30}"
    local critical_days="${3:-7}"
    
    if [ ! -f "$cert_file" ]; then
        return 1
    fi
    
    local expiry_date
    expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
    
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
    
    if [ "$expiry_epoch" -eq 0 ]; then
        return 1
    fi
    
    local current_epoch
    current_epoch=$(date +%s)
    
    local days_left
    days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
    
    if [ "$days_left" -lt "$critical_days" ]; then
        return 1  # Critical
    elif [ "$days_left" -lt "$warning_days" ]; then
        return 2  # Warning
    else
        return 0  # OK
    fi
}

# Get SSL certificate information
get_ssl_certificate_info() {
    local cert_file="${1:-${PROJECT_ROOT}/nginx/ssl/fullchain.pem}"
    
    if [ ! -f "$cert_file" ]; then
        echo "Certificate file not found"
        return 1
    fi
    
    local expiry_date
    expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
    
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
    
    if [ "$expiry_epoch" -eq 0 ]; then
        echo "Invalid certificate"
        return 1
    fi
    
    local current_epoch
    current_epoch=$(date +%s)
    
    local days_left
    days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
    
    echo "Expires in $days_left days ($expiry_date)"
}

# ==============================================================================
# BACKUP HEALTH CHECKS
# ==============================================================================

# Check backup status and recency
check_backup_status() {
    local backup_dir="${1:-${PROJECT_ROOT}/volumes/backups}"
    local max_age_hours="${2:-25}"  # 25 hours = just over daily
    
    if [ ! -d "$backup_dir" ]; then
        return 1
    fi
    
    local latest_backup
    latest_backup=$(ls -t "$backup_dir" | grep -E '^[0-9]{8}_[0-9]{6}$' | head -1)
    
    if [ -z "$latest_backup" ]; then
        return 1
    fi
    
    local backup_timestamp
    backup_timestamp=$(stat -c %Y "${backup_dir}/${latest_backup}" 2>/dev/null || echo "0")
    
    local current_timestamp
    current_timestamp=$(date +%s)
    
    local age_hours
    age_hours=$(( (current_timestamp - backup_timestamp) / 3600 ))
    
    [ "$age_hours" -le "$max_age_hours" ]
}

# Get backup status information
get_backup_status_info() {
    local backup_dir="${1:-${PROJECT_ROOT}/volumes/backups}"
    
    if [ ! -d "$backup_dir" ]; then
        echo "Backup directory not found"
        return 1
    fi
    
    local latest_backup
    latest_backup=$(ls -t "$backup_dir" | grep -E '^[0-9]{8}_[0-9]{6}$' | head -1)
    
    if [ -z "$latest_backup" ]; then
        echo "No backups found"
        return 1
    fi
    
    local backup_timestamp
    backup_timestamp=$(stat -c %Y "${backup_dir}/${latest_backup}" 2>/dev/null || echo "0")
    
    local current_timestamp
    current_timestamp=$(date +%s)
    
    local age_hours
    age_hours=$(( (current_timestamp - backup_timestamp) / 3600 ))
    
    echo "Latest: $latest_backup (${age_hours} hours ago)"
}

# ==============================================================================
# COMPREHENSIVE HEALTH CHECK RUNNER
# ==============================================================================

# Run all critical health checks
run_comprehensive_health_check() {
    local exit_code=0
    local checks_passed=0
    local checks_failed=0
    local warnings=0
    
    echo -e "${BLUE}=== Comprehensive N8N Health Check ===${NC}"
    echo
    
    # Docker system checks
    echo -e "${BLUE}Docker System:${NC}"
    if perform_health_check "Docker daemon" "check_docker_daemon"; then
        checks_passed=$((checks_passed + 1))
    else
        checks_failed=$((checks_failed + 1))
        exit_code=1
    fi
    
    if perform_health_check "Docker Compose" "check_docker_compose"; then
        checks_passed=$((checks_passed + 1))
    else
        checks_failed=$((checks_failed + 1))
        exit_code=1
    fi
    
    if perform_health_check "Compose configuration" "check_compose_config"; then
        checks_passed=$((checks_passed + 1))
    else
        checks_failed=$((checks_failed + 1))
        exit_code=1
    fi
    
    echo
    
    # Service checks
    echo -e "${BLUE}Services:${NC}"
    for service in postgres n8n nginx redis; do
        if perform_health_check "$service container" "check_service_running $service"; then
            checks_passed=$((checks_passed + 1))
        else
            checks_failed=$((checks_failed + 1))
            exit_code=1
        fi
    done
    
    echo
    
    # Application-specific checks
    echo -e "${BLUE}Application Health:${NC}"
    if perform_health_check "N8N health endpoint" "check_n8n_health_endpoint"; then
        checks_passed=$((checks_passed + 1))
    else
        checks_failed=$((checks_failed + 1))
        exit_code=1
    fi
    
    if perform_health_check "PostgreSQL connection" "check_postgresql_connection"; then
        checks_passed=$((checks_passed + 1))
    else
        checks_failed=$((checks_failed + 1))
        exit_code=1
    fi
    
    if [ "${ENABLE_REDIS_CACHE:-true}" = "true" ]; then
        if perform_health_check "Redis connection" "check_redis_connection"; then
            checks_passed=$((checks_passed + 1))
        else
            checks_failed=$((checks_failed + 1))
            exit_code=1
        fi
    fi
    
    if perform_health_check "Nginx configuration" "check_nginx_configuration"; then
        checks_passed=$((checks_passed + 1))
    else
        checks_failed=$((checks_failed + 1))
        exit_code=1
    fi
    
    echo
    
    # Non-critical checks
    echo -e "${BLUE}Optional Checks:${NC}"
    
    local check_result
    perform_health_check "N8N metrics endpoint" "check_n8n_metrics_endpoint" false
    check_result=$?
    if [ $check_result -eq 0 ]; then
        checks_passed=$((checks_passed + 1))
    elif [ $check_result -eq 2 ]; then
        warnings=$((warnings + 1))
    fi
    
    if [ -n "${N8N_HOST:-}" ] && [ "${N8N_HOST}" != "localhost" ]; then
        perform_health_check "HTTPS endpoint" "check_https_endpoint" false
        check_result=$?
        if [ $check_result -eq 0 ]; then
            checks_passed=$((checks_passed + 1))
        elif [ $check_result -eq 2 ]; then
            warnings=$((warnings + 1))
        fi
    fi
    
    perform_health_check "Disk space" "check_disk_space_usage" false
    check_result=$?
    if [ $check_result -eq 0 ]; then
        checks_passed=$((checks_passed + 1))
    elif [ $check_result -eq 2 ]; then
        warnings=$((warnings + 1))
    fi
    
    perform_health_check "Backup status" "check_backup_status" false
    check_result=$?
    if [ $check_result -eq 0 ]; then
        checks_passed=$((checks_passed + 1))
    elif [ $check_result -eq 2 ]; then
        warnings=$((warnings + 1))
    fi
    
    echo
    
    # Summary
    echo -e "${BLUE}=== Health Check Summary ===${NC}"
    echo -e "Checks passed: ${GREEN}$checks_passed${NC}"
    echo -e "Checks failed: ${RED}$checks_failed${NC}"
    echo -e "Warnings: ${YELLOW}$warnings${NC}"
    
    if [ $exit_code -eq 0 ]; then
        if [ $warnings -eq 0 ]; then
            echo -e "\nOverall status: ${GREEN}HEALTHY${NC}"
        else
            echo -e "\nOverall status: ${YELLOW}HEALTHY WITH WARNINGS${NC}"
        fi
    else
        echo -e "\nOverall status: ${RED}UNHEALTHY${NC}"
    fi
    
    return $exit_code
}

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

# Create health status JSON for external monitoring
create_health_status_json() {
    local output_file="${1:-${PROJECT_ROOT}/health-status.json}"
    
    cat > "$output_file" << EOF
{
  "timestamp": "$(get_readable_date)",
  "services": {
    "n8n": "$(is_service_running "n8n" && echo "up" || echo "down")",
    "postgres": "$(is_service_running "postgres" && echo "up" || echo "down")",
    "nginx": "$(is_service_running "nginx" && echo "up" || echo "down")",
    "redis": "$(is_service_running "redis" && echo "up" || echo "down")"
  },
  "versions": {
    "n8n": "$(get_n8n_version)",
    "postgres": "$(get_postgresql_version)"
  },
  "resources": {
    "disk_usage": "$(get_disk_space_info)",
    "database_size": "$(get_database_size || echo 'unknown')",
    "redis_memory": "$(get_redis_memory_usage || echo 'unknown')"
  },
  "backup_status": "$(get_backup_status_info || echo 'No backups found')",
  "ssl_status": "$(get_ssl_certificate_info || echo 'No certificate found')",
  "script_version": "${COMMON_LIB_VERSION:-unknown}"
}
EOF
}

# Export all functions for use in other scripts
export -f perform_health_check
export -f check_docker_daemon check_docker_compose check_service_running check_service_healthy check_compose_config
export -f check_n8n_health_endpoint check_n8n_metrics_endpoint get_n8n_version check_n8n_workflow_execution
export -f check_postgresql_connection get_postgresql_version get_database_size check_long_running_queries
export -f check_redis_connection get_redis_memory_usage get_redis_key_count
export -f check_nginx_configuration check_https_endpoint
export -f check_prometheus_health check_grafana_health check_loki_health
export -f check_disk_space_usage get_disk_space_info check_container_memory_usage
export -f check_ssl_certificate get_ssl_certificate_info
export -f check_backup_status get_backup_status_info
export -f run_comprehensive_health_check create_health_status_json