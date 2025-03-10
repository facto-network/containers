#!/bin/bash
# facto-deploy/core/cleanup.sh - Utilities for resource cleanup and error handling

# Source logging functionality
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/logging.sh"

# Array to track created resources
declare -A CREATED_RESOURCES

# Register a resource for tracking and cleanup
# Arguments:
#   $1 - Resource type (e.g., instance, sg, key, etc.)
#   $2 - Resource ID or name
#   $3 - Cloud provider (aws, gcp, azure)
register_resource() {
    local type=$1
    local id=$2
    local provider=$3
    
    CREATED_RESOURCES["${provider}_${type}"]=$id
    log "Registered resource for cleanup: ${provider}_${type} = $id"
}

# Get a registered resource
# Arguments:
#   $1 - Resource type
#   $2 - Cloud provider
# Returns:
#   Resource ID or empty string if not found
get_resource() {
    local type=$1
    local provider=$2
    
    echo "${CREATED_RESOURCES["${provider}_${type}"]}"
}

# Default cleanup hook - should be overridden by provider-specific cleanup
cleanup_hook() {
    log "Default cleanup hook called - no provider-specific cleanup defined"
}

# Register a cleanup hook
# Arguments:
#   $1 - Function to call for cleanup
set_cleanup_hook() {
    cleanup_hook=$1
}

# Clean up registered resources
# Arguments:
#   $1 - Signal (optional) - for when called from a trap
cleanup() {
    local exit_code=$?
    local signal=$1
    
    if [ ! -z "$signal" ]; then
        log "Received signal $signal. Cleaning up resources..."
    else
        log "Script error occurred with exit code $exit_code. Cleaning up resources..."
    fi
    
    # Call provider-specific cleanup hook if defined
    if type cleanup_hook &>/dev/null; then
        cleanup_hook
    fi
    
    log "Cleanup complete."
    
    # Only exit if this wasn't called from a signal handler
    if [ -z "$signal" ]; then
        exit 1
    fi
}

# Function to set up error traps
setup_error_traps() {
    trap cleanup ERR
    trap "cleanup SIGINT" SIGINT
    trap "cleanup SIGTERM" SIGTERM
} 