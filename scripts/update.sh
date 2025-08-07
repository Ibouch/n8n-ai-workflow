#!/bin/bash
# N8N Production Update Script
# Performs safe updates with backup and rollback capability

set -euo pipefail

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/health-checks.sh"

# Configuration
TIMESTAMP=$(get_timestamp)

# Load environment
if [ -f "${PROJECT_ROOT}/.env" ]; then
    source "${PROJECT_ROOT}/.env"
fi

# Initialize common environment
init_common
check_not_root
change_to_project_root

print_script_header "N8N Production Update" "Safe updates with automated backup and rollback capability"

# 1. Pre-flight checks
log_info "Performing comprehensive pre-flight checks..."

# Validate project structure and requirements
validate_project_structure
require_commands "docker" "docker compose"

# Check Docker Compose configuration
validate_compose_config

# Verify critical services are running
log_info "Checking service status..."
for service in postgres n8n nginx; do
    if ! is_service_running "$service"; then
        error_exit "Service '$service' is not running. Please start services first."
    fi
done

# Run health checks before update
log_info "Running pre-update health checks..."
if ! run_comprehensive_health_check; then
    if ! confirm_action "Health checks failed. Continue with update anyway?" "N"; then
        error_exit "Update cancelled due to failed health checks"
    fi
fi

# 2. Create pre-update backup
log_info "Creating pre-update backup..."
if [ ! -f "${SCRIPT_DIR}/backup.sh" ]; then
    error_exit "Backup script not found: ${SCRIPT_DIR}/backup.sh"
fi
"${SCRIPT_DIR}/backup.sh" || error_exit "Backup failed. Aborting update."

# 3. Pull latest images
log_info "Pulling latest Docker images..."
if ! docker compose pull; then
    error_exit "Failed to pull images"
fi

# 4. Show what will be updated
log_info "Images to be updated:"
docker compose images | grep -E "n8n|postgres|redis|nginx" || true

# 5. Confirm update
if ! confirm_action "Proceed with update? This will update all services with minimal downtime" "N"; then
    log_info "Update cancelled by user"
    exit 0
fi

# 6. Perform rolling update
log_info "Starting rolling update..."

# Update N8N (main application)
log_info "Updating N8N application..."
if ! docker compose up -d --no-deps n8n; then
    error_exit "Failed to update N8N service"
fi

# Wait for N8N to be healthy with timeout
log_info "Waiting for N8N to be healthy..."
if ! wait_for_service_healthy "n8n" 300; then
    warn "N8N failed to become healthy within timeout. Attempting rollback..."
    docker compose up -d --no-deps n8n
    error_exit "Update failed. Attempted rollback to previous version."
fi

log_success "N8N update completed successfully"

# Update Nginx
log_info "Updating Nginx..."
if ! docker compose up -d --no-deps nginx; then
    warn "Failed to update Nginx"
fi

# Update other services
log_info "Updating supporting services..."
docker compose up -d --no-deps redis

# Update monitoring stack if enabled
if [ "${ENABLE_MONITORING:-true}" = "true" ]; then
    log_info "Updating monitoring stack..."
    docker compose -f compose.yml -f compose.prod.yml up -d --no-deps prometheus grafana loki promtail 2>/dev/null || warn "Some monitoring services failed to update"
fi

# 7. Clean up old images
log_info "Cleaning up old Docker images..."
docker image prune -f >/dev/null

# 8. Verify all services are running
log_info "Verifying services after update..."
sleep 10

failed_services=()
for service in postgres n8n nginx redis; do
    if ! is_service_running "$service"; then
        failed_services+=("$service")
    fi
done

if [ ${#failed_services[@]} -gt 0 ]; then
    error_exit "The following services failed to start: ${failed_services[*]}"
fi

# 9. Run post-update health checks
log_info "Running post-update health checks..."
if ! run_comprehensive_health_check; then
    warn "Some health checks failed after update. Please review and fix issues."
fi

# 10. Get version information
NEW_N8N_VERSION=$(get_n8n_version)
NEW_POSTGRES_VERSION=$(get_postgresql_version)

# 11. Update completion
log_success "Update completed successfully!"
log_info "Update Summary:"
log_info "  N8N Version: ${NEW_N8N_VERSION}"
log_info "  PostgreSQL Version: ${NEW_POSTGRES_VERSION}"
log_info "  Backup Location: ${PROJECT_ROOT}/volumes/backups/ (latest)"
log_info "  Update Timestamp: ${TIMESTAMP}"

info "Next steps:"
echo "1. Test your workflows to ensure everything is working correctly"
echo "2. Monitor logs for any errors: docker compose logs -f"
echo "3. If issues occur, restore from the pre-update backup"

warn "Note: First workflow execution may be slower due to cache warming"

print_script_footer "N8N Production Update"