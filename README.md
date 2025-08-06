# 🚀 N8N Production Infrastructure

[![Docker](https://img.shields.io/badge/Docker-20.10+-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![Security](https://img.shields.io/badge/Security-Hardened-green?logo=shield&logoColor=white)](https://github.com/user/repo/actions)
[![Monitoring](https://img.shields.io/badge/Monitoring-Prometheus%20%7C%20Grafana-orange?logo=prometheus&logoColor=white)](https://prometheus.io/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.0.0-brightgreen)](https://github.com/user/repo/releases)

> **Production-ready, security-hardened N8N workflow automation infrastructure** with enterprise-grade security, comprehensive monitoring, and unified management.

## 🚀 Quick Start & Deployment

### Prerequisites
- Docker Engine 20.10+ & Docker Compose 2.0+
- Linux host (recommended for security features)

### Complete Setup Process

```bash
# 1. Clone and navigate
git clone <repository-url> && cd n8n

# 2. Generate secrets (first time only)
./scripts/generate-secrets.sh

# 3. Validate system requirements
./scripts/validate-infrastructure.sh

# 4. Configure environment (optional)
cp env.example .env
# Edit: N8N_HOST, N8N_PROTOCOL, WEBHOOK_URL

# 5. Deploy with production monitoring
docker-compose -f compose.yml -f compose.prod.yml up -d

# 6. Setup security hardening (run as root)
sudo ./scripts/setup-security.sh
sudo ./scripts/network-security.sh

# 7. Verify deployment health
./scripts/health-check.sh
```

**🎯 Access**: https://localhost (credentials in `secrets/n8n_*`)

## 🔒 Security Features

**Defense-in-depth architecture** with comprehensive threat mitigation:

| **Security Layer** | **Implementation** |
|-------------------|-------------------|
| **Container Hardening** | Non-root execution, read-only filesystems, seccomp profiles |
| **Network Segmentation** | DMZ (172.20.0.0/24) ↔ Internal (172.21.0.0/24) isolation |
| **Secrets Management** | Docker secrets, age encryption, secure generation |
| **Access Control** | Zero external backend access, minimal capabilities |
| **Monitoring** | Security events, audit logs, comprehensive health checks |

## ⚙️ Configuration

### Environment Setup (.env)
```bash
# Domain & Protocol
N8N_HOST=your-domain.com
N8N_PROTOCOL=https
WEBHOOK_URL=https://your-domain.com/

# SMTP Configuration
SMTP_HOST=smtp-mail.outlook.com
SMTP_PORT=587
SMTP_USERNAME=your-email@outlook.com
ALERT_EMAIL_TO=admin@your-domain.com
```

### SSL Certificates
```bash
# Place certificates in nginx/ssl/
nginx/ssl/
├── fullchain.pem     # Certificate chain
├── key.pem           # Private key
└── dhparam.pem       # DH parameters
```

## 📊 Monitoring & Observability

### Monitoring Stack Components

**Production monitoring stack** (localhost access only):
- **Grafana**: http://localhost:3000 - Dashboards and alerting
- **Prometheus**: http://localhost:9090 - Metrics collection  
- **Alertmanager**: http://localhost:9093 - Alert routing
- **Loki**: Log aggregation and analysis
- **Promtail**: Log collection agent

### Initial Monitoring Setup

```bash
# 1. Deploy with monitoring stack
docker-compose -f compose.yml -f compose.prod.yml up -d

# 2. Verify monitoring services
docker-compose ps | grep -E "(prometheus|grafana|loki|alertmanager)"

# 3. Access Grafana (credentials in secrets/grafana_*)
open http://localhost:3000

# 4. Import N8N dashboards (optional)
# - Container metrics dashboard ID: 893
# - PostgreSQL dashboard ID: 9628
# - Redis dashboard ID: 763
```

### Monitoring Configuration

**Prometheus Targets**:
- N8N application metrics: `n8n:5678/metrics`
- PostgreSQL metrics: `postgres-exporter:9187`
- Redis metrics: `redis-exporter:9121`
- System metrics: `node-exporter:9100`
- Container metrics: `cadvisor:8080`

**Alert Rules**:
- Service health checks (1-minute intervals)
- Resource utilization warnings (>80% threshold)
- Security events (failed logins, unusual traffic)
- Application performance (response times, errors)

### Custom Alerts Setup

```bash
# Edit alert rules
vim monitoring/prometheus/alerts.yml

# Add custom alert rules
vim monitoring/alertmanager/alertmanager.yml

# Reload configuration (no restart needed)
docker-compose exec prometheus kill -HUP 1
docker-compose exec alertmanager kill -HUP 1
```

## 🛠️ Management Commands

| **Operation** | **Command** | **Purpose** |
|---------------|-------------|-------------|
| **Health Check** | `./scripts/health-check.sh` | Comprehensive service monitoring |
| **Backup** | `./scripts/backup.sh` | Encrypted backups with verification |
| **Update** | `./scripts/update.sh` | Safe updates with rollback |
| **Validate** | `./scripts/validate-infrastructure.sh` | System validation |
| **Security** | `sudo ./scripts/setup-security.sh` | AppArmor profiles & audit rules |

## 🔐 Secrets Management

### Secret Generation and Setup

```bash
# Generate all required secrets (first time setup)
./scripts/generate-secrets.sh

# Force regenerate all secrets (security rotation)
./scripts/generate-secrets.sh --force

# Validate all secrets are properly configured
./scripts/validate-infrastructure.sh secrets
```

### Required Secrets Structure

```
secrets/
├── postgres_user.txt         # Database username
├── postgres_password.txt     # Database password (32 chars)
├── n8n_user.txt             # N8N admin username
├── n8n_password.txt         # N8N admin password (24 chars)
├── n8n_encryption_key.txt   # N8N data encryption key (64 chars)
├── redis_password.txt       # Redis authentication (24 chars)
├── grafana_user.txt         # Grafana admin username
├── grafana_password.txt     # Grafana admin password (24 chars)
├── smtp_password.txt        # Email service password (24 chars)
├── age-key.txt              # Backup encryption private key
└── age-recipients.txt       # Backup encryption public key
```

### Secret Rotation Process

```bash
# 1. Generate new secrets (keeps existing if present)
./scripts/generate-secrets.sh

# 2. Update specific secrets manually (optional)
echo "new_strong_password_here" > secrets/n8n_password.txt
chmod 600 secrets/n8n_password.txt

# 3. Validate secret strength and permissions
./scripts/validate-infrastructure.sh secrets

# 4. Apply new secrets (rolling restart)
docker-compose up -d --force-recreate

# 5. Verify services with new secrets
./scripts/health-check.sh
```

### Secret Security Best Practices

- **Permissions**: All secret files must have `600` permissions (owner read/write only)
- **Directory**: Secrets directory must have `700` permissions
- **Encryption**: Backup secrets are encrypted with age keys
- **Rotation**: Regular rotation recommended (quarterly for production)
- **Validation**: Use validation scripts to ensure proper configuration

## 🔄 Backup & Recovery

### Automated Backup System

```bash
# Manual backup (creates encrypted archive)
./scripts/backup.sh

# Automated daily backup (add to crontab)
0 2 * * * cd /path/to/n8n && ./scripts/backup.sh >/dev/null 2>&1

# Backup with custom retention (default: 7 days)
RETENTION_DAYS=30 ./scripts/backup.sh
```

### Backup Components

The backup system creates encrypted archives containing:
- **PostgreSQL database**: Full database dump with schema
- **N8N data**: Workflows, credentials, and settings  
- **Redis data**: Cache and queue state
- **Configuration files**: Docker Compose, nginx, monitoring configs
- **Secrets**: Encrypted secret files (with separate key)

### Backup Location and Structure

```
backups/
├── 20240101_120000/           # Timestamp-based directories
│   ├── postgresql.sql.age     # Encrypted database dump
│   ├── n8n_data.tar.age      # Encrypted N8N data
│   ├── redis_data.tar.age    # Encrypted Redis data
│   ├── config.tar.age        # Encrypted configuration
│   ├── backup_metadata.json  # Backup information
│   └── checksums.sha256      # File integrity checksums
└── latest -> 20240101_120000/ # Symlink to latest backup
```

### Recovery Process

```bash
# 1. Stop all services
docker-compose down

# 2. Navigate to backup directory
cd backups/latest  # or specific timestamp directory

# 3. Decrypt and restore database
age -d -i ../../secrets/age-key.txt postgresql.sql.age | \
  docker-compose exec -T postgres psql -U postgres -d n8n

# 4. Decrypt and restore N8N data
age -d -i ../../secrets/age-key.txt n8n_data.tar.age | \
  tar -xf - -C ../../volumes/n8n/

# 5. Decrypt and restore Redis data (optional)
age -d -i ../../secrets/age-key.txt redis_data.tar.age | \
  tar -xf - -C ../../volumes/redis/

# 6. Restart services and verify
docker-compose up -d
./scripts/health-check.sh
```

### Backup Verification and Testing

```bash
# Verify backup integrity
./scripts/backup.sh --verify

# Test restore process (dry run)
./scripts/backup.sh --test-restore

# List available backups
ls -la backups/

# Check backup metadata
cat backups/latest/backup_metadata.json | jq .
```

## 🔧 Troubleshooting

**Service issues:**
```bash
./scripts/health-check.sh              # Check all services
docker-compose logs servicename        # View specific logs
```

**Permission issues:**
```bash
sudo chown -R 70:70 volumes/postgres    # PostgreSQL
sudo chown -R 1000:1000 volumes/n8n     # N8N
chmod 600 secrets/*.txt                 # Secrets
```

**Network connectivity:**
```bash
./scripts/validate-deployment.sh        # Validate security
docker network inspect n8n-backend      # Check networks
```

---

**⚠️ Security Notice**: Regular monitoring with `./scripts/health-check.sh` and updates via `./scripts/update.sh` are essential for security.