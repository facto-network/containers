#!/bin/bash
# facto-deploy/ui-adapter/api.sh - UI adapter for Facto deployment
# This script provides a simple API for web applications to deploy nodes

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Source core functionality
source "$BASE_DIR/core/logging.sh"
source "$BASE_DIR/core/utils.sh"
source "$BASE_DIR/core/config.sh"

# Initialize logging
init_logging "facto-ui-api"

# Constants
CONFIG_DIR="$BASE_DIR/output/state"
OUTPUT_DIR="$BASE_DIR/output/ui"

# Ensure output directory exists
ensure_dir "$OUTPUT_DIR"

# Create a JSON response
# Arguments:
#   $1 - Status (success/error)
#   $2 - Message
#   $3 - Data (optional JSON string)
create_json_response() {
    local status=$1
    local message=$2
    local data=${3:-"{}"}
    
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    cat << EOF
{
  "status": "$status",
  "message": "$message",
  "timestamp": "$timestamp",
  "data": $data
}
EOF
}

# Deploy a node via API
# Arguments:
#   $1 - JSON parameters
# Returns:
#   JSON response
deploy_node() {
    local json_params=$1
    local deploy_id=$(date +%s)
    local output_file="$OUTPUT_DIR/deploy-$deploy_id.json"
    
    log "Received deployment request: $json_params"
    
    # Parse JSON parameters
    local provider=$(echo "$json_params" | jq -r '.provider')
    local node_type=$(echo "$json_params" | jq -r '.node_type')
    local region=$(echo "$json_params" | jq -r '.region')
    local instance_type=$(echo "$json_params" | jq -r '.instance_type')
    local volume_size=$(echo "$json_params" | jq -r '.volume_size')
    local name=$(echo "$json_params" | jq -r '.name')
    
    # Validate required parameters
    if [ "$provider" == "null" ] || [ -z "$provider" ]; then
        create_json_response "error" "Provider is required" "{}"
        return 1
    fi
    
    if [ "$node_type" == "null" ] || [ -z "$node_type" ]; then
        create_json_response "error" "Node type is required" "{}"
        return 1
    fi
    
    # Create command arguments
    local cmd_args=()
    cmd_args+=("--provider" "$provider" "--type" "$node_type")
    
    if [ "$region" != "null" ] && [ ! -z "$region" ]; then
        cmd_args+=("--region" "$region")
    fi
    
    if [ "$instance_type" != "null" ] && [ ! -z "$instance_type" ]; then
        cmd_args+=("--instance-type" "$instance_type")
    fi
    
    if [ "$volume_size" != "null" ] && [ ! -z "$volume_size" ]; then
        cmd_args+=("--volume-size" "$volume_size")
    fi
    
    if [ "$name" != "null" ] && [ ! -z "$name" ]; then
        cmd_args+=("--name" "$name")
    fi
    
    # Run deployment in background
    {
        # Run deployment script
        log "Starting deployment with args: ${cmd_args[@]}"
        "$BASE_DIR/deploy.sh" "${cmd_args[@]}" > "$OUTPUT_DIR/deploy-$deploy_id.log" 2>&1
        
        # Check result
        if [ $? -eq 0 ]; then
            # Get deployment details
            if [ "$name" == "null" ] || [ -z "$name" ]; then
                name="facto-${provider}-${node_type}"
            fi
            
            if [ -f "$CONFIG_DIR/$name.conf" ]; then
                # Load configuration
                declare -A DEPLOY_CONFIG
                while IFS='=' read -r key value; do
                    # Skip comments and empty lines
                    [[ $key =~ ^[[:space:]]*# ]] && continue
                    [[ -z $key ]] && continue
                    
                    # Trim whitespace
                    key=$(echo $key | xargs)
                    value=$(echo $value | xargs)
                    
                    DEPLOY_CONFIG["$key"]="$value"
                done < "$CONFIG_DIR/$name.conf"
                
                # Create result JSON
                local result_json=$(cat << EOF
{
  "deploy_id": "$deploy_id",
  "provider": "${DEPLOY_CONFIG["PROVIDER"]}",
  "node_type": "${DEPLOY_CONFIG["NODE_TYPE"]}",
  "instance_id": "${DEPLOY_CONFIG["INSTANCE_ID"]}",
  "public_ip": "${DEPLOY_CONFIG["PUBLIC_IP"]}",
  "region": "${DEPLOY_CONFIG["AWS_REGION"]}",
  "status": "completed"
}
EOF
)
                
                # Create success response
                create_json_response "success" "Deployment completed" "$result_json" > "$output_file"
            else
                create_json_response "error" "Deployment failed or configuration not found" "{}" > "$output_file"
            fi
        else
            create_json_response "error" "Deployment failed" "{}" > "$output_file"
        fi
    } &
    
    # Return immediate response with deploy ID
    local initial_response=$(cat << EOF
{
  "deploy_id": "$deploy_id",
  "status": "pending"
}
EOF
)
    
    create_json_response "success" "Deployment started" "$initial_response"
    return 0
}

# Get deployment status
# Arguments:
#   $1 - Deploy ID
# Returns:
#   JSON response
get_deployment_status() {
    local deploy_id=$1
    local output_file="$OUTPUT_DIR/deploy-$deploy_id.json"
    
    if [ -f "$output_file" ]; then
        cat "$output_file"
    else
        local log_file="$OUTPUT_DIR/deploy-$deploy_id.log"
        if [ -f "$log_file" ]; then
            create_json_response "success" "Deployment in progress" "{\"deploy_id\": \"$deploy_id\", \"status\": \"pending\"}"
        else
            create_json_response "error" "Deployment not found" "{}"
        fi
    fi
    
    return 0
}

# List all deployments
# Returns:
#   JSON response with all deployments
list_deployments() {
    local deployments=()
    
    # Find all configurations in state directory
    for conf_file in "$CONFIG_DIR"/*.conf; do
        if [ -f "$conf_file" ]; then
            local name=$(basename "$conf_file" .conf)
            
            # Load configuration
            declare -A DEPLOY_CONFIG
            while IFS='=' read -r key value; do
                # Skip comments and empty lines
                [[ $key =~ ^[[:space:]]*# ]] && continue
                [[ -z $key ]] && continue
                
                # Trim whitespace
                key=$(echo $key | xargs)
                value=$(echo $value | xargs)
                
                DEPLOY_CONFIG["$key"]="$value"
            done < "$conf_file"
            
            # Create deployment JSON
            local deploy_json=$(cat << EOF
{
  "name": "$name",
  "provider": "${DEPLOY_CONFIG["PROVIDER"]}",
  "node_type": "${DEPLOY_CONFIG["NODE_TYPE"]}",
  "instance_id": "${DEPLOY_CONFIG["INSTANCE_ID"]}",
  "public_ip": "${DEPLOY_CONFIG["PUBLIC_IP"]}",
  "region": "${DEPLOY_CONFIG["AWS_REGION"]}",
  "created": "$(stat -c %y "$conf_file")"
}
EOF
)
            deployments+=("$deploy_json")
        fi
    done
    
    # Combine all deployments into a JSON array
    local deployments_json="["
    local separator=""
    for deploy in "${deployments[@]}"; do
        deployments_json="${deployments_json}${separator}${deploy}"
        separator=","
    done
    deployments_json="${deployments_json}]"
    
    create_json_response "success" "Deployments retrieved" "$deployments_json"
    return 0
}

# Main function
main() {
    local action=$1
    shift
    
    case "$action" in
        deploy)
            deploy_node "$1"
            ;;
        status)
            get_deployment_status "$1"
            ;;
        list)
            list_deployments
            ;;
        *)
            create_json_response "error" "Unknown action: $action" "{}"
            return 1
            ;;
    esac
    
    return 0
}

# Run main function if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 