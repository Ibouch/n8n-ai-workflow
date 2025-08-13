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
COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$COMMON_LIB_DIR")")"
SECRETS_DIR="${PROJECT_ROOT}/secrets"

# Default log file (can be overridden by calling scripts)
LOG_FILE="${LOG_FILE:-${PROJECT_ROOT}/logs/scripts.log}"

# Ensure logs directory exists and is writable
if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
    # Fallback to user's home directory if project logs aren't writable
    LOG_FILE="${HOME}/.n8n-scripts.log"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
fi

# Test if log file is writable
if ! touch "$LOG_FILE" 2>/dev/null; then
    # Final fallback to /tmp
    LOG_FILE="/tmp/n8n-scripts-$(id -u).log"
fi

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
    local level
    local message
    # Support both two-argument (level, message) and one-argument (message only) usage
    if [ "$#" -ge 2 ]; then
        level="$1"
        message="$2"
    else
        level="INFO"
        message="$1"
    fi
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    # Format log entry
    local log_entry="[${timestamp}] [${level}] ${message}"

    # Color and symbol mapping for different log levels
    local color=""
    local symbol="$INFO"
    case "$level" in
        "ERROR") color="$RED"; symbol="$CROSS" ;;
        "WARN"|"WARNING") color="$YELLOW"; symbol="$WARNING" ;;
        "SUCCESS") color="$GREEN"; symbol="$CHECKMARK" ;;
        "INFO") color="$BLUE"; symbol="$INFO" ;;
        "DEBUG") color="$PURPLE"; symbol="$INFO" ;;
        *) color="$NC"; symbol="$INFO" ;;
    esac

    # Output to console with color
    echo -e "${color}${symbol} ${message}${NC}"

    # Output to log file without color (silently ignore if can't write)
    echo "$log_entry" >> "$LOG_FILE" 2>/dev/null || true
}

# Convenience logging functions
log_info() { log "INFO" "$1"; }
log_success() { log "SUCCESS" "$1"; }
log_warn() { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }
log_debug() { log "DEBUG" "$1"; }

# Warning function that doesn't exit
warn() {
    echo -e "${YELLOW}${WARNING} [WARNING]${NC} $1" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${YELLOW}${WARNING} [WARNING]${NC} $1"
}

# Error function that exits with code
error_exit() {
    local message="$1"
    local exit_code="${2:-1}"
    echo -e "${RED}${CROSS} [ERROR]${NC} $message" >&2
    # Try to log to file, but don't fail if we can't
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $message" >> "$LOG_FILE" 2>/dev/null || true
    exit "$exit_code"
}

# Info function for general information
info() {
    echo -e "${BLUE}${INFO} [INFO]${NC} $1" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${BLUE}${INFO} [INFO]${NC} $1"
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
    local skip_secrets_check="${1:-false}"

    local required_paths=(
        "$PROJECT_ROOT/compose.yml"
        "$PROJECT_ROOT/scripts"
    )

    # Only check secrets directory if not generating secrets
    if [ "$skip_secrets_check" != "true" ]; then
        required_paths+=("$PROJECT_ROOT/secrets")
    fi

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
    docker compose ps -q "$service" 2>/dev/null | head -1
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
    docker compose ps "$service" 2>/dev/null | grep -q "Up"
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
    docker compose exec -T "$service" "${command[@]}"
}

# Validate Docker Compose configuration
validate_compose_config() {
    change_to_project_root
    if ! docker compose config --quiet 2>/dev/null; then
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
        local validation_lib="${COMMON_LIB_DIR}/validation.sh"
        if [ -f "$validation_lib" ]; then
            source "$validation_lib"
        else
            # Fallback to direct path if COMMON_LIB_DIR doesn't work
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
    echo "  Docker Compose: $(docker compose --version 2>/dev/null || echo 'Not installed')"
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
    local skip_secrets_validation="${1:-false}"
    local require_docker="${2:-true}"

    # Validate basic requirements
    if [ "$require_docker" = "true" ]; then
        require_commands "docker"
    fi
    validate_project_structure "$skip_secrets_validation"

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

    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} ${WHITE}${script_name}${NC} $(printf "%*s" $((75 - ${#script_name})) "") ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${description} $(printf "%*s" $((75 - ${#description})) "") ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
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
# ==============================================================================
# ENVIRONMENT LOADING AND VALIDATION
# ==============================================================================

# Performance-optimized whitespace trimming
_trim_whitespace() {
    local var="$1"
    # Remove leading whitespace
    var="${var#"${var%%[![:space:]]*}"}"
    # Remove trailing whitespace
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# Secure dotenv parser with robust error handling
# Features:
# - Zero command execution risk
# - Performance-optimized parsing
# - Comprehensive validation
# - Secrets file integration
# - Detailed error reporting with line numbers
load_dotenv() {
    local dotenv_file="${1:-${PROJECT_ROOT}/.env}"
    local strict_mode="${2:-false}"

    if [ ! -f "$dotenv_file" ]; then
        if [ "$strict_mode" = "true" ]; then
            error_exit "Required environment file not found: $dotenv_file"
        else
            warn "Environment file not found: $dotenv_file"
            return 0
        fi
    fi

    log_info "Loading environment from $(basename "$dotenv_file")"

    local line_number=0
    local loaded=0
    local errors=0

    # Temporarily relax nounset for parsing
    set +u
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))

        # Performance-optimized whitespace trimming
        line="$(_trim_whitespace "$line")"

        # Skip comments and empty lines
        if [[ -z "$line" || "$line" == \#* ]]; then
            continue
        fi

        # Strip optional export prefix
        if [[ "$line" == export[[:space:]]* ]]; then
            line="${line#export}"
            line="$(_trim_whitespace "$line")"
        fi

        # Validate KEY=VALUE format
        if [[ "$line" != *"="* ]]; then
            if [ "$strict_mode" = "true" ]; then
                error_exit "Invalid line format at $dotenv_file:$line_number: $line"
            else
                warn "Skipping invalid line at $dotenv_file:$line_number: $line"
                errors=$((errors + 1))
                continue
            fi
        fi

        # Enhanced parsing to handle multiple = signs correctly
        local key="${line%%=*}"
        local value="${line#*=}"

        # Trim whitespace around key
        key="$(_trim_whitespace "$key")"

        # Comprehensive key validation
        if [[ -z "$key" ]]; then
            warn "Empty key at $dotenv_file:$line_number"
            errors=$((errors + 1))
            continue
        fi

        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            if [ "$strict_mode" = "true" ]; then
                error_exit "Invalid environment variable name '$key' at $dotenv_file:$line_number"
            else
                warn "Skipping invalid env key '$key' at $dotenv_file:$line_number"
                errors=$((errors + 1))
                continue
            fi
        fi

        # Enhanced value processing
        value="$(_trim_whitespace "$value")"

        # Handle quoted values with proper escape sequence support
        if [[ ${#value} -ge 2 ]]; then
            local first_char="${value:0:1}"
            local last_char="${value: -1}"

            # Strip matching quotes and handle escape sequences
            if [[ "$first_char" == '"' && "$last_char" == '"' ]]; then
                value="${value:1:${#value}-2}"
                # Process escape sequences in double quotes
                value="${value//\\n/$'\n'}"
                value="${value//\\t/$'\t'}"
                value="${value//\\r/$'\r'}"
                value="${value//\\\\/\\}"
                value="${value//\\\"/\"}"
            elif [[ "$first_char" == "'" && "$last_char" == "'" ]]; then
                # Single quotes - no escape processing
                value="${value:1:${#value}-2}"
            fi
        fi

        # Secrets integration - handle file:// references
        if [[ "$value" == file://* ]]; then
            local secret_path="${value#file://}"

            # Handle relative paths
            if [[ "$secret_path" != /* ]]; then
                secret_path="${SECRETS_DIR}/${secret_path}"
            fi

            if [[ -f "$secret_path" && -r "$secret_path" ]]; then
                # Read secret file content, removing any trailing newlines
                value="$(cat "$secret_path" | tr -d '\n\r')"
                log_debug "Loaded secret for $key from $secret_path"
            else
                if [ "$strict_mode" = "true" ]; then
                    error_exit "Secret file not found or not readable: $secret_path (referenced by $key)"
                else
                    warn "Secret file not found for $key: $secret_path"
                    errors=$((errors + 1))
                    continue
                fi
            fi
        fi

        # Security: Validate value doesn't contain dangerous patterns
        if [[ "$value" == *'$('* || "$value" == *'`'* || "$value" == *'${'* ]]; then
            warn "Potentially dangerous value for $key at $dotenv_file:$line_number (contains command substitution)"
            if [ "$strict_mode" = "true" ]; then
                error_exit "Dangerous value detected for $key"
            fi
        fi

        # Assign and export variable safely
        printf -v "$key" '%s' "$value"
        export "$key"

        loaded=$((loaded + 1))
        log_debug "Set $key from $dotenv_file:$line_number"

    done < "$dotenv_file"
    set -u

    if [ $loaded -gt 0 ]; then
        log_success "Loaded $loaded variables from $(basename "$dotenv_file")"
    fi

    if [ $errors -gt 0 ]; then
        warn "Encountered $errors errors in $(basename "$dotenv_file")"
    fi

    if [ $loaded -eq 0 ] && [ "$strict_mode" = "true" ]; then
        error_exit "No environment variables loaded"
    fi

    log_info "Environment loading complete: $loaded variables loaded, $errors errors"
    return 0
}

# Validate critical environment variables with comprehensive checks
validate_critical_env_vars() {
    local strict_mode="${1:-false}"

    log_info "Validating critical environment variables..."

    # Define critical variables by category
    local database_vars=(
        "POSTGRES_DB:PostgreSQL database name"
        "POSTGRES_USER:PostgreSQL username"
    )

    local security_vars=(
        "N8N_BASIC_AUTH_ACTIVE:N8N basic authentication"
        "N8N_SECURE_COOKIE:Secure cookie setting"
    )

    local network_vars=(
        "N8N_HOST:N8N host domain"
        "N8N_PROTOCOL:N8N protocol"
    )

    local optional_vars=(
        "SMTP_HOST:SMTP server host"
        "SMTP_PORT:SMTP server port"
        "GENERIC_TIMEZONE:System timezone"
    )

    local missing_critical=()
    local missing_optional=()
    local validation_warnings=()

    # Validate critical variables
    local all_critical=("${database_vars[@]}" "${security_vars[@]}" "${network_vars[@]}")

    for var_spec in "${all_critical[@]}"; do
        local var_name="${var_spec%%:*}"
        local var_desc="${var_spec#*:}"

        if [[ -z "${!var_name:-}" ]]; then
            missing_critical+=("$var_name ($var_desc)")
        else
            # Additional validation based on variable type
            case "$var_name" in
                "POSTGRES_DB")
                    if [[ ! "${!var_name}" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
                        validation_warnings+=("$var_name contains invalid characters for database name")
                    fi
                    ;;
                "N8N_PROTOCOL")
                    if [[ "${!var_name}" != "http" && "${!var_name}" != "https" ]]; then
                        validation_warnings+=("$var_name should be 'http' or 'https'")
                    fi
                    ;;
                "N8N_HOST")
                    if [[ "${!var_name}" == "localhost" ]]; then
                        validation_warnings+=("$var_name is set to localhost (not suitable for production)")
                    fi
                    ;;
            esac
        fi
    done

    # Check optional variables
    for var_spec in "${optional_vars[@]}"; do
        local var_name="${var_spec%%:*}"
        local var_desc="${var_spec#*:}"

        if [[ -z "${!var_name:-}" ]]; then
            missing_optional+=("$var_name ($var_desc)")
        else
            # Additional validation for optional vars
            case "$var_name" in
                "SMTP_PORT")
                    if [[ ! "${!var_name}" =~ ^[0-9]+$ ]] || [[ "${!var_name}" -lt 1 || "${!var_name}" -gt 65535 ]]; then
                        validation_warnings+=("$var_name must be a valid port number (1-65535)")
                    fi
                    ;;
                "GENERIC_TIMEZONE")
                    # Basic timezone validation
                    if [[ ! "${!var_name}" =~ ^[A-Za-z_/+-]+$ ]]; then
                        validation_warnings+=("$var_name appears to have invalid timezone format")
                    fi
                    ;;
            esac
        fi
    done

    # Report results
    if [[ ${#missing_critical[@]} -gt 0 ]]; then
        local missing_list=""
        for var in "${missing_critical[@]}"; do
            missing_list="${missing_list}\n  - $var"
        done

        if [[ "$strict_mode" == "true" ]]; then
            error_exit "Missing critical environment variables:$missing_list"
        else
            log_error "Missing critical environment variables:$missing_list"
            return 1
        fi
    fi

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        local optional_list=""
        for var in "${missing_optional[@]}"; do
            optional_list="${optional_list}\n  - $var"
        done
        warn "Missing optional environment variables:$optional_list"
    fi

    if [[ ${#validation_warnings[@]} -gt 0 ]]; then
        for warning in "${validation_warnings[@]}"; do
            warn "Environment validation: $warning"
        done
    fi

    # Security recommendations
    if [[ "${N8N_BASIC_AUTH_ACTIVE:-}" != "true" ]]; then
        warn "Security recommendation: Enable N8N basic authentication (N8N_BASIC_AUTH_ACTIVE=true)"
    fi

    if [[ "${N8N_PROTOCOL:-}" == "https" && "${N8N_SECURE_COOKIE:-}" != "true" ]]; then
        warn "Security recommendation: Enable secure cookies for HTTPS (N8N_SECURE_COOKIE=true)"
    fi

    local validation_score=$((100 - ${#missing_critical[@]} * 25 - ${#missing_optional[@]} * 5 - ${#validation_warnings[@]} * 10))
    validation_score=$((validation_score < 0 ? 0 : validation_score))

    log_info "Environment validation score: $validation_score/100"

    if [[ $validation_score -ge 90 ]]; then
        log_success "Environment configuration is excellent"
    elif [[ $validation_score -ge 75 ]]; then
        log_success "Environment configuration is good"
    elif [[ $validation_score -ge 50 ]]; then
        warn "Environment configuration needs improvement"
    else
        warn "Environment configuration has significant issues"
    fi

    return 0
}

# Initialize environment with validation and sensible defaults
init_environment() {
    local strict_mode="${1:-false}"
    local validate_critical="${2:-true}"

    log_info "Initializing environment configuration"

    # Load environment file
    load_dotenv "${PROJECT_ROOT}/.env" "$strict_mode"

    # Validate critical variables if requested
    if [[ "$validate_critical" == "true" ]]; then
        validate_critical_env_vars "$strict_mode"
    fi

    # Set sensible defaults for unset variables
    export POSTGRES_DB="${POSTGRES_DB:-n8n}"
    export POSTGRES_USER="${POSTGRES_USER:-n8n_admin}"
    export GENERIC_TIMEZONE="${GENERIC_TIMEZONE:-UTC}"
    export N8N_PROTOCOL="${N8N_PROTOCOL:-https}"
    export N8N_BASIC_AUTH_ACTIVE="${N8N_BASIC_AUTH_ACTIVE:-true}"
    export N8N_SECURE_COOKIE="${N8N_SECURE_COOKIE:-true}"
    export ENABLE_REDIS_CACHE="${ENABLE_REDIS_CACHE:-true}"
    export ENABLE_MONITORING="${ENABLE_MONITORING:-true}"

    # Log environment summary
    log_info "Environment initialization complete:"
    log_info "  Database: ${POSTGRES_DB} (user: ${POSTGRES_USER})"
    log_info "  Host: ${N8N_HOST:-localhost}"
    log_info "  Protocol: ${N8N_PROTOCOL}"
    log_info "  Timezone: ${GENERIC_TIMEZONE}"

    return 0
}

# Environment diagnostic and debugging function
diagnose_environment() {
    local output_file="${1:-${PROJECT_ROOT}/environment-diagnosis.json}"

    log_info "Running environment diagnostics..."

    # Check for .env file
    local env_file_status="not_found"
    [[ -f "${PROJECT_ROOT}/.env" ]] && env_file_status="found"

    # Check secrets directory
    local secrets_status="not_found"
    local secret_files=()
    if [[ -d "$SECRETS_DIR" ]]; then
        secrets_status="found"
        while IFS= read -r -d '' file; do
            secret_files+=("$(basename "$file")")
        done < <(find "$SECRETS_DIR" -name "*.txt" -print0 2>/dev/null)
    fi

    # Generate comprehensive diagnosis
    cat > "$output_file" << EOF
{
  "timestamp": "$(get_readable_date)",
  "files": {
    "env_file": "$env_file_status",
    "secrets_directory": "$secrets_status",
    "secret_files": [$(printf '"%s",' "${secret_files[@]}" | sed 's/,$//')],
    "secret_count": ${#secret_files[@]}
  },
  "critical_variables": {
    "postgres_db": "${POSTGRES_DB:-MISSING}",
    "postgres_user": "${POSTGRES_USER:-MISSING}",
    "n8n_host": "${N8N_HOST:-MISSING}",
    "n8n_protocol": "${N8N_PROTOCOL:-MISSING}",
    "smtp_configured": $([ -n "${SMTP_HOST:-}" ] && echo "true" || echo "false"),
    "basic_auth_enabled": "${N8N_BASIC_AUTH_ACTIVE:-MISSING}",
    "secure_cookies": "${N8N_SECURE_COOKIE:-MISSING}"
  },
  "features": {
    "redis_cache": "${ENABLE_REDIS_CACHE:-MISSING}",
    "monitoring": "${ENABLE_MONITORING:-MISSING}",
    "backup_encryption": "${BACKUP_ENCRYPTION_ENABLED:-MISSING}"
  },
  "system": {
    "timezone": "${GENERIC_TIMEZONE:-MISSING}",
    "log_level": "${N8N_LOG_LEVEL:-MISSING}",
    "development_mode": "${DEVELOPMENT_MODE:-MISSING}"
  },
  "script_info": {
    "common_lib_version": "${COMMON_LIB_VERSION}",
    "project_root": "$PROJECT_ROOT",
    "secrets_dir": "$SECRETS_DIR"
  }
}
EOF

    log_success "Environment diagnosis saved to $output_file"

    # Print summary to console
    echo -e "\n${BLUE}Environment Diagnosis Summary:${NC}"
    echo "├─ Config file: $env_file_status"
    echo "├─ Secrets: $secrets_status (${#secret_files[@]} files)"
    echo "├─ Database: ${POSTGRES_DB:-MISSING}"
    echo "├─ Host: ${N8N_HOST:-localhost}"
    echo "└─ Protocol: ${N8N_PROTOCOL:-MISSING}"

    return 0
}
# ==============================================================================
# ENVIRONMENT VALIDATION FUNCTIONS
# ==============================================================================

# Assert environment variable is set and non-empty
assert_env() {
    local var_name="$1"
    local description="${2:-$var_name}"
    local default_value="${3:-}"

    if [ -z "${!var_name:-}" ]; then
        if [ -n "$default_value" ]; then
            export "$var_name"="$default_value"
            log_warn "$description not set, using default: $default_value"
        else
            error_exit "$description is required but not set (environment variable: $var_name)"
        fi
    fi
}

# Validate multiple environment variables at once
validate_required_env() {
    local vars=("$@")
    local missing_vars=()

    for var in "${vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        error_exit "Required environment variables not set: ${missing_vars[*]}"
    fi
}

# Validate common N8N environment variables
validate_n8n_env() {
    log_info "Validating N8N environment configuration..."

    # Required variables
    assert_env "POSTGRES_DB" "PostgreSQL database name" "n8n"
    assert_env "GENERIC_TIMEZONE" "System timezone" "UTC"

    # Optional but recommended
    if [ -z "${N8N_HOST:-}" ]; then
        log_warn "N8N_HOST not set - using localhost (not suitable for production)"
    fi

    if [ -z "${N8N_PROTOCOL:-}" ]; then
        log_warn "N8N_PROTOCOL not set - using https (recommended)"
        export N8N_PROTOCOL="https"
    fi

    # Security validation
    if [ "${N8N_BASIC_AUTH_ACTIVE:-true}" != "true" ]; then
        warn "Basic authentication is disabled - consider enabling for security"
    fi

    if [ "${N8N_SECURE_COOKIE:-true}" != "true" ]; then
        warn "Secure cookies are disabled - consider enabling for HTTPS"
    fi
}

# Standardized HTTP health check using wget (consistent across all scripts)
http_health_check() {
    local url="$1"
    local timeout="${2:-10}"
    local retries="${3:-3}"

    for ((i=1; i<=retries; i++)); do
        if wget --no-verbose --tries=1 --timeout="$timeout" --spider "$url" >/dev/null 2>&1; then
            return 0
        fi

        if [ $i -lt $retries ]; then
            sleep 1
        fi
    done

    return 1
}

# ==============================================================================
# EXPORT ALL FUNCTIONS
# ==============================================================================

export -f check_root check_not_root require_commands validate_project_structure
export -f change_to_project_root get_container_id get_container_id_safe get_container_name
export -f is_service_running wait_for_service_healthy is_service_healthy docker_exec_safe
export -f validate_compose_config read_secret secret_exists validate_secrets
export -f get_timestamp get_readable_date check_disk_space get_system_info
export -f create_dir_safe backup_file cleanup_old_files
export -f is_age_available get_age_recipients_file encrypt_or_compress
export -f test_connectivity is_port_available
export -f init_common cleanup_common print_script_header print_script_footer confirm_action
export -f assert_env validate_required_env validate_n8n_env http_health_check
export -f _trim_whitespace load_dotenv validate_critical_env_vars init_environment diagnose_environment

# Export constants
export RED GREEN YELLOW BLUE PURPLE CYAN WHITE NC
export CHECKMARK CROSS WARNING INFO
export PROJECT_ROOT SECRETS_DIR LOG_FILE COMMON_LIB_VERSION