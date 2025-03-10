#!/bin/bash
# facto-deploy/core/logging.sh - Core logging functionality for Facto deployment scripts

# Default log directory
DEFAULT_LOG_DIR="$(dirname "$(dirname "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )")")/output/logs"

# Initialize logging
# Arguments:
#   $1 - Log file prefix (optional)
init_logging() {
    local prefix=${1:-facto-deployment}
    local timestamp=$(date +%Y%m%d-%H%M%S)
    
    # Ensure log directory exists
    mkdir -p "$DEFAULT_LOG_DIR"
    
    # Set global LOG_FILE variable
    LOG_FILE="$DEFAULT_LOG_DIR/${prefix}-${timestamp}.log"
    
    # Start logging
    exec > >(tee -a "$LOG_FILE") 2>&1
    
    log "===== Facto Deployment Log - $(date) ====="
    log "Script started by user: $(whoami)"
    
    # Log system information
    log "System information:"
    log "OS: $(uname -a)"
}

# Log function to timestamp messages
# Arguments:
#   $1 - Message to log
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Log an error message and optionally exit
# Arguments:
#   $1 - Error message
#   $2 - Exit code (optional, default: no exit)
log_error() {
    log "ERROR: $1"
    if [ ! -z "$2" ]; then
        exit $2
    fi
}

# Log a warning message
# Arguments:
#   $1 - Warning message
log_warning() {
    log "WARNING: $1"
}

# Log a success message
# Arguments:
#   $1 - Success message
log_success() {
    log "SUCCESS: $1"
}

# Get the log file path
get_log_file() {
    echo "$LOG_FILE"
} 