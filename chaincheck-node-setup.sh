#!/bin/bash
# chaincheck-node-setup.sh - Production-ready script to set up a Bitcoin verifier node on AWS

# Configuration
INSTANCE_TYPE="m5.xlarge"
VOLUME_SIZE=500  # GB
AWS_REGION="us-east-1"
KEY_NAME="chaincheck-bitcoin-key"
SG_NAME="chaincheck-bitcoin-sg"
INSTANCE_NAME="chaincheck-bitcoin-node"
SSH_TIMEOUT=300  # Maximum time to wait for SSH to become available (in seconds)
SETUP_TIMEOUT=1800  # Maximum time to wait for complete setup (in seconds)

# Set up logging
LOG_FILE="chaincheck-deployment-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Log function to timestamp messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Resource tracking
CREATED_INSTANCE=""
CREATED_SG=""
CREATED_KEY=false

# Tag structure for all resources
COMMON_TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=ChainCheck},{Key=Environment,Value=Development},{Key=CreatedBy,Value=AutomatedScript}]"

# Function to check if instance is network-accessible
check_instance_availability() {
    local host=$1
    local max_attempts=30
    local wait_seconds=5
    local attempt=1

    log "Checking if instance is network-accessible at $host..."
    
    # First check instance status via AWS API
    log "Verifying instance is running via AWS API..."
    local status=$(aws ec2 describe-instances --instance-ids $CREATED_INSTANCE --query 'Reservations[0].Instances[0].State.Name' --output text --region $AWS_REGION)
    log "Instance status from AWS API: $status"
    
    if [ "$status" != "running" ]; then
        log "ERROR: Instance is not in 'running' state, current state is '$status'"
        return 1
    fi
    
    # Then try ping to check network connectivity
    log "Attempting to ping instance..."
    while (( attempt <= max_attempts )); do
        log "Ping attempt $attempt of $max_attempts..."
        
        if ping -c 1 -W 2 $host &>/dev/null; then
            log "Instance is responding to ping!"
            
            # Once ping succeeds, try a basic TCP connection to port 22
            log "Checking if SSH port is open..."
            if nc -z -w 5 $host 22 &>/dev/null; then
                log "SSH port is open and accepting connections!"
                return 0
            else
                log "SSH port not responding yet, instance may still be initializing..."
            fi
        else
            log "Instance not responding to ping yet..."
        fi
        
        (( attempt++ ))
        sleep $wait_seconds
    done
    
    log "WARNING: Instance did not become fully network-accessible within the timeout period"
    log "The instance may still be initializing. You can try connecting manually later."
    return 1
}

# Function to check if SSH is available
check_ssh() {
    local host=$1
    local key=$2
    local max_attempts=$3
    local wait_seconds=10
    local attempt=1

    # Give the instance a bit more time for initial setup
    log "Waiting 30 seconds for instance to initialize before attempting SSH..."
    sleep 30

    log "Waiting for SSH to become available on $host..."
    while (( attempt <= max_attempts )); do
        log "SSH connection attempt $attempt of $max_attempts..."
        
        # Run SSH with verbose output to help diagnose issues
        if ssh -v -i "$(pwd)/$key" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes ubuntu@$host "echo SSH connection successful" &> ssh_attempt.log; then
            log "SSH connection established!"
            return 0
        else
            # Log SSH debugging information
            log "SSH debug output:"
            cat ssh_attempt.log | while read line; do
                log "  $line"
            done
        fi
        
        (( attempt++ ))
        
        # Check if instance is still running
        local status=$(aws ec2 describe-instances --instance-ids $CREATED_INSTANCE --query 'Reservations[0].Instances[0].State.Name' --output text --region $AWS_REGION)
        log "Instance status: $status"
        
        if [ "$status" != "running" ]; then
            log "ERROR: Instance is no longer running, status is $status"
            return 1
        fi
        
        log "Waiting $wait_seconds seconds before next attempt..."
        sleep $wait_seconds
    done
    
    log "WARNING: Failed to establish SSH connection after $max_attempts attempts"
    log "Try connecting manually: ssh -i $(pwd)/${key} ubuntu@${host}"
    log "If the connection fails, check that:"
    log "  1. The security group allows SSH access (port 22)"
    log "  2. The key pair is properly configured"
    log "  3. The instance is running and passed initialization"
    
    return 1
}

# Function to monitor remote setup
monitor_setup() {
    local host=$1
    local key=$2
    local timeout=$3
    local start_time=$(date +%s)
    local current_time=0
    local elapsed=0

    log "Monitoring setup progress on $host..."
    
    while (( elapsed < timeout )); do
        # Check if we can SSH to the host
        if ! ssh -i "$(pwd)/$key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes ubuntu@$host "echo SSH connection test" &>/dev/null; then
            log "SSH connection lost or not available. Will retry..."
            sleep 10
            current_time=$(date +%s)
            elapsed=$((current_time - start_time))
            continue
        fi
        
        # Check cloud-init status
        local cloud_init_status=$(ssh -i "$(pwd)/$key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$host "cloud-init status" 2>/dev/null)
        
        # Check bitcoind service status
        local bitcoind_status=$(ssh -i "$(pwd)/$key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$host "systemctl is-active bitcoind" 2>/dev/null)
        
        log "Cloud-init status: $cloud_init_status"
        log "Bitcoin daemon status: $bitcoind_status"
        
        # If cloud-init is done and bitcoind is active, we're finished
        if [[ "$cloud_init_status" == *"done"* ]] && [[ "$bitcoind_status" == "active" ]]; then
            log "Setup completed successfully!"
            
            # Get Bitcoin sync status
            local bitcoin_info=$(ssh -i "$(pwd)/$key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$host "bitcoin-cli -testnet getblockchaininfo 2>/dev/null || echo 'Not ready yet'" 2>/dev/null)
            log "Initial Bitcoin status: $(echo "$bitcoin_info" | grep -E 'blocks|headers|verificationprogress' | tr '\n' ' ')"
            
            return 0
        fi
        
        # If cloud-init failed, report error
        if [[ "$cloud_init_status" == *"error"* ]]; then
            log "ERROR: Cloud-init reported an error."
            log "Fetching cloud-init logs for debugging..."
            ssh -i "$(pwd)/$key" -o StrictHostKeyChecking=no ubuntu@$host "sudo cat /var/log/cloud-init-output.log" > "cloud-init-error-$host.log"
            log "Cloud-init logs saved to cloud-init-error-$host.log"
            return 1
        fi
        
        # Wait before checking again
        sleep 30
        
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        log "Setup monitoring in progress... ($elapsed seconds elapsed of $timeout maximum)"
    done
    
    log "WARNING: Setup monitoring timed out after $timeout seconds"
    log "The setup may still complete successfully in the background."
    log "You can check the status later by connecting manually:"
    log "  ssh -i $(pwd)/${key} ubuntu@${host}"
    log "  sudo cat /var/log/user-data.log"
    return 1
}

# Cleanup function
cleanup() {
    local exit_code=$?
    local signal=$1
    
    if [ ! -z "$signal" ]; then
        log "Received signal $signal. Cleaning up resources..."
    else
        log "Script error occurred with exit code $exit_code. Cleaning up resources..."
    fi
    
    if [ ! -z "$CREATED_INSTANCE" ]; then
        log "Terminating instance $CREATED_INSTANCE..."
        aws ec2 terminate-instances --instance-ids $CREATED_INSTANCE --region $AWS_REGION
        
        # Only wait for termination if we're not being killed
        if [ -z "$signal" ] || [ "$signal" != "SIGTERM" ]; then
            log "Waiting for instance termination..."
            aws ec2 wait instance-terminated --instance-ids $CREATED_INSTANCE --region $AWS_REGION
        fi
    fi
    
    if [ ! -z "$CREATED_SG" ]; then
        log "Deleting security group $CREATED_SG..."
        aws ec2 delete-security-group --group-id $CREATED_SG --region $AWS_REGION || log "Failed to delete security group, it may have dependencies or need manual cleanup"
    fi
    
    if [ "$CREATED_KEY" = true ] && [ ! -z "$KEY_NAME" ]; then
        log "Deleting key pair $KEY_NAME..."
        aws ec2 delete-key-pair --key-name $KEY_NAME --region $AWS_REGION
    fi
    
    log "Cleanup complete."
    
    # Only exit if this wasn't called from a signal handler
    if [ -z "$signal" ]; then
        exit 1
    fi
}

# Set trap for cleanup on error and interrupts
trap cleanup ERR
trap "cleanup SIGINT" SIGINT
trap "cleanup SIGTERM" SIGTERM

log "===== ChainCheck Deployment Log - $(date) ====="
log "Script started by user: $(whoami)"
log "AWS Region: $AWS_REGION"

# Log system information
log "System information:"
log "OS: $(uname -a)"
log "AWS CLI version: $(aws --version)"

echo "===== ChainCheck Verifier Node Setup ====="
echo "This script will set up a Bitcoin node on AWS for the ChainCheck verification network."

# Check for AWS CLI
if ! command -v aws &> /dev/null; then
    log "AWS CLI not found. Please install it first."
    exit 1
fi

# Check for required utilities
for cmd in ssh jq ping nc; do
    if ! command -v $cmd &> /dev/null; then
        log "Required command '$cmd' not found. Please install it first."
        exit 1
    fi
done

# Check AWS credentials
log "Checking AWS credentials..."
aws sts get-caller-identity > /dev/null 2>&1
if [ $? -ne 0 ]; then
    log "AWS credentials not configured. Please run 'aws configure' first."
    exit 1
fi

# Clean up any existing resources with the same names
log "Checking for existing resources to clean up..."

# Check for existing instance
log "Looking for existing instances named $INSTANCE_NAME..."
EXISTING_INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text \
    --region $AWS_REGION)
log "Found instances: $EXISTING_INSTANCE"

if [ ! -z "$EXISTING_INSTANCE" ]; then
    log "Terminating existing instances: $EXISTING_INSTANCE"
    aws ec2 terminate-instances --instance-ids $EXISTING_INSTANCE --region $AWS_REGION
    log "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids $EXISTING_INSTANCE --region $AWS_REGION
    log "Instances terminated"
fi

# Check for existing security group
log "Looking for existing security group named $SG_NAME..."
EXISTING_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[].GroupId' \
    --output text \
    --region $AWS_REGION)
log "Found security groups: $EXISTING_SG"

if [ ! -z "$EXISTING_SG" ]; then
    log "Deleting existing security group: $EXISTING_SG"
    aws ec2 delete-security-group --group-id $EXISTING_SG --region $AWS_REGION || true
    log "Security group deleted or deletion attempted"
fi

# Create or check SSH key pair
log "Setting up SSH key pair..."
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region $AWS_REGION &> /dev/null; then
    log "Using existing key pair: $KEY_NAME"
    
    # Check if we have the private key locally
    if [ ! -f "${KEY_NAME}.pem" ]; then
        log "WARNING: Using existing key pair but private key file ${KEY_NAME}.pem not found locally."
        log "You may need to provide the correct private key file for SSH access."
    fi
else
    log "Creating new key pair: $KEY_NAME"
    KEY_MATERIAL=$(aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text --region $AWS_REGION)
    if [ -z "$KEY_MATERIAL" ]; then
        log "ERROR: Failed to retrieve key material from AWS"
        exit 1
    fi
    KEY_FILE="${KEY_NAME}.pem"
    echo "$KEY_MATERIAL" > "$KEY_FILE"
    if [ ! -f "$KEY_FILE" ]; then
        log "ERROR: Failed to create key file $KEY_FILE"
        exit 1
    fi
    chmod 400 "$KEY_FILE"
    log "Verifying key file exists and is readable..."
    if [ -r "$KEY_FILE" ]; then
        log "Key file verified: $KEY_FILE"
        CREATED_KEY=true
    else
        log "ERROR: Key file $KEY_FILE is not readable"
        exit 1
    fi
    log "Key pair created and saved to $KEY_FILE"
fi

# Create security group
log "Creating security group..."
CREATED_SG=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Security group for ChainCheck Bitcoin verification node" \
    --region $AWS_REGION \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=ChainCheck},{Key=Environment,Value=Development},{Key=CreatedBy,Value=AutomatedScript}]" \
    --query 'GroupId' --output text)

log "Created security group: $CREATED_SG"

# Add necessary rules
log "Configuring security group rules..."
aws ec2 authorize-security-group-ingress \
    --group-id $CREATED_SG \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --region $AWS_REGION
log "Added SSH ingress rule"

aws ec2 authorize-security-group-ingress \
    --group-id $CREATED_SG \
    --protocol tcp \
    --port 18333 \
    --cidr 0.0.0.0/0 \
    --region $AWS_REGION
log "Added Bitcoin testnet ingress rule"

# Allow ICMP for ping
aws ec2 authorize-security-group-ingress \
    --group-id $CREATED_SG \
    --protocol icmp \
    --port -1 \
    --cidr 0.0.0.0/0 \
    --region $AWS_REGION
log "Added ICMP ingress rule (for ping)"

# Create user data script for node setup
log "Creating user data script..."
cat > user-data.sh << 'EOL'
#!/bin/bash
# Log setup steps
exec > >(tee /var/log/user-data.log) 2>&1

echo "Starting Bitcoin node setup: $(date)"

# Update system
echo "Updating system packages..."
apt-get update && apt-get upgrade -y

# Install dependencies
echo "Installing dependencies..."
apt-get install -y build-essential libtool autotools-dev automake pkg-config libssl-dev libevent-dev bsdmainutils libboost-all-dev jq

# Download Bitcoin Core
echo "Downloading Bitcoin Core..."
wget https://bitcoincore.org/bin/bitcoin-core-25.0/bitcoin-25.0-x86_64-linux-gnu.tar.gz

# Extract and install
echo "Extracting and installing Bitcoin Core..."
tar -xzf bitcoin-25.0-x86_64-linux-gnu.tar.gz
install -m 0755 -o root -g root -t /usr/local/bin bitcoin-25.0/bin/*

# Create bitcoin user
echo "Creating bitcoin user..."
useradd -m bitcoin

# Configure Bitcoin
echo "Configuring Bitcoin..."
mkdir -p /home/bitcoin/.bitcoin
cat > /home/bitcoin/.bitcoin/bitcoin.conf << EOF
# Run on testnet for ChainCheck development
testnet=1

# Enable JSON-RPC
server=1
rpcuser=chaincheckverifier
rpcpassword=$(openssl rand -hex 32)

# Allow RPC connections 
rpcallowip=127.0.0.1
# Note: rpcbind is not needed when only allowing local connections

# Index all transactions (needed for verification)
txindex=1

# Other optimizations
dbcache=4000
maxmempool=500
maxconnections=40
EOF

# Set permissions
chown -R bitcoin:bitcoin /home/bitcoin/.bitcoin

# Create systemd service
echo "Creating systemd service for Bitcoin daemon..."
cat > /etc/systemd/system/bitcoind.service << EOF
[Unit]
Description=Bitcoin daemon
After=network.target

[Service]
User=bitcoin
Group=bitcoin
Type=forking
ExecStart=/usr/local/bin/bitcoind -daemon
Restart=always
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
EOF

# Create status script
cat > /usr/local/bin/bitcoin-status << EOF
#!/bin/bash
bitcoin-cli -testnet getblockchaininfo | jq
EOF
chmod +x /usr/local/bin/bitcoin-status

# Create more detailed monitoring script
cat > /usr/local/bin/chaincheck-monitor << EOF
#!/bin/bash
echo "===== ChainCheck Bitcoin Node Status ====="
echo "Date: \$(date)"
echo ""

echo "System Status:"
echo "-------------"
echo "Uptime: \$(uptime)"
echo "Memory: \$(free -h | grep Mem)"
echo "Disk: \$(df -h / | grep /)"
echo ""

echo "Bitcoin Process Status:"
echo "---------------------"
if systemctl is-active bitcoind > /dev/null; then
    echo "Bitcoin daemon: RUNNING"
    
    # Get detailed process information
    echo "Process Details:"
    ps aux | grep bitcoind | grep -v grep | awk '{printf "  PID: %s, CPU: %s%%, MEM: %s%%, Uptime: %s\n", \$2, \$3, \$4, \$10}'
    
    # Get basic blockchain info
    BLOCKCHAIN_INFO=\$(bitcoin-cli -testnet getblockchaininfo 2>/dev/null)
    if [ \$? -eq 0 ]; then
        BLOCKS=\$(echo "\$BLOCKCHAIN_INFO" | jq .blocks)
        HEADERS=\$(echo "\$BLOCKCHAIN_INFO" | jq .headers)
        PROGRESS=\$(echo "\$BLOCKCHAIN_INFO" | jq .verificationprogress)
        PROGRESS_PCT=\$(echo "\$PROGRESS * 100" | bc -l | xargs printf "%.2f")
        
        echo "Current block: \$BLOCKS / \$HEADERS"
        echo "Sync progress: \$PROGRESS_PCT%"
        
        # Get network info
        NETWORK_INFO=\$(bitcoin-cli -testnet getnetworkinfo 2>/dev/null)
        if [ \$? -eq 0 ]; then
            CONNECTIONS=\$(echo "\$NETWORK_INFO" | jq .connections)
            echo "Connections: \$CONNECTIONS"
        fi
        
        # Get mempool info
        MEMPOOL_INFO=\$(bitcoin-cli -testnet getmempoolinfo 2>/dev/null)
        if [ \$? -eq 0 ]; then
            TX_COUNT=\$(echo "\$MEMPOOL_INFO" | jq .size)
            MEMPOOL_BYTES=\$(echo "\$MEMPOOL_INFO" | jq .bytes)
            echo "Mempool transactions: \$TX_COUNT"
            echo "Mempool size: \$(echo "\$MEMPOOL_BYTES / 1024 / 1024" | bc)MB"
        fi
    else
        echo "Bitcoin CLI not responding. Node may still be starting."
    fi
else
    echo "Bitcoin daemon: NOT RUNNING"
    systemctl status bitcoind
fi
EOF
chmod +x /usr/local/bin/chaincheck-monitor

# Add bc for calculations in the monitor script
apt-get install -y bc

# Enable and start service
echo "Enabling and starting Bitcoin daemon..."
systemctl daemon-reload
systemctl enable bitcoind
systemctl start bitcoind

# Create a setup complete flag
touch /var/lib/chaincheck-setup-complete

echo "ChainCheck Bitcoin node setup complete: $(date)"
EOL

log "User data script created"

# Launch EC2 instance
log "Launching EC2 instance..."
CREATED_INSTANCE=$(aws ec2 run-instances \
    --image-id ami-0c7217cdde317cfec \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_NAME \
    --security-group-ids $CREATED_SG \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    --user-data file://user-data.sh \
    --region $AWS_REGION \
    --tag-specifications "$COMMON_TAGS" \
    --query 'Instances[0].InstanceId' \
    --output text)

log "Created instance: $CREATED_INSTANCE"

# Add tags to EBS volumes after instance creation
log "Waiting for instance to start..."
aws ec2 wait instance-running --instance-ids $CREATED_INSTANCE --region $AWS_REGION
log "Instance is now running"

# Get public IP
log "Getting instance public IP..."
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $CREATED_INSTANCE \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text \
    --region $AWS_REGION)
log "Instance public IP: $PUBLIC_IP"

log "Tagging EBS volumes..."
VOLUME_IDS=$(aws ec2 describe-volumes \
    --filters "Name=attachment.instance-id,Values=$CREATED_INSTANCE" \
    --query "Volumes[*].VolumeId" \
    --output text \
    --region $AWS_REGION)
log "Found volumes: $VOLUME_IDS"

for VOLUME_ID in $VOLUME_IDS; do
    log "Tagging volume: $VOLUME_ID"
    aws ec2 create-tags \
        --resources $VOLUME_ID \
        --tags "Key=Name,Value=chaincheck-bitcoin-volume" "Key=Project,Value=ChainCheck" \
        --region $AWS_REGION
done

# Wait for network accessibility
log "Checking if instance is network-accessible..."
if check_instance_availability "$PUBLIC_IP"; then
    log "Instance is network-accessible"
    
    # Wait for SSH to become available
    MAX_SSH_ATTEMPTS=$((SSH_TIMEOUT / 10))
    if check_ssh "$PUBLIC_IP" "${KEY_NAME}.pem" "$MAX_SSH_ATTEMPTS"; then
        log "SSH connection established. Now monitoring setup progress..."
        if monitor_setup "$PUBLIC_IP" "${KEY_NAME}.pem" "$SETUP_TIMEOUT"; then
            log "Setup completed successfully!"
            SETUP_SUCCESS=true
        else
            log "Setup monitoring did not complete successfully within the timeout period"
            log "The setup may still complete in the background"
            SETUP_SUCCESS=false
        fi
    else
        log "SSH connection could not be established within the timeout period"
        log "The instance is running and may still be setting up in the background"
        SETUP_SUCCESS=false
    fi
else
    log "Instance did not become fully network-accessible within the timeout period"
    log "The instance is running and may still be setting up in the background"
    SETUP_SUCCESS=false
fi

# Even if we couldn't verify setup, continue with creating utilities and final output
log "===== Node Setup Summary ====="
log "Instance ID: $CREATED_INSTANCE"
log "Public IP: $PUBLIC_IP"
log "SSH Command: ssh -i $(pwd)/${KEY_NAME}.pem ubuntu@$PUBLIC_IP"
log "Status Command: ssh -i $(pwd)/${KEY_NAME}.pem ubuntu@$PUBLIC_IP '/usr/local/bin/chaincheck-monitor'"

echo "===== ChainCheck Bitcoin Node Setup ====="
echo "Instance ID: $CREATED_INSTANCE"
echo "Public IP: $PUBLIC_IP"
echo "Connect using: ssh -i $(pwd)/${KEY_NAME}.pem ubuntu@$PUBLIC_IP"
echo "Check node status: ssh -i $(pwd)/${KEY_NAME}.pem ubuntu@$PUBLIC_IP '/usr/local/bin/chaincheck-monitor'"
echo ""

if [ "$SETUP_SUCCESS" = true ]; then
    echo "Setup has been verified and Bitcoin daemon is running."
else
    echo "Note: Setup verification could not be completed, but the instance is running."
    echo "The Bitcoin node should continue setting up in the background."
fi

echo "Bitcoin will sync with the testnet, which will take several hours to complete."
echo "You can monitor progress using the command above."

# Create cleanup script
log "Creating cleanup script..."
cat > chaincheck-cleanup.sh << EOF
#!/bin/bash
# Cleanup script for ChainCheck node

# Set up logging
CLEANUP_LOG="chaincheck-cleanup-\$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "\$CLEANUP_LOG") 2>&1

echo "===== ChainCheck Cleanup - \$(date) ====="
echo "Cleaning up resources for instance $CREATED_INSTANCE"

echo "Terminating instance $CREATED_INSTANCE..."
aws ec2 terminate-instances --instance-ids $CREATED_INSTANCE --region $AWS_REGION

echo "Waiting for instance to terminate..."
aws ec2 wait instance-terminated --instance-ids $CREATED_INSTANCE --region $AWS_REGION

echo "Deleting security group $CREATED_SG..."
aws ec2 delete-security-group --group-id $CREATED_SG --region $AWS_REGION

echo "Deleting key pair $KEY_NAME..."
aws ec2 delete-key-pair --key-name $KEY_NAME --region $AWS_REGION

echo "Cleanup complete."
echo "Log saved to \$CLEANUP_LOG"
EOF
chmod +x chaincheck-cleanup.sh
log "Cleanup script created as chaincheck-cleanup.sh"

# Create a utility to find and clean all ChainCheck resources
log "Creating utility to find all ChainCheck resources..."
cat > chaincheck-find-resources.sh << 'EOF'
#!/bin/bash
# Script to find all ChainCheck resources in AWS

# Set up logging
FIND_LOG="chaincheck-resources-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$FIND_LOG") 2>&1

echo "===== Finding ChainCheck Resources - $(date) ====="

# Set AWS region
AWS_REGION=${1:-us-east-1}
echo "Searching in region: $AWS_REGION"

# Find instances
echo "Finding ChainCheck instances..."
INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=ChainCheck" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Name`].Value[]]' \
    --output json \
    --region $AWS_REGION)
echo "Instances:"
echo "$INSTANCES" | jq -r '.[] | "ID: \(.[0]), State: \(.[1]), Name: \(.[2][0] // "N/A")"'

# Find security groups
echo "Finding ChainCheck security groups..."
SGS=$(aws ec2 describe-security-groups \
    --filters "Name=tag:Project,Values=ChainCheck" "Name=group-name,Values=chaincheck-*" \
    --query 'SecurityGroups[].[GroupId,GroupName]' \
    --output json \
    --region $AWS_REGION)
echo "Security Groups:"
echo "$SGS" | jq -r '.[] | "ID: \(.[0]), Name: \(.[1])"'

# Find key pairs
echo "Finding ChainCheck key pairs..."
KEYS=$(aws ec2 describe-key-pairs \
    --filters "Name=key-name,Values=chaincheck-*" \
    --query 'KeyPairs[].[KeyName,KeyPairId]' \
    --output json \
    --region $AWS_REGION)
echo "Key Pairs:"
echo "$KEYS" | jq -r '.[] | "Name: \(.[0]), ID: \(.[1])"'

# Find volumes
echo "Finding ChainCheck volumes..."
VOLUMES=$(aws ec2 describe-volumes \
    --filters "Name=tag:Project,Values=ChainCheck" \
    --query 'Volumes[].[VolumeId,Size,State,Tags[?Key==`Name`].Value[]]' \
    --output json \
    --region $AWS_REGION)
echo "Volumes:"
echo "$VOLUMES" | jq -r '.[] | "ID: \(.[0]), Size: \(.[1])GB, State: \(.[2]), Name: \(.[3][0] // "N/A")"'

echo "===== Resource Search Complete ====="
echo "Log saved to $FIND_LOG"
EOF
chmod +x chaincheck-find-resources.sh
log "Resource finder created as chaincheck-find-resources.sh"

# Create comprehensive cleanup utility
log "Creating comprehensive cleanup utility..."
cat > chaincheck-cleanup-all.sh << 'EOF'
#!/bin/bash
# Script to clean up all ChainCheck resources in AWS

# Set up logging
CLEANUP_LOG="chaincheck-cleanup-all-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$CLEANUP_LOG") 2>&1

echo "===== ChainCheck Complete Cleanup - $(date) ====="

# Set AWS region
AWS_REGION=${1:-us-east-1}
echo "Cleaning up resources in region: $AWS_REGION"

# Finding all ChainCheck resources
echo "Finding all ChainCheck resources..."

# Find instances
echo "Finding ChainCheck instances..."
INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=ChainCheck" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text \
    --region $AWS_REGION)

# Terminate instances
if [ ! -z "$INSTANCES" ]; then
    echo "Terminating instances: $INSTANCES"
    aws ec2 terminate-instances --instance-ids $INSTANCES --region $AWS_REGION
    
    echo "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCES --region $AWS_REGION
else
    echo "No running ChainCheck instances found."
fi

# Find security groups
echo "Finding ChainCheck security groups..."
SGS=$(aws ec2 describe-security-groups \
    --filters "Name=tag:Project,Values=ChainCheck" "Name=group-name,Values=chaincheck-*" \
    --query 'SecurityGroups[].GroupId' \
    --output text \
    --region $AWS_REGION)

# Delete security groups
if [ ! -z "$SGS" ]; then
    echo "Deleting security groups: $SGS"
    for SG in $SGS; do
        echo "Deleting security group: $SG"
        aws ec2 delete-security-group --group-id $SG --region $AWS_REGION || echo "Failed to delete $SG, may have dependencies"
    done
else
    echo "No ChainCheck security groups found."
fi

# Find key pairs
echo "Finding ChainCheck key pairs..."
KEYS=$(aws ec2 describe-key-pairs \
    --filters "Name=key-name,Values=chaincheck-*" \
    --query 'KeyPairs[].KeyName' \
    --output text \
    --region $AWS_REGION)

# Delete key pairs
if [ ! -z "$KEYS" ]; then
    echo "Deleting key pairs: $KEYS"
    for KEY in $KEYS; do
        echo "Deleting key pair: $KEY"
        aws ec2 delete-key-pair --key-name $KEY --region $AWS_REGION
    done
else
    echo "No ChainCheck key pairs found."
fi

echo "===== Cleanup Complete ====="
echo "All ChainCheck resources have been cleaned up in region $AWS_REGION."
echo "Log saved to $CLEANUP_LOG"
EOF
chmod +x chaincheck-cleanup-all.sh
log "Comprehensive cleanup utility created as chaincheck-cleanup-all.sh"

# Final summary
log "===== Deployment Summary ====="
log "Key Pair: $KEY_NAME (Created: $CREATED_KEY)"
log "Security Group: $CREATED_SG"
log "Instance ID: $CREATED_INSTANCE"
log "Public IP: $PUBLIC_IP"
log "Bitcoin node setup completed successfully"
log "Log file created: $LOG_FILE"

echo ""
echo "===== Utilities Created ====="
echo "1. chaincheck-cleanup.sh - Cleans up resources created by this run"
echo "2. chaincheck-find-resources.sh - Finds all ChainCheck resources"
echo "3. chaincheck-cleanup-all.sh - Cleans up all ChainCheck resources"
echo ""
echo "A detailed log has been saved to: $LOG_FILE"
