# 🚀 N8N Production Infrastructure

[![Docker](https://img.shields.io/badge/Docker-20.10+-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![Security](https://img.shields.io/badge/Security-Hardened-green?logo=shield&logoColor=white)](https://github.com/user/repo/actions)
[![Monitoring](https://img.shields.io/badge/Monitoring-Prometheus%20%7C%20Grafana-orange?logo=prometheus&logoColor=white)](https://prometheus.io/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.0.0-brightgreen)](https://github.com/user/repo/releases)

> Production-ready N8N workflow automation with enterprise security, monitoring, and unified management.

## 🚀 Quick Start

### Prerequisites
- Docker Engine 20.10+ & Docker Compose 2.0+
- Linux host (required for security features)

### Complete Setup Process

```bash
# 1. Clone and navigate to project
git clone <repository-url> && cd n8n

# 2. Install system dependencies
./scripts/install-dependencies.sh

# 3. Generate secrets and SSL directory structure
./scripts/generate-secrets.sh

# 4. Configure environment variables
cp env.example .env
# Edit .env with your domain, SMTP settings, etc.

# 5. Setup SSL certificates with Let's Encrypt
sudo certbot certonly --standalone -d yourdomain.com
sudo cp /etc/letsencrypt/live/yourdomain.com/fullchain.pem nginx/ssl/
sudo cp /etc/letsencrypt/live/yourdomain.com/privkey.pem nginx/ssl/key.pem
sudo chown $USER:$USER nginx/ssl/*.pem

# 6. Validate infrastructure before deployment
./scripts/validate-infrastructure.sh

# 7. Deploy services with monitoring stack
docker compose -f compose.yml -f compose.prod.yml up -d

# Wait for services to initialize (2-3 minutes)

# 8. Verify deployment health and configuration
./scripts/health-check.sh

# 9. Setup security hardening
sudo ./scripts/setup-security.sh

# 10. Final health verification
./scripts/health-check.sh
```

**Access**: https://your-domain.com (credentials in `secrets/n8n_*`)

### Important Setup Notes

**🔐 SSL Certificates**
- **Required for production**: HTTPS access needs valid SSL certificates
- **Auto-generated dhparam.pem**: The secrets script creates secure DH parameters
- **Certificate placement**: Must be in `nginx/ssl/` before starting services

**📁 Directory Structure**
- **Auto-creation**: Scripts create required directories automatically
- **Permission handling**: Graceful fallback to user home/temp for logs
- **No sudo needed**: Most scripts run as regular user (except security hardening)

**⚠️ Common Issues**
```bash
# Fix project ownership if needed
sudo chown -R $USER:$USER /path/to/project

# Ensure correct SSL certificate permissions
chmod 600 nginx/ssl/key.pem
chmod 644 nginx/ssl/fullchain.pem nginx/ssl/dhparam.pem

# If services fail to start, check logs
docker compose logs <service-name>
```

## ⚙️ Configuration

### Environment Variables (.env)

```bash
# Domain & Protocol
N8N_HOST=your-domain.com
N8N_PROTOCOL=https
WEBHOOK_URL=https://your-domain.com/

# SMTP Configuration
SMTP_HOST=smtp-mail.your-domain.com
SMTP_PORT=587
SMTP_USERNAME=your-email@your-domain.com
ALERT_EMAIL_TO=admin@your-domain.com

# Service Credentials (usernames only - passwords in secrets/)
POSTGRES_USER=n8n_admin
N8N_ADMIN_USER=admin
GRAFANA_ADMIN_USER=admin
```

### SSL Certificates

```bash
# SSL directory structure (created by generate-secrets.sh)
nginx/ssl/
├── fullchain.pem     # Certificate chain (from Let's Encrypt)
├── key.pem           # Private key (from Let's Encrypt)
├── dhparam.pem       # Auto-generated secure DH parameters
└── README.md         # Auto-generated setup instructions
```

**Certificate Setup with Let's Encrypt:**
```bash
# Initial certificate generation
sudo certbot certonly --standalone -d yourdomain.com

# Copy to project directory
sudo cp /etc/letsencrypt/live/yourdomain.com/fullchain.pem nginx/ssl/
sudo cp /etc/letsencrypt/live/yourdomain.com/privkey.pem nginx/ssl/key.pem
sudo chown $USER:$USER nginx/ssl/*.pem

# Setup auto-renewal (crontab)
0 3 * * * certbot renew --quiet --post-hook "docker compose restart nginx"
```

## 🔒 Security

### Architecture

| **Layer** | **Implementation** |
|-----------|-------------------|
| **Container Hardening** | Non-root execution, read-only filesystems, seccomp profiles |
| **AppArmor Profiles** | Custom mandatory access control for all services |
| **Network Segmentation** | DMZ (172.20.0.0/24) ↔ Internal (172.21.0.0/24) isolation |
| **Secrets Management** | Docker secrets, age encryption, secure generation |
| **Access Control** | Zero external backend access, minimal capabilities |
| **Monitoring** | Security events, audit logs, comprehensive health checks |

### AppArmor Security Profiles

```bash
# Load AppArmor profiles (requires root)
sudo ./scripts/load-apparmor-profiles.sh

# Verify profiles are loaded and active
sudo aa-status | grep n8n

# Monitor AppArmor denials (security violations)
journalctl -f | grep apparmor
```

**Profile Coverage**:
- **n8n_postgres_profile**: Database security constraints
- **n8n_app_profile**: N8N application restrictions  
- **n8n_nginx_profile**: Web server access controls
- **n8n_redis_profile**: Cache service limitations

## 📊 Monitoring & Observability

### Monitoring Stack Components

- **Grafana**: http://localhost:3000 - Dashboards and alerting
- **Prometheus**: http://localhost:9090 - Metrics collection  
- **Alertmanager**: http://localhost:9093 - Alert routing
- **Loki**: Log aggregation and analysis
- **Promtail**: Log collection agent

### Initial Monitoring Setup

```bash
# 1. Deploy with monitoring stack
docker compose -f compose.yml -f compose.prod.yml up -d

# 2. Verify monitoring services
docker compose ps | grep -E "(prometheus|grafana|loki|alertmanager)"

# 3. Access Grafana (credentials in secrets/grafana_*)
open http://localhost:3000

# 4. Import production dashboards
# - Container metrics dashboard ID: 893
# - PostgreSQL dashboard ID: 9628
# - Redis dashboard ID: 763
```

### Custom Alerts Configuration

```bash
# Edit alert rules
vim monitoring/prometheus/alerts.yml
vim monitoring/alertmanager/alertmanager.yml

# Reload configuration without restart
docker compose exec prometheus kill -HUP 1
docker compose exec alertmanager kill -HUP 1
```

**Alert Rules**:
- Service health checks (1-minute intervals)
- Resource utilization warnings (>80% threshold)
- Security events (failed logins, unusual traffic)
- Application performance (response times, errors)

## 🛠️ Management Commands

| **Operation** | **Command** | **Purpose** |
|---------------|-------------|-------------|
| **Health Check** | `./scripts/health-check.sh` | Comprehensive service monitoring |
| **Backup** | `./scripts/backup.sh` | Encrypted backups with verification |
| **Update** | `./scripts/update.sh` | Safe updates with rollback |
| **Validate** | `./scripts/validate-infrastructure.sh` | System validation |
| **Generate Secrets** | `./scripts/generate-secrets.sh` | Create secrets & SSL directory |
| **Security Setup** | `sudo ./scripts/setup-security.sh` | Complete security hardening |
| **Docker Security** | `sudo ./scripts/setup-security.sh --docker-daemon` | Docker daemon security only |
| **AppArmor** | `sudo ./scripts/load-apparmor-profiles.sh` | Load security profiles |

## 🔐 Secrets Management

### Secret Generation

```bash
# Generate all required secrets and SSL directory
./scripts/generate-secrets.sh

# Force regenerate all secrets (security rotation)
./scripts/generate-secrets.sh --force

# Validate secrets configuration
./scripts/validate-infrastructure.sh secrets
```

### Generated Structure

```
secrets/                     # Auto-created with 700 permissions
├── postgres_password.txt    # Database password (32 chars)
├── n8n_password.txt         # N8N admin password (24 chars)
├── n8n_encryption_key.txt   # N8N data encryption key (32 chars)
├── redis_password.txt       # Redis authentication (32 chars)
├── grafana_password.txt     # Grafana admin password (24 chars)
├── smtp_password.txt        # Email service password (24 chars)
├── age-key.txt              # Backup encryption private key
└── age-recipients.txt       # Backup encryption public key
```

### Secret Rotation Process

```bash
# 1. Generate new secrets
./scripts/generate-secrets.sh

# 2. Validate secret strength and permissions
./scripts/validate-infrastructure.sh secrets

# 3. Apply new secrets (rolling restart)
docker compose up -d --force-recreate

# 4. Verify services with new secrets
./scripts/health-check.sh
```

**Security Best Practices**:
- All secret files must have `600` permissions
- Secrets directory must have `700` permissions
- Regular rotation recommended (quarterly for production)

## 🔄 Backup & Recovery

### Automated Backup System

```bash
# Manual backup
./scripts/backup.sh

# Automated daily backup (add to crontab)
0 2 * * * cd /path/to/n8n && ./scripts/backup.sh >/dev/null 2>&1

# Backup with custom retention (default: 7 days)
RETENTION_DAYS=30 ./scripts/backup.sh
```

### Backup Components

- **PostgreSQL database**: Full database dump with schema
- **N8N data**: Workflows, credentials, and settings  
- **Redis data**: Cache and queue state
- **Configuration files**: Docker Compose, nginx, monitoring configs
- **Secrets**: Encrypted secret files (with separate key)

### Backup Structure

```
backups/
├── 20240101_120000/           # Timestamp-based directories
│   ├── postgresql.sql.age     # Encrypted database dump
│   ├── n8n_data.tar.age       # Encrypted N8N data
│   ├── redis_data.tar.age     # Encrypted Redis data
│   ├── config.tar.age         # Encrypted configuration
│   ├── backup_metadata.json   # Backup information
│   └── checksums.sha256       # File integrity checksums
└── latest -> 20240101_120000/ # Symlink to latest backup
```

### Recovery Process

```bash
# 1. Stop all services
docker compose down

# 2. Navigate to backup directory
cd backups/latest

# 3. Decrypt and restore database
age -d -i ../../secrets/age-key.txt postgresql.sql.age | \
  docker compose exec -T postgres psql -U postgres -d n8n

# 4. Decrypt and restore N8N data
age -d -i ../../secrets/age-key.txt n8n_data.tar.age > /tmp/n8n_data.tar
docker compose exec -T n8n sh -c "rm -rf /home/node/.n8n/*"
docker cp /tmp/n8n_data.tar $(docker compose ps -q n8n):/tmp/n8n_data.tar
docker compose exec -T n8n sh -c "tar -xf /tmp/n8n_data.tar -C /home/node && rm -f /tmp/n8n_data.tar && chown -R 1000:1000 /home/node/.n8n"

# 5. Decrypt and restore Redis data
age -d -i ../../secrets/age-key.txt redis_data.tar.age | \
  tar -xf - -C ../../volumes/redis/

# 6. Restart services and verify
docker compose up -d
./scripts/health-check.sh
```

### Backup Verification

```bash
# Verify backup integrity
./scripts/backup.sh --verify

# List available backups
ls -la backups/

# Check backup metadata
cat backups/latest/backup_metadata.json | jq .
```

## 🔧 Troubleshooting

### Service Issues

```bash
# Check all services
./scripts/health-check.sh

# View specific logs
docker compose logs <service-name>

# Validate network configuration
./scripts/validate-infrastructure.sh network
docker network inspect n8n-backend
```

### Permission Issues

```bash
# Fix project ownership
sudo chown -R $USER:$USER /path/to/project

# Fix Docker volumes
sudo chown -R 70:70 volumes/postgres    # PostgreSQL
sudo chown -R 1000:1000 volumes/n8n     # N8N
chmod 600 secrets/*.txt                 # Secrets

# Check logs in fallback locations
~/.n8n-scripts.log or /tmp/n8n-scripts-*.log
```

### SSL/HTTPS Issues

```bash
# Check SSL certificate status
./scripts/health-check.sh

# Verify SSL files and permissions
ls -la nginx/ssl/
chmod 600 nginx/ssl/key.pem
chmod 644 nginx/ssl/fullchain.pem nginx/ssl/dhparam.pem

# Test certificate
openssl x509 -in nginx/ssl/fullchain.pem -text -noout
```

---

**⚠️ Security Notice**: Regular monitoring with `./scripts/health-check.sh` and updates via `./scripts/update.sh` are essential for production security.