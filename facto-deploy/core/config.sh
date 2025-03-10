#!/bin/bash
# facto-deploy/core/config.sh - Configuration functionality for Facto deployment

# Source logging functionality
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/logging.sh"

# Global configuration associative array
declare -A CONFIG

# Load configuration from a file
# Arguments:
#   $1 - Path to configuration file
load_config_file() {
    local config_file=$1
    
    if [ ! -f "$config_file" ]; then
        log_error "Configuration file not found: $config_file"
        return 1
    }
    
    log "Loading configuration from $config_file"
    
    # Parse config file
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ $key =~ ^[[:space:]]*# ]] && continue
        [[ -z $key ]] && continue
        
        # Trim whitespace
        key=$(echo $key | xargs)
        value=$(echo $value | xargs)
        
        # Store in CONFIG array
        CONFIG["$key"]="$value"
        log "Config: $key = $value"
    done < "$config_file"
    
    return 0
}

# Set a configuration value
# Arguments:
#   $1 - Key
#   $2 - Value
set_config() {
    local key=$1
    local value=$2
    
    CONFIG["$key"]="$value"
    log "Set config: $key = $value"
}

# Get a configuration value
# Arguments:
#   $1 - Key
#   $2 - Default value (optional)
get_config() {
    local key=$1
    local default_value=$2
    
    if [ -z "${CONFIG[$key]}" ]; then
        echo "$default_value"
    else
        echo "${CONFIG[$key]}"
    fi
}

# Save configuration to a file
# Arguments:
#   $1 - Path to output file
save_config() {
    local output_file=$1
    
    log "Saving configuration to $output_file"
    
    # Ensure output directory exists
    mkdir -p "$(dirname "$output_file")"
    
    # Write header
    echo "# Facto Configuration" > "$output_file"
    echo "# Generated on $(date)" >> "$output_file"
    echo "" >> "$output_file"
    
    # Write all config values
    for key in "${!CONFIG[@]}"; do
        echo "$key=${CONFIG[$key]}" >> "$output_file"
    done
    
    log "Configuration saved to $output_file"
}

# Validate required configuration values
# Arguments:
#   $@ - List of required keys
validate_config() {
    local missing=false
    
    for key in "$@"; do
        if [ -z "${CONFIG[$key]}" ]; then
            log_error "Missing required configuration value: $key"
            missing=true
        fi
    done
    
    if [ "$missing" = true ]; then
        return 1
    fi
    return 0
}

# Set default configuration values
# Arguments:
#   $1 - Provider (aws, gcp, azure)
set_defaults() {
    local provider=$1
    
    # Common defaults
    set_config "PROVIDER" "$provider"
    set_config "PROJECT_NAME" "facto"
    set_config "NODE_TYPE" "bitcoin"
    set_config "ENVIRONMENT" "development"
    
    # Provider-specific defaults
    case "$provider" in
        aws)
            set_config "AWS_REGION" "us-east-1"
            set_config "INSTANCE_TYPE" "m5.xlarge"
            set_config "VOLUME_SIZE" "500"
            ;;
        gcp)
            set_config "GCP_REGION" "us-central1"
            set_config "MACHINE_TYPE" "n2-standard-4"
            set_config "DISK_SIZE" "500"
            ;;
        azure)
            set_config "AZURE_REGION" "eastus"
            set_config "VM_SIZE" "Standard_D4s_v3"
            set_config "DISK_SIZE" "500"
            ;;
        *)
            log_error "Unknown provider: $provider"
            return 1
            ;;
    esac
    
    return 0
} 