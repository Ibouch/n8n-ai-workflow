#!/bin/bash
# ==============================================================================
# COMMON UTILITIES LIBRARY FOR N8N INFRASTRUCTURE SCRIPTS
# ==============================================================================
# Shared functions for logging, error handling, Docker operations, and utilities
# Source this file in other scripts: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

set -euo pipefail

# ==============================================================================
# GLOBAL VARIABLES AND INITIALIZATION
# ==============================================================================

# Script paths and project structure
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
SECRETS_DIR="${PROJECT_ROOT}/secrets"

# Default log file (can be overridden by calling scripts)
LOG_FILE="${LOG_FILE:-${PROJECT_ROOT}/logs/scripts.log}"

# Ensure logs directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# ==============================================================================
# COLOR CONSTANTS AND FORMATTING
# ==============================================================================

# Colors for console output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m' # No Color

# Unicode symbols for better visual feedback
readonly CHECKMARK="✓"
readonly CROSS="✗"
readonly WARNING="⚠"
readonly INFO="ℹ"

# ==============================================================================
# LOGGING AND OUTPUT FUNCTIONS
# ==============================================================================

# Enhanced logging function with levels and file output
log() {
    local level="${1:-INFO}"
    local message="$2"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # Format log entry
    local log_entry="[${timestamp}] [${level}] ${message}"
    
    # Color mapping for different log levels
    local color=""
    case "$level" in
        "ERROR") color="$RED" ;;
        "WARN"|"WARNING") color="$YELLOW" ;;
        "SUCCESS") color="$GREEN" ;;
        "INFO") color="$BLUE" ;;
        "DEBUG") color="$PURPLE" ;;
        *) color="$NC" ;;
    esac
    
    # Output to console with color
    echo -e "${color}${CHECKMARK} ${message}${NC}"
    
    # Output to log file without color
    echo "$log_entry" >> "$LOG_FILE"
}

# Convenience logging functions
log_info() { log "INFO" "$1"; }
log_success() { log "SUCCESS" "$1"; }
log_warn() { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }
log_debug() { log "DEBUG" "$1"; }

# Warning function that doesn't exit
warn() {
    echo -e "${YELLOW}${WARNING} [WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

# Error function that exits with code
error_exit() {
    local message="$1"
    local exit_code="${2:-1}"
    echo -e "${RED}${CROSS} [ERROR]${NC} $message" >&2
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $message" >> "$LOG_FILE"
    exit "$exit_code"
}

# Info function for general information
info() {
    echo -e "${BLUE}${INFO} [INFO]${NC} $1" | tee -a "$LOG_FILE"
}

# ==============================================================================
# VALIDATION AND DEPENDENCY CHECKING
# ==============================================================================

# Check if running as root (when required)
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This operation requires root privileges. Please run with sudo."
    fi
}

# Check if NOT running as root (when not desired)
check_not_root() {
    if [ "$EUID" -eq 0 ]; then
        warn "Running as root. Consider using a regular user with docker permissions."
    fi
}

# Validate required commands are available
require_commands() {
    local commands=("$@")
    local missing_commands=()
    
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [ ${#missing_commands[@]} -gt 0 ]; then
        error_exit "Missing required commands: ${missing_commands[*]}"
    fi
}

# Check if project is properly initialized
validate_project_structure() {
    local required_paths=(
        "$PROJECT_ROOT/compose.yml"
        "$PROJECT_ROOT/secrets"
        "$PROJECT_ROOT/scripts"
    )
    
    for path in "${required_paths[@]}"; do
        if [ ! -e "$path" ]; then
            error_exit "Required project path not found: $path"
        fi
    done
    
    log_success "Project structure validation passed"
}

# ==============================================================================
# DOCKER AND COMPOSE UTILITIES
# ==============================================================================

# Change to project root directory
change_to_project_root() {
    cd "$PROJECT_ROOT" || error_exit "Failed to change to project directory: $PROJECT_ROOT"
}

# Get actual container ID for a service
get_container_id() {
    local service="$1"
    change_to_project_root
    docker-compose ps -q "$service" 2>/dev/null | head -1
}

# Get container ID with validation
get_container_id_safe() {
    local service="$1"
    local container_id
    container_id=$(get_container_id "$service")
    
    if [ -z "$container_id" ]; then
        error_exit "Container for service '$service' not found or not running"
    fi
    
    echo "$container_id"
}

# Get container name for a service
get_container_name() {
    local service="$1"
    local container_id
    container_id=$(get_container_id "$service")
    
    if [ -n "$container_id" ]; then
        docker inspect --format='{{.Name}}' "$container_id" | sed 's/^.//'
    fi
}

# Check if a service is running
is_service_running() {
    local service="$1"
    change_to_project_root
    docker-compose ps "$service" 2>/dev/null | grep -q "Up"
}

# Wait for service to be healthy
wait_for_service_healthy() {
    local service="$1"
    local timeout="${2:-300}" # 5 minutes default
    local interval="${3:-5}"
    local elapsed=0
    
    log_info "Waiting for $service to be healthy (timeout: ${timeout}s)"
    
    while [ $elapsed -lt $timeout ]; do
        if is_service_healthy "$service"; then
            log_success "$service is healthy"
            return 0
        fi
        
        sleep "$interval"
        elapsed=$((elapsed + interval))
        echo -n "."
    done
    
    echo ""
    error_exit "$service failed to become healthy within ${timeout}s"
}

# Check if service is healthy (using healthcheck)
is_service_healthy() {
    local service="$1"
    local container_id
    container_id=$(get_container_id "$service")
    
    if [ -z "$container_id" ]; then
        return 1
    fi
    
    local health_status
    health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container_id" 2>/dev/null || echo "none")
    
    [ "$health_status" = "healthy" ]
}

# Execute command in service container with error handling
docker_exec_safe() {
    local service="$1"
    shift
    local command=("$@")
    
    if ! is_service_running "$service"; then
        error_exit "Service '$service' is not running"
    fi
    
    change_to_project_root
    docker-compose exec -T "$service" "${command[@]}"
}

# Validate Docker Compose configuration
validate_compose_config() {
    change_to_project_root
    if ! docker-compose config --quiet 2>/dev/null; then
        error_exit "Docker Compose configuration is invalid"
    fi
    log_success "Docker Compose configuration is valid"
}

# ==============================================================================
# SECRET MANAGEMENT UTILITIES
# ==============================================================================

# Read secret from file with validation
read_secret() {
    local secret_name="$1"
    local secret_file="${SECRETS_DIR}/${secret_name}.txt"
    
    if [ ! -f "$secret_file" ]; then
        error_exit "Secret file not found: $secret_file"
    fi
    
    if [ ! -r "$secret_file" ]; then
        error_exit "Secret file not readable: $secret_file"
    fi
    
    cat "$secret_file"
}

# Check if secret exists
secret_exists() {
    local secret_name="$1"
    local secret_file="${SECRETS_DIR}/${secret_name}.txt"
    [ -f "$secret_file" ] && [ -r "$secret_file" ]
}

# Validate all required secrets exist (basic validation only)
# This function delegates to the comprehensive validation function in validation.sh
validate_secrets() {
    # Source validation.sh if the function doesn't exist yet
    if ! command -v validate_secrets_configuration >/dev/null 2>&1; then
        local validation_lib="${SCRIPT_DIR}/validation.sh"
        if [ -f "$validation_lib" ]; then
            source "$validation_lib"
        else
            # Fallback to direct path if SCRIPT_DIR doesn't work
            source "$(dirname "${BASH_SOURCE[0]}")/validation.sh"
        fi
    fi
    
    # Call the comprehensive function in basic mode
    validate_secrets_configuration "basic"
}

# ==============================================================================
# SYSTEM AND ENVIRONMENT UTILITIES
# ==============================================================================

# Get timestamp for backups and logs
get_timestamp() {
    date +%Y%m%d_%H%M%S
}

# Get human-readable date
get_readable_date() {
    date -Iseconds
}

# Check available disk space
check_disk_space() {
    local path="${1:-$PROJECT_ROOT}"
    local min_space_gb="${2:-5}" # 5GB minimum by default
    
    local available_gb
    available_gb=$(df -BG "$path" | awk 'NR==2 {print $4}' | sed 's/G//')
    
    if [ "$available_gb" -lt "$min_space_gb" ]; then
        error_exit "Insufficient disk space. Available: ${available_gb}GB, Required: ${min_space_gb}GB"
    fi
    
    log_info "Disk space check passed: ${available_gb}GB available"
}

# Get system information
get_system_info() {
    echo "System Information:"
    echo "  OS: $(uname -s) $(uname -r)"
    echo "  Architecture: $(uname -m)"
    echo "  Docker: $(docker --version 2>/dev/null || echo 'Not installed')"
    echo "  Docker Compose: $(docker-compose --version 2>/dev/null || echo 'Not installed')"
    echo "  User: $(whoami) (UID: $(id -u))"
    echo "  Working Directory: $(pwd)"
    echo "  Project Root: $PROJECT_ROOT"
}

# ==============================================================================
# FILE AND BACKUP UTILITIES
# ==============================================================================

# Create directory with proper permissions
create_dir_safe() {
    local dir="$1"
    local mode="${2:-755}"
    
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || error_exit "Failed to create directory: $dir"
        chmod "$mode" "$dir"
        log_success "Created directory: $dir"
    fi
}

# Backup file with timestamp
backup_file() {
    local file="$1"
    local backup_dir="${2:-$(dirname "$file")}"
    
    if [ -f "$file" ]; then
        local timestamp=$(get_timestamp)
        local backup_file="${backup_dir}/$(basename "$file").backup.${timestamp}"
        cp "$file" "$backup_file"
        log_info "Backed up $file to $backup_file"
    fi
}

# Clean up old files by age
cleanup_old_files() {
    local directory="$1"
    local pattern="$2"
    local days="${3:-30}"
    
    if [ -d "$directory" ]; then
        local count
        count=$(find "$directory" -name "$pattern" -type f -mtime +$days 2>/dev/null | wc -l)
        
        if [ "$count" -gt 0 ]; then
            find "$directory" -name "$pattern" -type f -mtime +$days -delete
            log_info "Cleaned up $count old files in $directory"
        fi
    fi
}

# ==============================================================================
# ENCRYPTION AND COMPRESSION UTILITIES
# ==============================================================================

# Check if age encryption is available
is_age_available() {
    command -v age >/dev/null 2>&1
}

# Get age recipients file path
get_age_recipients_file() {
    echo "${SECRETS_DIR}/age-recipients.txt"
}

# Encrypt file with age if available, otherwise compress with gzip
encrypt_or_compress() {
    local source_file="$1"
    local encryption_mode="${2:-auto}"
    
    case "$encryption_mode" in
        "age")
            if is_age_available && [ -f "$(get_age_recipients_file)" ]; then
                age -R "$(get_age_recipients_file)" -o "${source_file}.age" "$source_file"
                rm "$source_file"
                log_success "Encrypted: $(basename "$source_file")"
                echo "${source_file}.age"
            else
                error_exit "Age encryption requested but not available"
            fi
            ;;
        "gzip")
            gzip "$source_file"
            log_success "Compressed: $(basename "$source_file")"
            echo "${source_file}.gz"
            ;;
        "auto")
            if is_age_available && [ -f "$(get_age_recipients_file)" ]; then
                encrypt_or_compress "$source_file" "age"
            else
                encrypt_or_compress "$source_file" "gzip"
            fi
            ;;
        "none")
            log_info "Stored uncompressed: $(basename "$source_file")"
            echo "$source_file"
            ;;
        *)
            error_exit "Invalid encryption mode: $encryption_mode"
            ;;
    esac
}

# ==============================================================================
# NETWORK AND SECURITY UTILITIES
# ==============================================================================

# Test network connectivity
test_connectivity() {
    local host="$1"
    local port="$2"
    local timeout="${3:-5}"
    
    if timeout "$timeout" bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check if port is available
is_port_available() {
    local port="$1"
    ! ss -tuln | grep -q ":$port "
}

# ==============================================================================
# INITIALIZATION AND CLEANUP
# ==============================================================================

# Initialize common environment
init_common() {
    # Validate basic requirements
    require_commands "docker" "docker-compose"
    validate_project_structure
    
    # Set up signal handlers for cleanup
    trap cleanup_common EXIT
    trap 'error_exit "Script interrupted"' INT TERM
    
    log_success "Common utilities initialized"
}

# Cleanup function called on script exit
cleanup_common() {
    # Perform any necessary cleanup
    # This can be overridden by individual scripts
    :
}

# ==============================================================================
# SCRIPT TEMPLATE FUNCTIONS
# ==============================================================================

# Standard script header
print_script_header() {
    local script_name="$1"
    local description="$2"
    
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} ${WHITE}${script_name}${NC} $(printf "%*s" $((75 - ${#script_name})) "") ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${description} $(printf "%*s" $((75 - ${#description})) "") ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo
}

# Standard script footer
print_script_footer() {
    local script_name="$1"
    
    echo
    echo -e "${GREEN}${CHECKMARK} $script_name completed successfully!${NC}"
    echo -e "${BLUE}ℹ${NC} For more information, check the logs at: $LOG_FILE"
}

# Confirmation prompt
confirm_action() {
    local message="$1"
    local default="${2:-N}"
    
    if [ "$default" = "Y" ]; then
        read -p "$message (Y/n): " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]
    else
        read -p "$message (y/N): " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

# ==============================================================================
# VERSION AND COMPATIBILITY
# ==============================================================================

# Common library version
readonly COMMON_LIB_VERSION="1.0.0"

# Print version information
print_version() {
    echo "N8N Infrastructure Common Library v${COMMON_LIB_VERSION}"
}

# Export functions for use in other scripts
export -f log log_info log_success log_warn log_error log_debug
export -f warn error_exit info
export -f check_root check_not_root require_commands validate_project_structure
export -f change_to_project_root get_container_id get_container_id_safe get_container_name
export -f is_service_running wait_for_service_healthy is_service_healthy docker_exec_safe
export -f validate_compose_config read_secret secret_exists validate_secrets
export -f get_timestamp get_readable_date check_disk_space get_system_info
export -f create_dir_safe backup_file cleanup_old_files
export -f is_age_available get_age_recipients_file encrypt_or_compress
export -f test_connectivity is_port_available
export -f init_common cleanup_common print_script_header print_script_footer confirm_action

# Export constants
export RED GREEN YELLOW BLUE PURPLE CYAN WHITE NC
export CHECKMARK CROSS WARNING INFO
export PROJECT_ROOT SECRETS_DIR LOG_FILE COMMON_LIB_VERSION