#!/bin/bash
# ==============================================================================
# APPARMOR PROFILE LOADER FOR N8N INFRASTRUCTURE
# ==============================================================================
# Loads custom AppArmor profiles to ensure container security hardening
# Run with: sudo ./scripts/load-apparmor-profiles.sh

set -euo pipefail

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Initialize common environment (no Docker requirement for loader)
init_common false false
change_to_project_root

# Require root privileges
if [ "$EUID" -ne 0 ]; then
    error_exit "This script must be run as root (use sudo)"
fi

print_script_header "AppArmor Profile Loader" "Loading N8N security profiles into the kernel"

# Comprehensive AppArmor environment validation
validate_apparmor_environment() {
    local issues_found=0
    
    info "Validating AppArmor environment..."
    
    # Check 1: AppArmor utilities available
    if ! command -v apparmor_parser >/dev/null 2>&1; then
        log_error "AppArmor parser not found"
        echo "  Solution: Install AppArmor utilities"
        echo "    sudo apt-get update && sudo apt-get install apparmor-utils"
        issues_found=$((issues_found + 1))
    fi
    
    # Check 2: AppArmor kernel module loaded
    if ! [ -d /sys/module/apparmor ]; then
        log_error "AppArmor kernel module not loaded"
        echo "  Solution: Enable AppArmor in kernel and reboot"
        echo "    sudo ${SCRIPT_DIR}/setup-apparmor.sh"
        issues_found=$((issues_found + 1))
    fi
    
    # Check 3: AppArmor filesystem interface available
    if ! [ -f /proc/thread-self/attr/apparmor/exec ]; then
        log_error "AppArmor profile interface not available"
        echo "  This is the source of the Docker error you're experiencing"
        echo "  Solution: Ensure AppArmor is properly configured"
        echo "    sudo ${SCRIPT_DIR}/setup-apparmor.sh"
        issues_found=$((issues_found + 1))
    fi
    
    # Check 4: AppArmor service status
    if ! systemctl is-active apparmor >/dev/null 2>&1; then
        log_error "AppArmor service not active"
        echo "  Solution: Start AppArmor service"
        echo "    sudo systemctl start apparmor"
        issues_found=$((issues_found + 1))
    fi
    
    # Check 5: AppArmor enabled in kernel command line
    if ! grep -q "apparmor=1" /proc/cmdline 2>/dev/null; then
        log_error "AppArmor not enabled in kernel boot parameters"
        echo "  Solution: Configure kernel parameters and reboot"
        echo "    sudo ${SCRIPT_DIR}/setup-apparmor.sh"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$issues_found" -gt 0 ]; then
        echo ""
        echo -e "${RED}=== AppArmor Environment Issues ===${NC}"
        echo "=================================="
        echo -e "Issues found: ${RED}$issues_found${NC}"
        echo ""
        echo -e "${YELLOW}RECOMMENDED SOLUTION:${NC}"
        echo "Run the AppArmor setup script to resolve all issues:"
        echo ""
        echo -e "${CYAN}  sudo ${SCRIPT_DIR}/setup-apparmor.sh${NC}"
        echo ""
        echo "This will:"
        echo "  • Install required AppArmor packages"
        echo "  • Configure kernel parameters"
        echo "  • Enable and start AppArmor service"
        echo "  • Verify complete functionality"
        echo ""
        error_exit "AppArmor environment validation failed ($issues_found issues)"
    fi
    
    log_success "AppArmor environment validation passed"
}

# Call validation function
validate_apparmor_environment

PROFILES_DIR="${PROJECT_ROOT}/security/apparmor-profiles"
SYSTEM_PROFILES_DIR="/etc/apparmor.d"

# Validate profiles directory exists
if [ ! -d "$PROFILES_DIR" ]; then
    error_exit "Profiles directory not found: $PROFILES_DIR"
fi

info "Loading AppArmor profiles for N8N services..."

# Profile definitions
declare -A PROFILES=(
    ["n8n_postgres_profile"]="postgres-profile"
    ["n8n_app_profile"]="n8n-profile"
    ["n8n_nginx_profile"]="nginx-profile"
    ["n8n_redis_profile"]="redis-profile"
)

PROFILES_LOADED=0
PROFILES_FAILED=0

# Load each profile
for profile_name in "${!PROFILES[@]}"; do
    profile_file="${PROFILES_DIR}/${PROFILES[$profile_name]}"
    system_file="${SYSTEM_PROFILES_DIR}/${profile_name}"
    
    echo -n "Loading ${profile_name}... "
    
    if [ ! -f "$profile_file" ]; then
        echo -e "${RED}${CROSS} MISSING${NC}"
        log_error "Profile file not found: $profile_file"
        PROFILES_FAILED=$((PROFILES_FAILED + 1))
        continue
    fi
    
    # Validate profile syntax (show detailed parser output)
    set +e
    SYNTAX_OUTPUT=$(apparmor_parser -Q "$profile_file" 2>&1)
    SYNTAX_STATUS=$?
    set -e
    if [ "$SYNTAX_STATUS" -ne 0 ]; then
        echo -e "${RED}${CROSS} INVALID SYNTAX${NC}"
        echo "$SYNTAX_OUTPUT" | sed 's/^/  /'
        log_error "Profile syntax validation failed: $profile_file\n$SYNTAX_OUTPUT"
        PROFILES_FAILED=$((PROFILES_FAILED + 1))
        continue
    fi
    
    # Copy to system directory
    if ! cp "$profile_file" "$system_file"; then
        echo -e "${RED}${CROSS} COPY FAILED${NC}"
        log_error "Failed to copy profile to system directory"
        PROFILES_FAILED=$((PROFILES_FAILED + 1))
        continue
    fi
    
    # Load the profile (show detailed parser output)
    set +e
    LOAD_OUTPUT=$(apparmor_parser -r "$system_file" 2>&1)
    LOAD_STATUS=$?
    set -e
    if [ "$LOAD_STATUS" -eq 0 ]; then
        echo -e "${GREEN}${CHECKMARK} LOADED${NC}"
        log_success "Profile loaded successfully: $profile_name"
        PROFILES_LOADED=$((PROFILES_LOADED + 1))
    else
        echo -e "${RED}${CROSS} LOAD FAILED${NC}"
        echo "$LOAD_OUTPUT" | sed 's/^/  /'
        log_error "Failed to load profile: $profile_name\n$LOAD_OUTPUT"
        PROFILES_FAILED=$((PROFILES_FAILED + 1))
        # Remove the copied file if loading failed
        rm -f "$system_file"
    fi
done

echo ""
info "Verifying loaded profiles..."

# Verify profiles are loaded
for profile_name in "${!PROFILES[@]}"; do
    if aa-status | grep -q "^   $profile_name"; then
        log "Profile active: $profile_name"
    else
        warn "Profile not active: $profile_name"
    fi
done

echo ""
echo -e "${BLUE}=== Profile Loading Summary ===${NC}"
echo "=============================="
echo -e "Profiles loaded: ${GREEN}$PROFILES_LOADED${NC}"
echo -e "Profiles failed: ${RED}$PROFILES_FAILED${NC}"

## Automatic boot-time loading is managed by setup-apparmor.sh

# Overall status
if [ "$PROFILES_FAILED" -eq 0 ]; then
    echo -e "\nOverall Status: ${GREEN}SUCCESS${NC}"
    log_info "All AppArmor profiles loaded successfully"
    
    info "Next steps:"
    echo "  1. Restart Docker containers to apply profiles"
    echo "  2. Verify profile enforcement with: sudo aa-status"
    echo "  3. Monitor logs for AppArmor denials: journalctl -f | grep apparmor"
    
    exit_code=0
else
    echo -e "\nOverall Status: ${RED}PARTIAL FAILURE${NC}"
    log_error "Some AppArmor profiles failed to load"
    
    info "Troubleshooting:"
    echo "  1. Check profile syntax with: apparmor_parser -Q profile_file"
    echo "  2. Review system logs: journalctl -u apparmor"
    echo "  3. Ensure AppArmor is enabled: systemctl status apparmor"
    
    exit_code=1
fi

print_script_footer "AppArmor Profile Loader"

exit $exit_code