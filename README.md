# N8N Production Infrastructure

[![Docker](https://img.shields.io/badge/Docker-20.10+-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![Security](https://img.shields.io/badge/Security-Hardened-green?logo=shield&logoColor=white)](https://github.com/user/repo/actions)
[![Monitoring](https://img.shields.io/badge/Monitoring-Prometheus%20%7C%20Grafana-orange?logo=prometheus&logoColor=white)](https://prometheus.io/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.0.0-brightgreen)](https://github.com/user/repo/releases)

> Enterprise-grade N8N workflow automation with comprehensive security, monitoring, and management.

## Prerequisites

- **Docker Engine** 20.10+ with Compose 2.0+
- **Linux host** (required for AppArmor security profiles)
- **Domain name** with DNS pointing to your server
- **SSL certificates** (Let's Encrypt recommended)

## 🚀 Installation

### 1. Initial Setup

```bash
# Clone repository
git clone <repository-url> && cd <repository-url>

# Install dependencies & prepare environment
./scripts/install-dependencies.sh
./scripts/generate-secrets.sh
cp env.example .env
```

### 2. Configure Environment

Edit `.env` with your settings:

```bash
# Domain Configuration
N8N_HOST=your-domain.com
N8N_PROTOCOL=https
WEBHOOK_URL=https://your-domain.com/

# Email Settings
SMTP_HOST=smtp-mail.your-domain.com
SMTP_PORT=587
SMTP_USERNAME=your-email@your-domain.com
ALERT_EMAIL_TO=admin@your-domain.com

# Service Users (passwords auto-generated in secrets/)
POSTGRES_USER=n8n_admin
N8N_ADMIN_USER=admin
GRAFANA_ADMIN_USER=admin
```

### 3. SSL Certificates

```bash
# Generate certificates with Let's Encrypt
sudo certbot certonly --standalone -d your-domain.com

# Copy to project (script handles permissions)
sudo cp /etc/letsencrypt/live/your-domain.com/fullchain.pem nginx/ssl/
sudo cp /etc/letsencrypt/live/your-domain.com/privkey.pem nginx/ssl/key.pem
sudo chown $USER:$USER nginx/ssl/*.pem
```

### 4. Deploy

```bash
# Validate configuration
./scripts/validate-infrastructure.sh

# Setup security profiles (requires reboot if AppArmor not enabled)
sudo ./scripts/setup-apparmor.sh

# Deploy services
docker compose -f compose.yml -f compose.prod.yml up -d

# Verify deployment
./scripts/health-check.sh
```

**Access your instance**: `https://your-domain.com`  
**Credentials**: Check `secrets/n8n_password.txt`

## 🔒 Security Architecture

### Defense Layers

| Layer | Implementation |
|-------|---------------|
| **Container Isolation** | Non-root users, read-only filesystems, minimal capabilities |
| **Mandatory Access Control** | AppArmor profiles for all services |
| **Network Segmentation** | DMZ (172.20.0.0/24) ↔ Internal (172.21.0.0/24) |
| **Secrets Management** | Docker secrets with age encryption |
| **SSL/TLS** | Force HTTPS, modern cipher suites, HSTS enabled |

### AppArmor Profiles

Security profiles automatically load on boot via systemd:

```bash
# Check profile status
sudo aa-status | grep n8n

# Monitor security violations
journalctl -f | grep apparmor

# Manual reload if needed
sudo ./scripts/load-apparmor-profiles.sh
```

## 📊 Monitoring

### Access Points

- **Grafana**: `http://localhost:3000` - Dashboards & alerts
- **Prometheus**: `http://localhost:9090` - Metrics store
- **Alertmanager**: `http://localhost:9093` - Alert routing

### Dashboard Setup

1. Login to Grafana (credentials in `secrets/grafana_password.txt`)
2. Import dashboards:
   - Container Metrics: `893`
   - PostgreSQL: `9628`
   - Redis: `763`

### Alert Configuration

Edit monitoring configs and reload without restart:

```bash
vim monitoring/prometheus/alerts.yml
docker compose exec prometheus kill -HUP 1
vim monitoring/alertmanager/alertmanager.yml
docker compose exec alertmanager kill -HUP 1
```

## 🔄 Operations

### Daily Management

```bash
# Health monitoring
./scripts/health-check.sh

# View logs
docker compose logs -f <service>

# Backup data
./scripts/backup.sh
```

### Maintenance Tasks

```bash
# Update services
./scripts/update.sh

# Rotate secrets
./scripts/generate-secrets.sh --force
docker compose up -d --force-recreate

# Certificate renewal (add to crontab)
0 3 * * * certbot renew --quiet --post-hook "docker compose restart nginx"
```

## 💾 Backup & Recovery

### Automated Backups

```bash
# Manual backup
./scripts/backup.sh

# Schedule daily backups (crontab)
0 2 * * * cd /path/to/n8n && ./scripts/backup.sh
```

Backups include:
- PostgreSQL database
- N8N workflows & credentials
- Redis cache
- Configuration files
  (Secrets are intentionally excluded; back up the `secrets/` directory separately and securely)

### Recovery Process

```bash
# Stop services
docker compose down

# Locate backup
BACKUP_DIR=$(ls -t volumes/backups | head -1)
cd volumes/backups/$BACKUP_DIR

# Restore database
age -d -i ../../secrets/age-key.txt postgres_backup.dump.age > /tmp/postgres_backup.dump
docker cp /tmp/postgres_backup.dump $(docker compose ps -q postgres):/tmp/postgres_backup.dump
docker compose exec -T postgres pg_restore -U <POSTGRES_USER> -d <POSTGRES_DB> -c -v /tmp/postgres_backup.dump

# Restore N8N data
age -d -i ../../secrets/age-key.txt n8n_data.tar.age | \
  docker compose exec -T n8n tar -xf - -C /home/node

# Restore Redis
age -d -i ../../secrets/age-key.txt redis_backup.rdb.age > /tmp/dump.rdb
docker cp /tmp/dump.rdb $(docker compose ps -q redis):/data/dump.rdb
docker compose restart redis

# Restart services
docker compose up -d
./scripts/health-check.sh
```

## 🔧 Troubleshooting

### Common Issues

**Services not starting**
```bash
# Check logs
docker compose logs <service>

# Validate configuration
./scripts/validate-infrastructure.sh
```

**Permission denied errors**
```bash
# Fix ownership
sudo chown -R $USER:$USER .
chmod 600 secrets/*.txt
```

**SSL certificate issues**
```bash
# Verify certificates
openssl x509 -in nginx/ssl/fullchain.pem -text -noout

# Check permissions
ls -la nginx/ssl/
```

**AppArmor blocking operations**
```bash
# If you see: "write /proc/thread-self/attr/apparmor/exec: no such file"
sudo ./scripts/setup-apparmor.sh
# Reboot if requested, then re-run
```

### Log Locations

- **Service logs**: `docker compose logs <service>`
- **Script logs**: `~/.n8n-scripts.log` or `/tmp/n8n-scripts-*.log`
- **Security events**: `journalctl -f | grep apparmor`

## 📁 Project Structure

```
h2g2/
├── compose.yml                 # Core services
├── compose.prod.yml            # Production overrides (monitoring stack)
├── env.example                 # Example environment file
├── nginx/
│   ├── nginx.conf              # Web server config
│   ├── conf.d/                 # Site configs
│   │   ├── n8n.conf
│   │   └── monitoring.conf
│   └── ssl/                    # SSL certificates (place fullchain.pem, key.pem)
├── monitoring/                 # Prometheus, Grafana, Loki, Alertmanager, Promtail
│   ├── prometheus/
│   ├── grafana/
│   ├── loki/
│   ├── promtail/
│   └── alertmanager/
├── security/                   # Security profiles
│   ├── apparmor-profiles/
│   └── seccomp-profile.json
├── scripts/                    # Management utilities
│   ├── *.sh
│   └── lib/
└── volumes/                    # Persistent data (created at runtime)
    └── backups/                # Encrypted backups created by backup script
```

## 📚 Script Reference

### Core Setup Scripts

```bash
# Install Docker and system dependencies
./scripts/install-dependencies.sh

# Generate secrets and create SSL directory structure
./scripts/generate-secrets.sh
./scripts/generate-secrets.sh --force  # Force regenerate all

# Validate system before deployment
./scripts/validate-infrastructure.sh
./scripts/validate-infrastructure.sh network  # Check specific component (network, secrets etc.)
```

### Security Scripts

```bash
# Setup AppArmor profiles (requires root)
sudo ./scripts/setup-apparmor.sh

# Reload AppArmor profiles manually (requires root)
sudo ./scripts/load-apparmor-profiles.sh

# Complete security hardening (requires root)
sudo ./scripts/setup-security.sh
sudo ./scripts/setup-security.sh --docker-daemon  # Docker daemon only

# Network security and firewall (requires root)
sudo ./scripts/network-security.sh

# Validate security deployment
./scripts/validate-deployment.sh
```

### Operations Scripts

```bash
# Health monitoring
./scripts/health-check.sh

# Backup management
./scripts/backup.sh
BACKUP_RETENTION_DAYS=30 ./scripts/backup.sh  # Custom retention

# Update services with rollback capability
./scripts/update.sh
```

---

**⚠️ Production Note**: Always run `health-check.sh` after changes and maintain regular backups.