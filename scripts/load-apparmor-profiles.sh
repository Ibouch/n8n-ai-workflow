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

# Initialize common environment
init_common
change_to_project_root

# Require root privileges
if [ "$EUID" -ne 0 ]; then
    error_exit "This script must be run as root (use sudo)"
fi

print_script_header "AppArmor Profile Loader" "Loading N8N security profiles into the kernel"

# Check if AppArmor is available
if ! command -v apparmor_parser >/dev/null 2>&1; then
    error_exit "AppArmor not found. Install with: apt-get install apparmor-utils"
fi

# Check if AppArmor is enabled
if ! [ -d /sys/module/apparmor ]; then
    error_exit "AppArmor module not loaded in kernel"
fi

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
    
    # Validate profile syntax
    if ! apparmor_parser -Q "$profile_file" >/dev/null 2>&1; then
        echo -e "${RED}${CROSS} INVALID SYNTAX${NC}"
        log_error "Profile syntax validation failed: $profile_file"
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
    
    # Load the profile
    if apparmor_parser -r "$system_file" >/dev/null 2>&1; then
        echo -e "${GREEN}${CHECKMARK} LOADED${NC}"
        log_success "Profile loaded successfully: $profile_name"
        PROFILES_LOADED=$((PROFILES_LOADED + 1))
    else
        echo -e "${RED}${CROSS} LOAD FAILED${NC}"
        log_error "Failed to load profile: $profile_name"
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

# Create systemd service for automatic loading
create_systemd_service() {
    local service_file="/etc/systemd/system/n8n-apparmor-loader.service"
    
    info "Creating systemd service for automatic profile loading..."
    
    cat > "$service_file" << 'EOF'
[Unit]
Description=Load N8N AppArmor Profiles
After=apparmor.service
Wants=apparmor.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash SCRIPT_PATH/load-apparmor-profiles.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Replace the script path placeholder
    sed -i "s|SCRIPT_PATH|${SCRIPT_DIR}|g" "$service_file"
    
    # Enable the service
    if systemctl enable n8n-apparmor-loader.service >/dev/null 2>&1; then
        log_success "Systemd service created and enabled"
        log "Service will automatically load profiles on boot"
    else
        warn "Failed to enable systemd service"
    fi
}

if [ "$PROFILES_LOADED" -gt 0 ]; then
    info "Setting up automatic profile loading..."
    create_systemd_service
fi

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