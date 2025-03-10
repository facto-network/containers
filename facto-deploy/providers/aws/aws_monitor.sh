#!/bin/bash
# facto-deploy/providers/aws/aws_monitor.sh - AWS node monitoring implementation

# Source core functionality
BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/../../"
source "$BASE_DIR/core/logging.sh"
source "$BASE_DIR/core/utils.sh"
source "$BASE_DIR/core/config.sh"

# Check if SSH is available on the host
# Arguments:
#   $1 - Host
#   $2 - Key file
#   $3 - Maximum attempts
# Returns:
#   0 - Success, 1 - Failure
check_ssh() {
    local host=$1
    local key=$2
    local max_attempts=${3:-30}
    local wait_seconds=10
    local attempt=1
    
    if $DRY_RUN; then
        log "DRY RUN: Would check SSH connectivity to $host with key $key"
        log "DRY RUN: Simulating successful SSH connection"
        return 0
    }
    
    # Give the instance a bit more time for initial setup
    log "Waiting 30 seconds for instance to initialize before attempting SSH..."
    sleep 30
    
    log "Waiting for SSH to become available on $host..."
    while (( attempt <= max_attempts )); do
        log "SSH connection attempt $attempt of $max_attempts..."
        
        # Try SSH connection with verbose logging to help diagnose issues
        if ssh -v -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes ubuntu@$host "echo SSH connection successful" &> "$BASE_DIR/output/logs/ssh_attempt_${host}.log"; then
            log "SSH connection established!"
            return 0
        else
            # Log SSH debugging information
            log "SSH debug output:"
            cat "$BASE_DIR/output/logs/ssh_attempt_${host}.log" | while read line; do
                log "  $line"
            done
        fi
        
        (( attempt++ ))
        
        # Check if instance is still running (if AWS)
        if [ "$(get_config "PROVIDER")" = "aws" ]; then
            local instance_id=$(get_config "INSTANCE_ID")
            local region=$(get_config "AWS_REGION" "us-east-1")
            
            if [ ! -z "$instance_id" ]; then
                local status=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].State.Name' --output text --region "$region")
                log "Instance status: $status"
                
                if [ "$status" != "running" ]; then
                    log_error "Instance is no longer running, status is $status"
                    return 1
                fi
            fi
        fi
        
        log "Waiting $wait_seconds seconds before next attempt..."
        sleep $wait_seconds
    done
    
    log_warning "Failed to establish SSH connection after $max_attempts attempts"
    log_warning "Try connecting manually: ssh -i $key ubuntu@$host"
    
    return 1
}

# Monitor node setup progress
# Arguments:
#   $1 - Host
#   $2 - Key file
#   $3 - Timeout (seconds)
# Returns:
#   0 - Success, 1 - Failure
monitor_setup() {
    local host=$1
    local key=$2
    local timeout=${3:-1800}
    local start_time=$(date +%s)
    local current_time=0
    local elapsed=0
    
    if $DRY_RUN; then
        log "DRY RUN: Would monitor setup progress on $host"
        log "DRY RUN: Simulating cloud-init and bitcoind service status checks"
        log "DRY RUN: Simulating successful setup completion"
        return 0
    }
    
    log "Monitoring setup progress on $host..."
    
    while (( elapsed < timeout )); do
        # Check if we can SSH to the host
        if ! ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes ubuntu@$host "echo SSH connection test" &>/dev/null; then
            log "SSH connection lost or not available. Will retry..."
            sleep 10
            current_time=$(date +%s)
            elapsed=$((current_time - start_time))
            continue
        fi
        
        # Check cloud-init status
        local cloud_init_status=$(ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$host "cloud-init status" 2>/dev/null)
        
        # Check bitcoind service status (assuming Bitcoin node)
        local bitcoind_status=$(ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$host "systemctl is-active bitcoind" 2>/dev/null)
        
        log "Cloud-init status: $cloud_init_status"
        log "Bitcoin daemon status: $bitcoind_status"
        
        # If cloud-init is done and bitcoind is active, we're finished
        if [[ "$cloud_init_status" == *"done"* ]] && [[ "$bitcoind_status" == "active" ]]; then
            log_success "Setup completed successfully!"
            
            # Get Bitcoin sync status
            local bitcoin_info=$(ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$host "bitcoin-cli -testnet getblockchaininfo 2>/dev/null || echo 'Not ready yet'" 2>/dev/null)
            log "Initial Bitcoin status: $(echo "$bitcoin_info" | grep -E 'blocks|headers|verificationprogress' | tr '\n' ' ')"
            
            return 0
        fi
        
        # If cloud-init failed, report error
        if [[ "$cloud_init_status" == *"error"* ]]; then
            log_error "Cloud-init reported an error."
            log "Fetching cloud-init logs for debugging..."
            ssh -i "$key" -o StrictHostKeyChecking=no ubuntu@$host "sudo cat /var/log/cloud-init-output.log" > "$BASE_DIR/output/logs/cloud-init-error-$host.log"
            log "Cloud-init logs saved to $BASE_DIR/output/logs/cloud-init-error-$host.log"
            return 1
        fi
        
        # Wait before checking again
        sleep 30
        
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        log "Setup monitoring in progress... ($elapsed seconds elapsed of $timeout maximum)"
    done
    
    log_warning "Setup monitoring timed out after $timeout seconds"
    log_warning "The setup may still complete successfully in the background."
    
    return 1
}

# Get node status - checks Bitcoin node status
# Arguments:
#   $1 - Host
#   $2 - Key file
# Returns:
#   0 - Success, 1 - Failure
get_node_status() {
    local host=$1
    local key=$2
    
    if $DRY_RUN; then
        log "DRY RUN: Would check node status on $host"
        log "DRY RUN: Simulated status:"
        log "  ===== Facto Bitcoin Node Status ====="
        log "  Date: $(date)"
        log "  Bitcoin daemon: RUNNING"
        log "  Current block: 2000000 / 2100000"
        log "  Sync progress: 95.24%"
        log "  Connections: 8"
        log "  Mempool transactions: 1250"
        return 0
    }
    
    log "Getting node status from $host..."
    
    # Check if we can SSH to the host
    if ! ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes ubuntu@$host "echo SSH connection test" &>/dev/null; then
        log_error "SSH connection not available. Cannot get node status."
        return 1
    fi
    
    # Run the monitor command and capture output
    local status_output=$(ssh -i "$key" -o StrictHostKeyChecking=no ubuntu@$host "/usr/local/bin/chaincheck-monitor" 2>/dev/null)
    
    if [ -z "$status_output" ]; then
        log_warning "Failed to get node status. Monitor script may not be available yet."
        return 1
    fi
    
    log "Node status:"
    echo "$status_output" | while read line; do
        log "  $line"
    done
    
    return 0
}

# Wait for node to be ready (fully synced)
# Arguments:
#   $1 - Host
#   $2 - Key file
#   $3 - Progress threshold (0.0-1.0, default 0.99)
#   $4 - Timeout (seconds, default 86400 - 24 hours)
# Returns:
#   0 - Success, 1 - Failure (timeout)
wait_for_node_ready() {
    local host=$1
    local key=$2
    local threshold=${3:-0.99}
    local timeout=${4:-86400}
    local start_time=$(date +%s)
    local current_time=0
    local elapsed=0
    local check_interval=300 # Check every 5 minutes
    
    if $DRY_RUN; then
        log "DRY RUN: Would wait for node to be ready with sync progress >= $threshold"
        log "DRY RUN: Simulating successful node sync completion"
        return 0
    }
    
    log "Waiting for node to be ready (sync progress >= $threshold)..."
    
    while (( elapsed < timeout )); do
        # Get blockchain info
        local blockchain_info=$(ssh -i "$key" -o StrictHostKeyChecking=no ubuntu@$host "bitcoin-cli -testnet getblockchaininfo 2>/dev/null" 2>/dev/null)
        
        if [ ! -z "$blockchain_info" ]; then
            local progress=$(echo "$blockchain_info" | grep -o '"verificationprogress": [0-9.]*' | cut -d ' ' -f 2)
            local blocks=$(echo "$blockchain_info" | grep -o '"blocks": [0-9]*' | cut -d ' ' -f 2)
            local headers=$(echo "$blockchain_info" | grep -o '"headers": [0-9]*' | cut -d ' ' -f 2)
            
            if [ ! -z "$progress" ] && [ ! -z "$blocks" ] && [ ! -z "$headers" ]; then
                local progress_pct=$(echo "$progress * 100" | bc -l | xargs printf "%.2f")
                log "Sync progress: $progress_pct% (blocks: $blocks, headers: $headers)"
                
                # Check if we've reached the threshold
                if (( $(echo "$progress >= $threshold" | bc -l) )); then
                    log_success "Node is ready! Sync progress has reached $progress_pct%"
                    return 0
                fi
            else
                log_warning "Could not parse blockchain info"
            fi
        else
            log_warning "Failed to get blockchain info"
        fi
        
        # Wait before checking again
        sleep $check_interval
        
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        log "Still waiting for node to be ready... ($elapsed seconds elapsed of $timeout maximum)"
    done
    
    log_warning "Timed out waiting for node to be ready after $timeout seconds"
    return 1
} 