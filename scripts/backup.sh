#!/bin/bash
# ==============================================================================
# N8N UNIFIED BACKUP SCRIPT
# ==============================================================================
# Consolidated backup solution with encryption support
# Replaces both backup.sh and secure-backup.sh with unified functionality

set -euo pipefail

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ==============================================================================
# CONFIGURATION AND DEFAULTS
# ==============================================================================

# Backup configuration
BACKUP_ROOT="${PROJECT_ROOT}/volumes/backups"
TIMESTAMP=$(get_timestamp)
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
LOG_FILE="${BACKUP_ROOT}/backup.log"

# Encryption configuration
ENCRYPTION_MODE="${BACKUP_ENCRYPTION_MODE:-auto}"  # auto, age, gzip, none
ENCRYPTION_REQUIRED="${BACKUP_ENCRYPTION_REQUIRED:-false}"
AGE_RECIPIENTS_FILE="${SECRETS_DIR}/age-recipients.txt"

# Security configuration for sidecar containers
USE_SIDECAR_CONTAINERS="${BACKUP_USE_SIDECAR:-false}"

# Remote storage configuration
BACKUP_REMOTE_DESTINATION="${BACKUP_REMOTE_DESTINATION:-}"
BACKUP_REMOTE_TYPE="${BACKUP_REMOTE_TYPE:-}"

# Load environment variables
if [ -f "${PROJECT_ROOT}/.env" ]; then
    source "${PROJECT_ROOT}/.env"
fi

# Initialize common environment
init_common

# ==============================================================================
# BACKUP-SPECIFIC FUNCTIONS
# ==============================================================================

# Validate encryption configuration
validate_encryption_config() {
    case "$ENCRYPTION_MODE" in
        "age")
            if ! is_age_available; then
                if [ "$ENCRYPTION_REQUIRED" = "true" ]; then
                    error_exit "Age encryption required but not available. Install 'age' or set BACKUP_ENCRYPTION_REQUIRED=false"
                else
                    warn "Age encryption not available, falling back to gzip compression"
                    ENCRYPTION_MODE="gzip"
                fi
            elif [ ! -f "$AGE_RECIPIENTS_FILE" ]; then
                if [ "$ENCRYPTION_REQUIRED" = "true" ]; then
                    error_exit "Age recipients file not found: $AGE_RECIPIENTS_FILE"
                else
                    warn "Age recipients file not found, falling back to gzip compression"
                    ENCRYPTION_MODE="gzip"
                fi
            fi
            ;;
        "auto")
            if is_age_available && [ -f "$AGE_RECIPIENTS_FILE" ]; then
                ENCRYPTION_MODE="age"
                log_info "Auto-detected age encryption availability"
            else
                ENCRYPTION_MODE="gzip"
                log_info "Age encryption not available, using gzip compression"
            fi
            ;;
        "gzip"|"none")
            # Valid modes, no validation needed
            ;;
        *)
            error_exit "Invalid encryption mode: $ENCRYPTION_MODE. Valid options: auto, age, gzip, none"
            ;;
    esac
    
    log_info "Backup encryption mode: $ENCRYPTION_MODE"
}

# Enhanced encryption/compression function with multiple modes
process_backup_file() {
    local source_file="$1"
    local base_name="$(basename "$source_file")"
    
    if [ ! -f "$source_file" ]; then
        warn "Source file not found: $source_file"
        return 1
    fi
    
    if [ ! -s "$source_file" ]; then
        warn "Source file is empty: $source_file"
        return 1
    fi
    
    case "$ENCRYPTION_MODE" in
        "age")
            log_info "Encrypting: $base_name"
            if age -R "$AGE_RECIPIENTS_FILE" -o "${source_file}.age" "$source_file"; then
                rm "$source_file"
                log_success "Encrypted: $base_name"
                echo "${source_file}.age"
            else
                error_exit "Failed to encrypt: $base_name"
            fi
            ;;
        "gzip")
            log_info "Compressing: $base_name"
            if gzip "$source_file"; then
                log_success "Compressed: $base_name"
                echo "${source_file}.gz"
            else
                error_exit "Failed to compress: $base_name"
            fi
            ;;
        "none")
            log_info "Stored uncompressed: $base_name"
            echo "$source_file"
            ;;
        *)
            error_exit "Unknown encryption mode: $ENCRYPTION_MODE"
            ;;
    esac
}

# PostgreSQL backup with optional sidecar container
backup_postgresql() {
    log_info "Starting PostgreSQL backup..."
    
    # Verify PostgreSQL service is available
    if ! is_service_running "postgres"; then
        error_exit "PostgreSQL service is not running"
    fi
    
    if ! is_service_healthy "postgres"; then
        warn "PostgreSQL service is not healthy, proceeding with caution..."
    fi
    
    # Read credentials safely
    local postgres_user
    postgres_user=$(read_secret "postgres_user")
    local postgres_db="${POSTGRES_DB:-n8n}"
    local backup_file="${BACKUP_DIR}/postgres_backup.dump"
    
    if [ "$USE_SIDECAR_CONTAINERS" = "true" ]; then
        # Use dedicated backup container for enhanced security
        log_info "Using sidecar container for PostgreSQL backup..."
        
        if docker run --rm \
            --name "n8n-backup-postgres-$(get_timestamp)" \
            --network "$(docker-compose config | grep 'name:' | grep backend | awk '{print $2}')" \
            --user 70:70 \
            --read-only \
            --security-opt no-new-privileges:true \
            --cap-drop ALL \
            --tmpfs /tmp:noexec,nosuid,size=100m \
            -v "${BACKUP_DIR}:/backup" \
            -v "${SECRETS_DIR}:/secrets:ro" \
            postgres:16-alpine \
            sh -c "pg_dump \
                -h postgres \
                -U \"$postgres_user\" \
                -d \"$postgres_db\" \
                --no-owner \
                --no-privileges \
                --format=custom \
                --verbose \
                --file=/backup/postgres_backup.dump"; then
            
            log_success "PostgreSQL sidecar backup completed"
        else
            error_exit "PostgreSQL sidecar backup failed"
        fi
    else
        # Use standard container exec approach
        if docker_exec_safe postgres pg_dump \
            -U "$postgres_user" \
            -d "$postgres_db" \
            --no-owner \
            --no-privileges \
            --format=custom \
            --verbose \
            --file=/tmp/postgres_backup.dump; then
            
            # Copy from container
            local postgres_container
            postgres_container=$(get_container_id_safe "postgres")
            if docker cp "${postgres_container}:/tmp/postgres_backup.dump" "$backup_file"; then
                # Clean up temp file in container
                docker_exec_safe postgres rm -f /tmp/postgres_backup.dump
                log_success "PostgreSQL backup completed"
            else
                error_exit "Failed to copy PostgreSQL backup from container"
            fi
        else
            error_exit "PostgreSQL backup failed during pg_dump execution"
        fi
    fi
    
    # Verify backup file and process it
    if [ -s "$backup_file" ]; then
        process_backup_file "$backup_file"
    else
        error_exit "PostgreSQL backup file is empty or missing"
    fi
}

# Redis backup with optional sidecar container
backup_redis() {
    if [ "${ENABLE_REDIS_CACHE:-true}" != "true" ]; then
        log_info "Redis caching disabled, skipping Redis backup"
        return 0
    fi
    
    log_info "Starting Redis backup..."
    
    if ! is_service_running "redis"; then
        warn "Redis service is not running, skipping Redis backup"
        return 0
    fi
    
    local redis_password
    redis_password=$(read_secret "redis_password")
    local backup_file="${BACKUP_DIR}/redis_backup.rdb"
    
    if [ "$USE_SIDECAR_CONTAINERS" = "true" ]; then
        # Use dedicated backup container
        log_info "Using sidecar container for Redis backup..."
        
        if docker run --rm \
            --name "n8n-backup-redis-$(get_timestamp)" \
            --network "$(docker-compose config | grep 'name:' | grep backend | awk '{print $2}')" \
            --user 999:999 \
            --read-only \
            --security-opt no-new-privileges:true \
            --cap-drop ALL \
            --tmpfs /tmp:noexec,nosuid,size=100m \
            -v "${BACKUP_DIR}:/backup" \
            -v "${SECRETS_DIR}:/secrets:ro" \
            redis:7-alpine \
            sh -c "redis-cli -h redis --pass \"$redis_password\" BGSAVE && \
                   sleep 5 && \
                   redis-cli -h redis --pass \"$redis_password\" --rdb /backup/redis_backup.rdb"; then
            
            log_success "Redis sidecar backup completed"
        else
            warn "Redis sidecar backup failed (non-critical)"
            return 0
        fi
    else
        # Use standard container exec approach
        if docker_exec_safe redis redis-cli --pass "$redis_password" BGSAVE; then
            log_info "Waiting for Redis BGSAVE to complete..."
            sleep 5
            
            # Verify BGSAVE completion with timeout
            local retries=12  # 1 minute timeout
            while [ $retries -gt 0 ]; do
                if docker_exec_safe redis redis-cli --pass "$redis_password" LASTSAVE >/dev/null 2>&1; then
                    break
                fi
                sleep 5
                retries=$((retries - 1))
            done
            
            # Copy Redis dump
            local redis_container
            redis_container=$(get_container_id_safe "redis")
            if docker cp "${redis_container}:/data/dump.rdb" "$backup_file"; then
                log_success "Redis backup completed"
            else
                warn "Failed to copy Redis backup (non-critical)"
                return 0
            fi
        else
            warn "Failed to trigger Redis BGSAVE (non-critical)"
            return 0
        fi
    fi
    
    # Process backup file if it exists and has content
    if [ -f "$backup_file" ] && [ -s "$backup_file" ]; then
        process_backup_file "$backup_file"
    else
        warn "Redis backup file is empty or missing (non-critical)"
    fi
}

# N8N data backup
backup_n8n_data() {
    log_info "Starting N8N data backup..."
    
    local n8n_data_dir="${PROJECT_ROOT}/volumes/n8n"
    local backup_file="${BACKUP_DIR}/n8n_data.tar"
    
    if [ ! -d "$n8n_data_dir" ]; then
        warn "N8N data directory not found: $n8n_data_dir"
        return 0
    fi
    
    # Create tar archive (uncompressed first, then process)
    if tar -cf "$backup_file" -C "${PROJECT_ROOT}/volumes" n8n; then
        if [ -s "$backup_file" ]; then
            log_success "N8N data archived successfully"
            # Process the file (compress/encrypt)
            process_backup_file "$backup_file"
        else
            error_exit "N8N data backup file is empty"
        fi
    else
        error_exit "Failed to create N8N data backup"
    fi
}

# Configuration files backup
backup_configuration() {
    log_info "Starting configuration backup..."
    
    # Create list of configuration files/directories to backup
    local config_items=()
    
    # Core compose files
    [ -f "compose.yml" ] && config_items+=("compose.yml")
    [ -f "compose.prod.yml" ] && config_items+=("compose.prod.yml")
    [ -f ".env" ] && config_items+=(".env")
    
    # Nginx configuration
    [ -d "nginx" ] && config_items+=("nginx")
    
    # Monitoring configuration
    [ -d "monitoring" ] && config_items+=("monitoring")
    
    # Security configuration (excluding secrets)
    [ -d "security" ] && config_items+=("security")
    
    # Scripts (excluding logs)
    [ -d "scripts" ] && config_items+=("scripts")
    
    if [ ${#config_items[@]} -eq 0 ]; then
        warn "No configuration files found to backup"
        return 0
    fi
    
    local backup_file="${BACKUP_DIR}/config_backup.tar"
    
    # Create configuration backup
    if tar -cf "$backup_file" \
        -C "${PROJECT_ROOT}" \
        --exclude='secrets/*' \
        --exclude='volumes/*' \
        --exclude='.git/*' \
        --exclude='*.log' \
        --exclude='scripts/lib/common.sh.backup.*' \
        "${config_items[@]}"; then
        
        if [ -s "$backup_file" ]; then
            log_success "Configuration backup created successfully"
            process_backup_file "$backup_file"
        else
            error_exit "Configuration backup file is empty"
        fi
    else
        error_exit "Failed to create configuration backup"
    fi
}

# Create comprehensive backup metadata
create_backup_metadata() {
    log_info "Creating backup metadata..."
    
    # Get version information safely
    local n8n_version="unknown"
    local postgres_version="unknown"
    
    if is_service_running "n8n"; then
        n8n_version=$(docker_exec_safe n8n n8n --version 2>/dev/null | tr -d '\r' || echo 'unknown')
    fi
    
    if is_service_running "postgres"; then
        postgres_version=$(docker_exec_safe postgres postgres --version 2>/dev/null | cut -d' ' -f3 | tr -d '\r' || echo 'unknown')
    fi
    
    # Get list of actual backup files created
    local backup_files=()
    for file in "${BACKUP_DIR}"/*; do
        if [ -f "$file" ] && [[ "$(basename "$file")" != "backup_metadata.json" ]]; then
            backup_files+=("$(basename "$file")")
        fi
    done
    
    # Create comprehensive metadata
    cat > "${BACKUP_DIR}/backup_metadata.json" << EOF
{
  "timestamp": "${TIMESTAMP}",
  "date": "$(get_readable_date)",
  "script_version": "${COMMON_LIB_VERSION}",
  "backup_type": "unified",
  "encryption": {
    "mode": "${ENCRYPTION_MODE}",
    "required": ${ENCRYPTION_REQUIRED},
    "age_available": $(is_age_available && echo "true" || echo "false")
  },
  "configuration": {
    "sidecar_containers": ${USE_SIDECAR_CONTAINERS},
    "retention_days": ${RETENTION_DAYS}
  },
  "versions": {
    "n8n": "${n8n_version}",
    "postgres": "${postgres_version}"
  },
  "files": [$(printf '"%s",' "${backup_files[@]}" | sed 's/,$//')],
  "size": "$(du -sh "${BACKUP_DIR}" | cut -f1)",
  "file_count": ${#backup_files[@]},
  "services_backed_up": {
    "postgres": $([ -f "${BACKUP_DIR}"/postgres_backup.* ] && echo "true" || echo "false"),
    "redis": $([ -f "${BACKUP_DIR}"/redis_backup.* ] && echo "true" || echo "false"),
    "n8n_data": $([ -f "${BACKUP_DIR}"/n8n_data.* ] && echo "true" || echo "false"),
    "configuration": $([ -f "${BACKUP_DIR}"/config_backup.* ] && echo "true" || echo "false")
  }
}
EOF
    
    log_success "Backup metadata created"
}

# Create checksums for integrity verification
create_checksums() {
    log_info "Creating integrity checksums..."
    
    local files_to_check=()
    for file in "${BACKUP_DIR}"/*; do
        if [ -f "$file" ]; then
            files_to_check+=("$(basename "$file")")
        fi
    done
    
    if [ ${#files_to_check[@]} -gt 0 ]; then
        cd "${BACKUP_DIR}"
        sha256sum "${files_to_check[@]}" > checksums.sha256
        cd - > /dev/null
        log_success "Checksums created for ${#files_to_check[@]} files"
    else
        warn "No files found for checksum generation"
    fi
}

# Remote storage upload
upload_to_remote_storage() {
    if [ -z "$BACKUP_REMOTE_DESTINATION" ]; then
        return 0
    fi
    
    log_info "Uploading to remote storage: $BACKUP_REMOTE_DESTINATION"
    
    case "$BACKUP_REMOTE_TYPE" in
        "azure")
            if command -v az >/dev/null 2>&1; then
                if az storage blob upload-batch \
                    --destination "${BACKUP_REMOTE_CONTAINER}" \
                    --source "${BACKUP_DIR}" \
                    --pattern "*" \
                    --account-name "${BACKUP_STORAGE_ACCOUNT}"; then
                    log_success "Azure Blob Storage upload completed"
                else
                    warn "Azure Blob Storage upload failed"
                fi
            else
                warn "Azure CLI not available for remote upload"
            fi
            ;;
        "aws")
            if command -v aws >/dev/null 2>&1; then
                if aws s3 sync "${BACKUP_DIR}" "s3://${BACKUP_S3_BUCKET}/n8n-backups/${TIMESTAMP}/"; then
                    log_success "AWS S3 upload completed"
                else
                    warn "AWS S3 upload failed"
                fi
            else
                warn "AWS CLI not available for remote upload"
            fi
            ;;
        "gcp")
            if command -v gsutil >/dev/null 2>&1; then
                if gsutil -m cp -r "${BACKUP_DIR}" "gs://${BACKUP_GCS_BUCKET}/n8n-backups/${TIMESTAMP}/"; then
                    log_success "Google Cloud Storage upload completed"
                else
                    warn "Google Cloud Storage upload failed"
                fi
            else
                warn "Google Cloud SDK not available for remote upload"
            fi
            ;;
        *)
            warn "Unknown remote storage type: $BACKUP_REMOTE_TYPE"
            ;;
    esac
}

# Send notification webhook
send_notification() {
    if [ -z "${BACKUP_NOTIFICATION_WEBHOOK:-}" ]; then
        return 0
    fi
    
    log_info "Sending backup notification..."
    
    if ! command -v curl >/dev/null 2>&1; then
        warn "curl not available for notification"
        return 0
    fi
    
    local backup_size
    backup_size=$(du -sh "${BACKUP_DIR}" | cut -f1)
    
    local backup_files_count
    backup_files_count=$(find "${BACKUP_DIR}" -type f ! -name "backup_metadata.json" ! -name "checksums.sha256" | wc -l)
    
    if curl -X POST "${BACKUP_NOTIFICATION_WEBHOOK}" \
        -H "Content-Type: application/json" \
        -H "User-Agent: N8N-Unified-Backup/${COMMON_LIB_VERSION}" \
        --max-time 30 \
        --retry 3 \
        --silent \
        -d "{
            \"text\": \"N8N Unified Backup Completed\",
            \"timestamp\": \"${TIMESTAMP}\",
            \"backup_mode\": \"${ENCRYPTION_MODE}\",
            \"size\": \"${backup_size}\",
            \"files\": ${backup_files_count},
            \"location\": \"${BACKUP_DIR}\",
            \"sidecar_mode\": ${USE_SIDECAR_CONTAINERS},
            \"status\": \"success\"
        }"; then
        log_success "Notification sent successfully"
    else
        warn "Failed to send notification webhook"
    fi
}

# ==============================================================================
# MAIN BACKUP EXECUTION
# ==============================================================================

main() {
    # Print header
    print_script_header "N8N Unified Backup" "Consolidated backup with encryption and security features"
    
    # Validate prerequisites
    validate_secrets
    validate_encryption_config
    check_disk_space "$BACKUP_ROOT" 3  # Require at least 3GB free space
    
    # Create backup directories
    create_dir_safe "${BACKUP_ROOT}"
    create_dir_safe "${BACKUP_DIR}"
    
    log_info "Starting unified backup process..."
    log_info "Backup mode: $ENCRYPTION_MODE"
    log_info "Sidecar containers: $USE_SIDECAR_CONTAINERS"
    
    # Perform individual backup operations
    backup_postgresql
    backup_redis
    backup_n8n_data
    backup_configuration
    
    # Create metadata and checksums
    create_backup_metadata
    create_checksums
    
    # Clean up old backups
    log_info "Cleaning up old backups (retention: ${RETENTION_DAYS} days)..."
    cleanup_old_files "${BACKUP_ROOT}" "[0-9]*_[0-9]*" "${RETENTION_DAYS}"
    
    # Optional remote upload and notification
    upload_to_remote_storage
    send_notification
    
    # Final status report
    local backup_size
    backup_size=$(du -sh "${BACKUP_DIR}" | cut -f1)
    
    local backup_files_count
    backup_files_count=$(find "${BACKUP_DIR}" -type f ! -name "backup_metadata.json" ! -name "checksums.sha256" | wc -l)
    
    log_success "Unified backup completed successfully!"
    log_info "Backup Summary:"
    log_info "  Location: ${BACKUP_DIR}"
    log_info "  Size: ${backup_size}"
    log_info "  Files: ${backup_files_count}"
    log_info "  Encryption: ${ENCRYPTION_MODE}"
    log_info "  Sidecar Mode: ${USE_SIDECAR_CONTAINERS}"
    
    print_script_footer "N8N Unified Backup"
}

# Execute main function
main "$@"