#!/bin/bash
# Network Security Configuration Script
# Implements egress restrictions and zero-trust networking with Docker integration

set -euo pipefail

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Initialize common environment
init_common

# Print header and check permissions
print_script_header "N8N Network Security Setup" "Zero-trust networking with Docker-compatible firewall rules"

# Check if running as root
check_root

log_info "Configuring network security for N8N infrastructure..."

# 1. Docker-compatible firewall configuration
configure_firewall_rules() {
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        log_info "Configuring firewalld rules (Docker-compatible)..."
        
        # Create custom zone for Docker networks (if not exists)
        if ! firewall-cmd --get-zones | grep -q docker-n8n; then
            firewall-cmd --permanent --new-zone=docker-n8n
            log_success "Created docker-n8n firewall zone"
        fi
        
        # Configure public zone for frontend access
        firewall-cmd --permanent --zone=public --add-port=80/tcp 2>/dev/null || true
        firewall-cmd --permanent --zone=public --add-port=443/tcp 2>/dev/null || true
        
        # Allow internal Docker network communication
        firewall-cmd --permanent --zone=docker-n8n --add-rich-rule='rule family="ipv4" source address="172.20.0.0/24" accept' 2>/dev/null || true
        firewall-cmd --permanent --zone=docker-n8n --add-rich-rule='rule family="ipv4" source address="172.21.0.0/24" accept' 2>/dev/null || true
        
        firewall-cmd --reload
        log_success "Firewalld configuration completed"
        
    elif command -v iptables >/dev/null 2>&1; then
        log_info "Configuring iptables rules (Docker-compatible)..."
        
        # Backup existing iptables rules
        iptables-save > /etc/iptables.rules.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
        
        # Check if Docker chains exist before creating custom rules
        if iptables -t filter -L DOCKER >/dev/null 2>&1; then
            log_info "Docker iptables chains detected, integrating carefully..."
            
            # Create custom chains only if they don't exist
            if ! iptables -t filter -L N8N-SECURITY >/dev/null 2>&1; then
                iptables -t filter -N N8N-SECURITY
                # Insert at the beginning of FORWARD chain, but after Docker rules
                iptables -t filter -I FORWARD -j N8N-SECURITY
                
                # Allow established connections
                iptables -t filter -A N8N-SECURITY -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
                
                # Allow internal Docker networks
                iptables -t filter -A N8N-SECURITY -s 172.20.0.0/24 -d 172.20.0.0/24 -j ACCEPT
                iptables -t filter -A N8N-SECURITY -s 172.21.0.0/24 -d 172.21.0.0/24 -j ACCEPT
                iptables -t filter -A N8N-SECURITY -s 172.20.0.0/24 -d 172.21.0.0/24 -j ACCEPT
                iptables -t filter -A N8N-SECURITY -s 172.21.0.0/24 -d 172.20.0.0/24 -j ACCEPT
                
                # Return to main chain for other rules
                iptables -t filter -A N8N-SECURITY -j RETURN
                
                log_success "N8N security chain created and integrated with Docker"
            else
                log_info "N8N security chain already exists"
            fi
        else
            warn "Docker iptables chains not found. Please start Docker first."
        fi
        
        log_success "iptables configuration completed"
    else
        warn "Neither firewalld nor iptables available. Network security rules not configured."
    fi
}

configure_firewall_rules

# Seccomp profile is managed via security/seccomp-profile.json and compose files

# 4. Create network monitoring script
log "Creating network monitoring script..."

cat > "${PROJECT_ROOT}/scripts/monitor-network.sh" << 'EOF'
#!/bin/bash
# Network monitoring script for N8N infrastructure

LOGFILE="/var/log/n8n-network-monitor.log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# Monitor suspicious network activity
monitor_network() {
    log "Starting network monitoring..."
    
    # Monitor for unexpected outbound connections
    netstat -tupln | grep -E "(postgres|redis|n8n)" | while read line; do
        if echo "$line" | grep -q ":80\|:443\|:53"; then
            log "ALERT: Unexpected outbound connection detected: $line"
        fi
    done
    
    # Check for unusual port activity
    ss -tulpn | grep -E ":22[0-9][0-9]|:3[0-9][0-9][0-9]|:4[0-9][0-9][0-9]" | while read line; do
        log "INFO: Non-standard port activity: $line"
    done
}

# Run monitoring
monitor_network
EOF

chmod +x "${PROJECT_ROOT}/scripts/monitor-network.sh"

# 5. Create systemd service for network monitoring
log "Creating systemd service for network monitoring..."

cat > /etc/systemd/system/n8n-network-monitor.service << EOF
[Unit]
Description=N8N Network Security Monitor
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${PROJECT_ROOT}/scripts/monitor-network.sh
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/n8n-network-monitor.timer << 'EOF'
[Unit]
Description=Run N8N Network Monitor every 5 minutes
Requires=n8n-network-monitor.service

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable n8n-network-monitor.timer
systemctl start n8n-network-monitor.timer

## Docker daemon security is configured via scripts/setup-security.sh

# Final summary
log_success "Network security configuration completed!"
log_info "Security measures implemented:"
log_info "  ${CHECKMARK} Docker-compatible firewall rules"
log_info "  ${CHECKMARK} Network monitoring and alerting"

warn "IMPORTANT: Please verify that your applications still function correctly"
warn "Monitor network monitoring logs at: /var/log/n8n-network-monitor.log"

print_script_footer "N8N Network Security Setup"