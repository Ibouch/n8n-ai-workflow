#!/bin/bash
# Enhanced Secrets Generation Script with Age Encryption Support
# Generates cryptographically secure secrets and optionally encrypts them

set -euo pipefail

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Initialize common environment (skip secrets directory validation)
init_common true

# Function to generate secure random string
generate_secure_string() {
    local length="${1:-32}"
    openssl rand -base64 "${length}" | tr -d "=+/" | cut -c1-"${length}"
}

# Function to generate secure password
generate_password() {
    local length="${1:-20}"
    openssl rand -base64 "${length}" | tr -d "=+/" | cut -c1-"${length}"
}

# Print header
print_script_header "N8N Secrets Generation" "Cryptographically secure secret generation with optional encryption"

# Create secrets directory if it doesn't exist
create_dir_safe "${SECRETS_DIR}" 700

log_info "Generating secure secrets..."

# Check if force regeneration is requested
FORCE_REGENERATE=false
if [ "${1:-}" = "--force" ]; then
    FORCE_REGENERATE=true
    log_info "Force regeneration mode enabled"
fi

# PostgreSQL secrets
if [ ! -f "${SECRETS_DIR}/postgres_password.txt" ] || [ "$FORCE_REGENERATE" = true ]; then
    printf '%s' "$(generate_password 32)" > "${SECRETS_DIR}/postgres_password.txt"
    log_success "Generated PostgreSQL password"
fi

# N8N authentication secrets

if [ ! -f "${SECRETS_DIR}/n8n_password.txt" ] || [ "$FORCE_REGENERATE" = true ]; then
    printf '%s' "$(generate_password 24)" > "${SECRETS_DIR}/n8n_password.txt"
    log_success "Generated N8N password"
fi

if [ ! -f "${SECRETS_DIR}/n8n_encryption_key.txt" ] || [ "$FORCE_REGENERATE" = true ]; then
    printf '%s' "$(generate_secure_string 32)" > "${SECRETS_DIR}/n8n_encryption_key.txt"
    log_success "Generated N8N encryption key"
fi

# Redis secrets
if [ ! -f "${SECRETS_DIR}/redis_password.txt" ] || [ "$FORCE_REGENERATE" = true ]; then
    printf '%s' "$(generate_password 32)" > "${SECRETS_DIR}/redis_password.txt"
    log_success "Generated Redis password"
fi

# Grafana authentication secrets
if [ ! -f "${SECRETS_DIR}/grafana_password.txt" ] || [ "$FORCE_REGENERATE" = true ]; then
    printf '%s' "$(generate_password 24)" > "${SECRETS_DIR}/grafana_password.txt"
    log_success "Generated Grafana password"
fi

# SMTP password
if [ ! -f "${SECRETS_DIR}/smtp_password.txt" ] || [ "$FORCE_REGENERATE" = true ]; then
    printf '%s' "$(generate_password 24)" > "${SECRETS_DIR}/smtp_password.txt"
    log_success "Generated SMTP password"
fi

# Generate age key pair for backup encryption if age is available
if is_age_available; then
    if [ ! -f "${SECRETS_DIR}/age-key.txt" ] || [ "$FORCE_REGENERATE" = true ]; then
        age-keygen -o "${SECRETS_DIR}/age-key.txt"
        log_success "Generated age encryption key"
    fi
    
    if [ ! -f "${SECRETS_DIR}/age-recipients.txt" ] || [ "$FORCE_REGENERATE" = true ]; then
        printf '%s' "$(age-keygen -y "${SECRETS_DIR}/age-key.txt")" > "${SECRETS_DIR}/age-recipients.txt"
        log_success "Generated age recipients file"
    fi
else
    warn "age encryption tool not found. Install 'age' for backup encryption support."
fi

# Create SSL directory and generate dhparam.pem for nginx
SSL_DIR="${PROJECT_ROOT}/nginx/ssl"
create_dir_safe "${SSL_DIR}" 755

if [ ! -f "${SSL_DIR}/dhparam.pem" ] || [ "$FORCE_REGENERATE" = true ]; then
    log_info "Generating secure Diffie-Hellman parameters (this may take a few minutes)..."
    
    # Generate 2048-bit DH parameters (secure and reasonable generation time)
    if openssl dhparam -out "${SSL_DIR}/dhparam.pem" 2048 2>/dev/null; then
        chmod 644 "${SSL_DIR}/dhparam.pem"
        log_success "Generated Diffie-Hellman parameters (dhparam.pem)"
    else
        warn "Failed to generate Diffie-Hellman parameters. OpenSSL may not be available."
    fi
else
    log_info "Diffie-Hellman parameters already exist"
fi

# Set proper permissions (portable across GNU/BSD)
find "${SECRETS_DIR}" -type f -name "*.txt" -exec chmod 600 {} +
chmod 700 "${SECRETS_DIR}"

log_success "Secrets generation completed!"
log_info "Secrets location: ${SECRETS_DIR}"
log_info "SSL directory: ${SSL_DIR}"

# Display summary
echo ""
echo "Generated secrets:"
for file in "${SECRETS_DIR}"/*.txt; do
    if [ -f "$file" ]; then
        filename=$(basename "$file")
        echo "  ${CHECKMARK} $filename"
    fi
done

echo ""
echo "SSL setup:"
if [ -f "${SSL_DIR}/dhparam.pem" ]; then
    echo "  ${CHECKMARK} dhparam.pem (Diffie-Hellman parameters)"
else
    echo "  ${CROSS} dhparam.pem (generation failed)"
fi

# Check for actual SSL certificates
if [ -f "${SSL_DIR}/fullchain.pem" ] && [ -f "${SSL_DIR}/key.pem" ]; then
    echo "  ${CHECKMARK} SSL certificates present"
else
    echo "  ${WARNING} SSL certificates not found"
fi

echo ""
echo -e "${YELLOW}IMPORTANT SECURITY NOTES:${NC}"
echo "1. Keep these secrets secure and never commit them to version control"
echo "2. Use encrypted storage for backups containing these secrets"
echo "3. Rotate secrets regularly (recommended: every 90 days)"
echo "4. Use different secrets for different environments"
echo "5. Generate SSL certificates before starting services"
echo "6. Monitor SSL certificate expiration and renew before expiry"
if is_age_available; then
    echo "7. Store the age private key (age-key.txt) in a secure location separate from backups"
fi

print_script_footer "N8N Secrets Generation"