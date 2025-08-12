#!/bin/bash
# ==============================================================================
# APPARMOR DEBIAN PRODUCTION SETUP SCRIPT
# ==============================================================================
# Comprehensive AppArmor installation and configuration for Debian systems
# Ensures proper AppArmor functionality for container security hardening
# Run with: sudo ./scripts/setup-apparmor.sh

set -euo pipefail

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Initialize common environment (no Docker requirement)
init_common false false
change_to_project_root

# Require root privileges
if [ "$EUID" -ne 0 ]; then
    error_exit "This script must be run as root (use sudo)"
fi

print_script_header "AppArmor Debian Setup" "Installing and configuring AppArmor for production containers"

# System requirements validation
validate_debian_system() {
    info "Validating Debian system requirements..."
    
    local distro=""
    if command -v lsb_release >/dev/null 2>&1; then
        distro=$(lsb_release -si 2>/dev/null || echo "")
    elif [ -r /etc/os-release ]; then
        . /etc/os-release
        distro="${ID:-}${ID_LIKE:+ ${ID_LIKE}}"
    fi

    if echo "$distro" | grep -Eiq '(debian|ubuntu)'; then
        log_success "Compatible OS detected"
    else
        error_exit "Unsupported distribution. This script supports Debian/Ubuntu only."
    fi
}

# Install AppArmor packages
install_apparmor_packages() {
    info "Installing AppArmor packages..."
    
    # Update package lists
    if ! apt-get update -qq; then
        error_exit "Failed to update package lists"
    fi
    
    # Required packages
    local packages=(
        "apparmor"
        "apparmor-utils"
        "apparmor-profiles"
        "apparmor-profiles-extra"
    )
    
    local missing_packages=()
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$package "; then
            missing_packages+=("$package")
        fi
    done
    
    if [ ${#missing_packages[@]} -gt 0 ]; then
        log "Installing missing packages: ${missing_packages[*]}"
        if ! apt-get install -y "${missing_packages[@]}"; then
            error_exit "Failed to install AppArmor packages"
        fi
    else
        log_success "All AppArmor packages already installed"
    fi
}

# Configure kernel parameters
configure_kernel_apparmor() {
    info "Configuring kernel parameters for AppArmor..."
    
    local grub_config="/etc/default/grub"
    local kernel_params="apparmor=1 security=apparmor"
    local reboot_required=false
    
    # Check current kernel command line
    if grep -q "apparmor=1" /proc/cmdline && grep -q "security=apparmor" /proc/cmdline; then
        log_success "AppArmor kernel parameters already configured"
    else
        warn "AppArmor not enabled in kernel. Configuring GRUB..."
        
        # Backup GRUB configuration
        cp "$grub_config" "${grub_config}.bak.$(date +%Y%m%d_%H%M%S)"
        
        # Update GRUB configuration
        if grep -q "GRUB_CMDLINE_LINUX_DEFAULT" "$grub_config"; then
            if ! grep -q "apparmor=1" "$grub_config"; then
                sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/&${kernel_params} /" "$grub_config"
                reboot_required=true
            fi
        else
            echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${kernel_params}\"" >> "$grub_config"
            reboot_required=true
        fi
        
        if [ "$reboot_required" = true ]; then
            log "Updating GRUB configuration..."
            if ! update-grub; then
                error_exit "Failed to update GRUB configuration"
            fi
            
            warn "System reboot required to enable AppArmor in kernel"
            warn "Run 'sudo reboot' and then re-run this script"
            exit 2
        fi
    fi
}

# Enable and start AppArmor service
configure_apparmor_service() {
    info "Configuring AppArmor service..."
    
    # Enable AppArmor service
    if ! systemctl is-enabled apparmor >/dev/null 2>&1; then
        log "Enabling AppArmor service..."
        if ! systemctl enable apparmor; then
            error_exit "Failed to enable AppArmor service"
        fi
    fi
    
    # Start AppArmor service
    if ! systemctl is-active apparmor >/dev/null 2>&1; then
        log "Starting AppArmor service..."
        if ! systemctl start apparmor; then
            error_exit "Failed to start AppArmor service"
        fi
    fi
    
    log_success "AppArmor service is active and enabled"
}

# Verify AppArmor functionality
verify_apparmor_functionality() {
    info "Verifying AppArmor functionality..."
    
    local checks_passed=0
    local total_checks=6
    
    # Check 1: AppArmor module loaded
    if [ -d /sys/module/apparmor ]; then
        log_success "✓ AppArmor kernel module loaded"
        ((checks_passed++))
    else
        log_error "✗ AppArmor kernel module not loaded"
    fi
    
    # Check 2: AppArmor filesystem mounted
    if [ -d /sys/kernel/security/apparmor ]; then
        log_success "✓ AppArmor security filesystem mounted"
        ((checks_passed++))
    else
        log_error "✗ AppArmor security filesystem not mounted"
    fi
    
    # Check 3: AppArmor enabled in kernel
    if grep -q "apparmor=1" /proc/cmdline; then
        log_success "✓ AppArmor enabled in kernel"
        ((checks_passed++))
    else
        log_error "✗ AppArmor not enabled in kernel"
    fi
    
    # Check 4: AppArmor security model active
    if grep -q "apparmor" /sys/kernel/security/lsm 2>/dev/null; then
        log_success "✓ AppArmor security model active"
        ((checks_passed++))
    else
        log_error "✗ AppArmor security model not active"
    fi
    
    # Check 5: Profile loading interface available
    if [ -f /proc/thread-self/attr/apparmor/exec ]; then
        log_success "✓ AppArmor profile interface available"
        ((checks_passed++))
    else
        log_error "✗ AppArmor profile interface not available"
    fi
    
    # Check 6: AppArmor utilities functional
    if command -v aa-status >/dev/null 2>&1 && aa-status >/dev/null 2>&1; then
        log_success "✓ AppArmor utilities functional"
        ((checks_passed++))
    else
        log_error "✗ AppArmor utilities not functional"
    fi
    
    echo ""
    echo -e "${BLUE}=== AppArmor Verification Summary ===${NC}"
    echo "====================================="
    echo -e "Checks passed: ${GREEN}$checks_passed${NC}/${total_checks}"
    
    if [ "$checks_passed" -eq "$total_checks" ]; then
        log_success "All AppArmor functionality checks passed"
        return 0
    else
        log_error "AppArmor verification failed ($checks_passed/$total_checks checks passed)"
        return 1
    fi
}

# Display AppArmor status
show_apparmor_status() {
    info "Current AppArmor status:"
    echo ""
    
    if command -v aa-status >/dev/null 2>&1; then
        aa-status 2>/dev/null || {
            warn "AppArmor status not available - service may not be running"
        }
    fi
}

# Configure Docker AppArmor integration
configure_docker_apparmor() {
    info "Configuring Docker AppArmor integration..."
    
    if ! command -v docker >/dev/null 2>&1; then
        warn "Docker not installed - skipping Docker AppArmor configuration"
        return 0
    fi
    
    local docker_apparmor_dir="/etc/apparmor.d/docker"
    if [ ! -d "$docker_apparmor_dir" ]; then
        mkdir -p "$docker_apparmor_dir"
        log "Created Docker AppArmor directory: $docker_apparmor_dir"
    fi
}

# Create AppArmor startup service
create_apparmor_startup_service() {
    info "Creating AppArmor startup service..."
    
    local service_file="/etc/systemd/system/apparmor-n8n.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=Load N8N AppArmor Profiles
Documentation=man:apparmor(7)
After=apparmor.service
Wants=apparmor.service
Before=docker.service
ConditionPathExists=/sys/kernel/security/apparmor

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SCRIPT_DIR}/load-apparmor-profiles.sh
ExecReload=/bin/bash -c 'aa-status | grep -q "n8n.*profile" && echo "N8N profiles active" || ${SCRIPT_DIR}/load-apparmor-profiles.sh'
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable the service
    if systemctl enable apparmor-n8n.service; then
        log_success "AppArmor N8N service created and enabled"
    else
        warn "Failed to enable AppArmor N8N service"
    fi
}

# Main execution flow
main() {
    validate_debian_system
    install_apparmor_packages
    configure_kernel_apparmor
    configure_apparmor_service
    configure_docker_apparmor
    create_apparmor_startup_service
    
    echo ""
    if verify_apparmor_functionality; then
        show_apparmor_status
        
        info "Loading N8N AppArmor profiles..."
        if "${SCRIPT_DIR}/load-apparmor-profiles.sh"; then
            log_success "N8N AppArmor profiles loaded"
        else
            error_exit "Failed to load N8N AppArmor profiles"
        fi
        
        echo ""
        echo -e "${GREEN}=== AppArmor Setup Complete ===${NC}"
        echo "==============================="
        log_success "AppArmor is properly configured and functional"
        
        info "Next steps:"
        echo "  1. Deploy containers: docker compose -f compose.yml -f compose.prod.yml up -d"
        echo "  2. Verify profiles: sudo aa-status | grep n8n_"
        echo "  3. Monitor denials: journalctl -f | grep apparmor"
        
        exit 0
    else
        echo ""
        echo -e "${RED}=== AppArmor Setup Issues ===${NC}"
        echo "============================="
        warn "AppArmor setup completed with issues"
        
        info "Troubleshooting:"
        echo "  1. Reboot system if kernel parameters were changed"
        echo "  2. Check AppArmor service: systemctl status apparmor"
        echo "  3. Verify kernel support: cat /sys/kernel/security/lsm"
        echo "  4. Check logs: journalctl -u apparmor"
        
        exit 1
    fi
}

print_script_footer "AppArmor Debian Setup"

main "$@"
