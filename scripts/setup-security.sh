#!/bin/bash
# Security Setup Script for N8N Infrastructure
# Configures host-level security measures

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Initialize common environment (no Docker requirement)
init_common false false
change_to_project_root

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error_exit "This script must be run as root to configure security profiles"
fi

# Parse command line arguments
SETUP_DOCKER_DAEMON=false
FULL_SETUP=true

for arg in "$@"; do
    case $arg in
        --docker-daemon)
            SETUP_DOCKER_DAEMON=true
            FULL_SETUP=false
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "  --docker-daemon    Setup Docker daemon security configuration only"
            echo "  --help|-h          Show this help message"
            exit 0
            ;;
    esac
done

if [ "$SETUP_DOCKER_DAEMON" = "true" ]; then
    log_info "Setting up Docker daemon security configuration..."
else
    log_info "Setting up security profiles for N8N infrastructure..."
fi

# Function to setup Docker daemon security configuration
setup_docker_daemon_security() {
    log_info "Configuring Docker daemon security settings..."
    
    local docker_config="/etc/docker/daemon.json"
    local backup_file="/etc/docker/daemon.json.backup.$(date +%Y%m%d_%H%M%S)"
    local seccomp_profile="${PROJECT_ROOT}/security/seccomp-profile.json"
    
    # Create /etc/docker directory if it doesn't exist
    mkdir -p /etc/docker
    
    # Backup existing configuration if it exists
    if [ -f "$docker_config" ]; then
        log_info "Backing up existing Docker daemon configuration to $backup_file"
        cp "$docker_config" "$backup_file"
        
        # Parse existing JSON and add security settings
        local temp_config="/tmp/daemon.json.tmp"
        
        if command -v jq >/dev/null 2>&1; then
            # Use jq if available for proper JSON merging
            jq --arg sp "$seccomp_profile" '. + {
                "no-new-privileges": true,
                "userns-remap": "default",
                "log-driver": "json-file",
                "log-opts": {
                    "max-size": "10m",
                    "max-file": "3"
                },
                "icc": false,
                "userland-proxy": false,
                "experimental": false,
                "live-restore": true,
                "seccomp-profile": $sp
            }' "$docker_config" > "$temp_config"
            mv "$temp_config" "$docker_config"
        else
            # Fallback: manual JSON construction
            warn "jq not available. Creating new daemon.json with security settings."
            setup_docker_daemon_security_fallback "$docker_config"
        fi
    else
        # Create new configuration file
        setup_docker_daemon_security_fallback "$docker_config"
    fi
    
    # Set proper permissions
    chmod 644 "$docker_config"
    
    log_info "Docker daemon security configuration updated"
    log_info "Changes will take effect after Docker restart: sudo systemctl restart docker"
    warn "Restarting Docker will temporarily stop all containers"
}

# Fallback function to create Docker daemon config without jq
setup_docker_daemon_security_fallback() {
    local docker_config="$1"
    
    cat > "$docker_config" << EOF
{
  "no-new-privileges": true,
  "userns-remap": "default",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "icc": false,
  "userland-proxy": false,
  "experimental": false,
  "live-restore": true,
  "seccomp-profile": "${PROJECT_ROOT}/security/seccomp-profile.json"
}
EOF
}

# If only Docker daemon setup is requested, do that and exit
if [ "$SETUP_DOCKER_DAEMON" = "true" ]; then
    setup_docker_daemon_security
    log_info "Docker daemon security setup completed!"
    log_info "To apply changes, restart Docker: sudo systemctl restart docker"
    exit 0
fi

 

# 3. Configure additional kernel security parameters
log_info "Configuring kernel security parameters..."

cat > /etc/sysctl.d/99-n8n-security.conf << 'EOF'
# Network security
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1

# IPv6 security
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Kernel hardening
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1

# Memory protection
vm.mmap_rnd_bits = 32
vm.mmap_rnd_compat_bits = 16

# File system security
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
EOF

sysctl --system

# 4. Configure audit rules
log_info "Setting up audit rules..."

if command -v auditctl >/dev/null 2>&1; then
    cat > /etc/audit/rules.d/n8n-security.rules << 'EOF'
# Monitor Docker daemon
-w /usr/bin/docker -p x -k docker
-w /var/lib/docker -p wa -k docker
-w /etc/docker -p wa -k docker

# Monitor container runtime
-w /var/run/docker.sock -p wa -k docker-socket
-w /var/lib/containerd -p wa -k containerd

# Monitor N8N specific directories
-w /opt/n8n -p wa -k n8n-files
-w /etc/systemd/system/docker.service -p wa -k docker-service

# System integrity
-w /etc/passwd -p wa -k passwd-changes
-w /etc/group -p wa -k group-changes
-w /etc/shadow -p wa -k shadow-changes
-w /etc/sudoers -p wa -k sudoers-changes

# Network configuration changes
-w /etc/network/ -p wa -k network-config
-w /etc/hosts -p wa -k hosts-file
-w /etc/hostname -p wa -k hostname

 

# Capability use monitoring
-a always,exit -F arch=b64 -S capset -k capability-use
-a always,exit -F arch=b32 -S capset -k capability-use

# Process execution monitoring
-a always,exit -F arch=b64 -S execve -k process-execution
-a always,exit -F arch=b32 -S execve -k process-execution
EOF

    systemctl restart auditd
    log_info "Audit rules configured"
else
    warn "auditd not available - install audit package for enhanced monitoring"
fi

# 5. Configure fail2ban for additional protection
log_info "Setting up fail2ban..."

if command -v fail2ban-client >/dev/null 2>&1; then
    cat > /etc/fail2ban/jail.d/n8n.conf << 'EOF'
[nginx-auth]
enabled = true
filter = nginx-auth
logpath = /var/log/nginx/error.log
maxretry = 3
bantime = 3600
findtime = 600

[nginx-noscript]
enabled = true
filter = nginx-noscript
logpath = /var/log/nginx/access.log
maxretry = 6
bantime = 86400
findtime = 60

[nginx-badbots]
enabled = true
filter = nginx-badbots
logpath = /var/log/nginx/access.log
maxretry = 2
bantime = 86400
findtime = 60

[nginx-noproxy]
enabled = true
filter = nginx-noproxy
logpath = /var/log/nginx/access.log
maxretry = 2
bantime = 86400
findtime = 60
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    log_info "fail2ban configured for nginx protection"
else
    warn "fail2ban not available - consider installing for additional protection"
fi

# 6. Set up log rotation for security logs
log_info "Configuring log rotation..."

cat > /etc/logrotate.d/n8n-security << 'EOF'
/var/log/n8n-security.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    copytruncate
    notifempty
    create 0640 root root
}

/var/log/n8n-network-monitor.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    copytruncate
    notifempty
    create 0640 root root
}
EOF

# 7. Create security monitoring script
log_info "Creating security monitoring script..."

cat > /usr/local/bin/n8n-security-monitor.sh << 'EOF'
#!/bin/bash
# N8N Security Monitoring Script

LOGFILE="/var/log/n8n-security.log"

log_security_event() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] SECURITY: $1" >> "$LOGFILE"
}

# Check for unusual Docker events
check_docker_events() {
    # Monitor container creation/deletion
    docker events --since="5m" --format "{{.Time}} {{.Type}} {{.Action}} {{.Actor.Attributes.name}}" | while read event; do
        if echo "$event" | grep -E "(create|destroy|kill|die)" >/dev/null; then
            log_security_event "Docker event: $event"
        fi
    done
}

# Check for failed login attempts
check_failed_logins() {
    failed_logins=$(journalctl --since="5 minutes ago" | grep -i "failed\|authentication failure" | wc -l)
    if [ "$failed_logins" -gt 10 ]; then
        log_security_event "High number of failed login attempts: $failed_logins"
    fi
}

# Check for unusual network connections
check_network_connections() {
    unusual_connections=$(netstat -tupln | grep -E ":22[0-9][0-9]|:3[0-9][0-9][0-9]|:4[0-9][0-9][0-9]" | wc -l)
    if [ "$unusual_connections" -gt 5 ]; then
        log_security_event "Unusual network connections detected: $unusual_connections"
    fi
}

# Main monitoring loop
check_docker_events &
check_failed_logins
check_network_connections

log_security_event "Security monitoring check completed"
EOF

chmod +x /usr/local/bin/n8n-security-monitor.sh

# 8. Create systemd timer for security monitoring
cat > /etc/systemd/system/n8n-security-monitor.service << 'EOF'
[Unit]
Description=N8N Security Monitor
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/n8n-security-monitor.sh
User=root
StandardOutput=journal
StandardError=journal
EOF

cat > /etc/systemd/system/n8n-security-monitor.timer << 'EOF'
[Unit]
Description=Run N8N Security Monitor every 5 minutes
Requires=n8n-security-monitor.service

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable n8n-security-monitor.timer
systemctl start n8n-security-monitor.timer

# 9. Setup Docker daemon security (for full setup)
if [ "$FULL_SETUP" = "true" ]; then
    setup_docker_daemon_security
fi

log_info "Security setup completed successfully!"
log_info "Security measures implemented:"
log_info "  ✅ Kernel security parameters"
log_info "  ✅ Audit rules for monitoring"
log_info "  ✅ fail2ban protection"
log_info "  ✅ Log rotation configuration"
log_info "  ✅ Security monitoring automation"
if [ "$FULL_SETUP" = "true" ]; then
    log_info "  ✅ Docker daemon security configuration"
fi

warn "Please verify that your applications still function correctly after these changes"
warn "Monitor security logs at: /var/log/n8n-security.log"
if [ "$FULL_SETUP" = "true" ]; then
    warn "Restart Docker to apply daemon security changes: sudo systemctl restart docker"
fi