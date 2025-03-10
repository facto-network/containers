#!/bin/bash
# facto-deploy/core/utils.sh - Common utility functions for Facto deployment

# Source logging functionality
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/logging.sh"

# Global dry run flag
DRY_RUN=false

# Set dry run mode
# Arguments:
#   $1 - Enable/disable dry run (true/false)
set_dry_run() {
    DRY_RUN=$1
    if $DRY_RUN; then
        log "DRY RUN MODE ENABLED - No cloud resources will be created"
    fi
}

# Execute or simulate a command based on dry run mode
# Arguments:
#   $@ - Command and arguments to execute
dry_run_exec() {
    local cmd="$@"
    
    if $DRY_RUN; then
        log "DRY RUN: Would execute: $cmd"
        return 0
    else
        log "Executing: $cmd"
        eval "$cmd"
        return $?
    fi
}

# Check for required commands/tools
# Arguments:
#   $@ - List of commands to check for
check_requirements() {
    local missing=false
    for cmd in "$@"; do
        if ! command -v $cmd &> /dev/null; then
            log_error "Required command '$cmd' not found. Please install it first."
            missing=true
        fi
    done
    
    if [ "$missing" = true ]; then
        return 1
    fi
    return 0
}

# Safely get a parameter with a default value
# Arguments:
#   $1 - Parameter name
#   $2 - Default value
#   $3 - Config object (associative array name)
get_param() {
    local param_name="$1"
    local default_value="$2"
    local config_name="$3"
    
    # Check if the config name is provided and the variable exists
    if [ ! -z "$config_name" ] && declare -p "$config_name" > /dev/null 2>&1; then
        # Get the value using indirect reference to the associative array
        local param_value="${!config_name[$param_name]}"
        if [ ! -z "$param_value" ]; then
            echo "$param_value"
            return
        fi
    fi
    
    # Return default value if the parameter wasn't found in the config
    echo "$default_value"
}

# Check if a string is a valid IP address
# Arguments:
#   $1 - String to check
is_valid_ip() {
    local ip=$1
    local stat=1
    
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a ip_array <<< "$ip"
        [[ ${ip_array[0]} -le 255 && ${ip_array[1]} -le 255 && ${ip_array[2]} -le 255 && ${ip_array[3]} -le 255 ]]
        stat=$?
    fi
    
    return $stat
}

# Check network connectivity to a host
# Arguments:
#   $1 - Host to check
#   $2 - Optional port to check (if omitted, just ping)
#   $3 - Maximum attempts
#   $4 - Wait seconds between attempts
check_connectivity() {
    local host=$1
    local port=$2
    local max_attempts=${3:-30}
    local wait_seconds=${4:-5}
    local attempt=1
    
    if $DRY_RUN; then
        log "DRY RUN: Would check connectivity to $host"
        return 0
    fi
    
    log "Checking connectivity to $host..."
    
    while (( attempt <= max_attempts )); do
        log "Attempt $attempt of $max_attempts..."
        
        # Check basic reachability with ping
        if ping -c 1 -W 2 $host &>/dev/null; then
            log "Host is responding to ping!"
            
            # If port is specified, check TCP connectivity
            if [ ! -z "$port" ]; then
                if nc -z -w 5 $host $port &>/dev/null; then
                    log "Port $port is open and accepting connections!"
                    return 0
                else
                    log "Port $port not responding yet..."
                fi
            else
                # No port specified, ping success is enough
                return 0
            fi
        else
            log "Host not responding to ping yet..."
        fi
        
        (( attempt++ ))
        sleep $wait_seconds
    done
    
    log_warning "Host did not become fully accessible within the timeout period"
    return 1
}

# Generate a random password
# Arguments:
#   $1 - Length of password (default: 16)
generate_password() {
    local length=${1:-16}
    
    # Using openssl for better randomness if available
    if command -v openssl &> /dev/null; then
        openssl rand -hex $(($length / 2))
    else
        # Fallback to built-in methods
        cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $length | head -n 1
    fi
}

# Create a directory if it doesn't exist
# Arguments:
#   $1 - Directory path
ensure_dir() {
    local dir_path=$1
    
    if [ ! -d "$dir_path" ]; then
        log "Creating directory: $dir_path"
        mkdir -p "$dir_path"
    fi
}

# Convert relative to absolute path
# Arguments:
#   $1 - Relative path
to_absolute_path() {
    local path=$1
    
    if [[ "$path" != /* ]]; then
        path="$(pwd)/$path"
    fi
    
    echo "$path"
} 