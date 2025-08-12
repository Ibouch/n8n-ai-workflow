#!/bin/bash
# ==============================================================================
# N8N INFRASTRUCTURE VALIDATION SCRIPT
# ==============================================================================
# Comprehensive validation of all infrastructure components
# Usage: ./validate-infrastructure.sh [component|all]

set -euo pipefail

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/validation.sh"
source "${SCRIPT_DIR}/lib/health-checks.sh"

# Initialize common environment
init_common
change_to_project_root

# Load environment variables from .env if present (export-safe)
if [ -f "${PROJECT_ROOT}/.env" ]; then
    # Export all sourced vars in this block; temporarily relax nounset for safe sourcing
    set -a
    set +u
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/.env"
    set -u
    set +a
    log_success "Loaded environment from .env"
else
    warn ".env file not found at ${PROJECT_ROOT}/.env - proceeding with defaults"
fi

# Parse command line arguments
VALIDATION_COMPONENT="${1:-all}"

print_script_header "N8N Infrastructure Validation" "Comprehensive validation of all infrastructure components"

# Show available validation components
show_validation_help() {
    echo "Available validation components:"
    echo "  docker     - Docker daemon and Docker Compose"
    echo "  compose    - Docker Compose configuration files"
    echo "  secrets    - Secrets configuration and security"
    echo "  network    - Network configuration and ports"
    echo "  ssl        - SSL/TLS certificate configuration"
    echo "  security   - Security profiles and configurations"
    echo "  resources  - System resources (CPU, memory, disk)"
    echo "  health     - Service health checks"
    echo "  all        - Run all validation checks (default)"
    echo ""
    echo "Usage: $0 [component]"
    echo "Example: $0 docker"
}

# Main validation logic
case "$VALIDATION_COMPONENT" in
    "help"|"-h"|"--help")
        show_validation_help
        exit 0
        ;;
    "health")
        log_info "Running health checks..."
        if run_comprehensive_health_check; then
            log_success "All health checks passed"
            exit_code=0
        else
            log_error "Some health checks failed"
            exit_code=1
        fi
        ;;
    "all")
        log_info "Running comprehensive infrastructure validation..."
        
        validation_success=true
        
        # Run configuration validation
        if ! run_comprehensive_validation; then
            validation_success=false
        fi
        
        echo
        log_info "Running health checks..."
        
        # Run health checks if services are available
        if docker compose ps | grep -q "Up"; then
            if ! run_comprehensive_health_check; then
                validation_success=false
            fi
        else
            warn "Services not running - skipping health checks"
        fi
        
        # Generate comprehensive report
        if [ "$validation_success" = "true" ]; then
            create_validation_report "${PROJECT_ROOT}/infrastructure-validation-report.json" "passed"
            log_success "Infrastructure validation completed successfully"
            exit_code=0
        else
            create_validation_report "${PROJECT_ROOT}/infrastructure-validation-report.json" "failed"
            log_error "Infrastructure validation failed"
            exit_code=1
        fi
        ;;
    *)
        log_info "Running validation for component: $VALIDATION_COMPONENT"
        if validate_component "$VALIDATION_COMPONENT"; then
            log_success "$VALIDATION_COMPONENT validation passed"
            exit_code=0
        else
            log_error "$VALIDATION_COMPONENT validation failed"
            exit_code=1
        fi
        ;;
esac

print_script_footer "N8N Infrastructure Validation"

exit ${exit_code:-0}