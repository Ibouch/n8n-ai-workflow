#!/bin/bash
# Security Setup Script for N8N Infrastructure
# Configures AppArmor profiles and additional security measures

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root to configure security profiles"
fi

log "Setting up security profiles for N8N infrastructure..."

# 1. Install AppArmor if not present
if ! command -v apparmor_parser >/dev/null 2>&1; then
    log "Installing AppArmor..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y apparmor-utils
    elif command -v yum >/dev/null 2>&1; then
        yum install -y apparmor-utils
    else
        warn "Could not install AppArmor automatically. Please install manually."
    fi
fi

# 2. Load AppArmor profiles
if command -v apparmor_parser >/dev/null 2>&1; then
    log "Loading AppArmor profiles..."
    
    # Copy profiles to system directory
    cp "${PROJECT_ROOT}/security/apparmor-profiles/"* /etc/apparmor.d/
    
    # Load profiles
    apparmor_parser -r /etc/apparmor.d/n8n-profile
    apparmor_parser -r /etc/apparmor.d/postgres-profile
    apparmor_parser -r /etc/apparmor.d/nginx-profile
    apparmor_parser -r /etc/apparmor.d/redis-profile
    
    # Enable AppArmor service
    systemctl enable apparmor
    systemctl start apparmor
    
    log "AppArmor profiles loaded successfully"
else
    warn "AppArmor not available on this system"
fi

# 3. Configure additional kernel security parameters
log "Configuring kernel security parameters..."

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
log "Setting up audit rules..."

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

# AppArmor monitoring
-w /etc/apparmor/ -p wa -k apparmor
-w /sys/module/apparmor/ -p wa -k apparmor-module

# Capability use monitoring
-a always,exit -F arch=b64 -S capset -k capability-use
-a always,exit -F arch=b32 -S capset -k capability-use

# Process execution monitoring
-a always,exit -F arch=b64 -S execve -k process-execution
-a always,exit -F arch=b32 -S execve -k process-execution
EOF

    systemctl restart auditd
    log "Audit rules configured"
else
    warn "auditd not available - install audit package for enhanced monitoring"
fi

# 5. Configure fail2ban for additional protection
log "Setting up fail2ban..."

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
    log "fail2ban configured for nginx protection"
else
    warn "fail2ban not available - consider installing for additional protection"
fi

# 6. Set up log rotation for security logs
log "Configuring log rotation..."

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
log "Creating security monitoring script..."

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

log "Security setup completed successfully!"
log "Security measures implemented:"
log "  ✅ AppArmor profiles for containers"
log "  ✅ Kernel security parameters"
log "  ✅ Audit rules for monitoring"
log "  ✅ fail2ban protection"
log "  ✅ Log rotation configuration"
log "  ✅ Security monitoring automation"

warn "Please verify that your applications still function correctly after these changes"
warn "Monitor security logs at: /var/log/n8n-security.log"