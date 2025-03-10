#!/bin/bash
# facto-deploy/providers/aws/aws_provider.sh - AWS provider implementation

# Source core functionality
BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/../../"
source "$BASE_DIR/core/logging.sh"
source "$BASE_DIR/core/cleanup.sh"
source "$BASE_DIR/core/utils.sh"
source "$BASE_DIR/core/config.sh"
source "$BASE_DIR/core/template.sh"

# Constants
OUTPUT_KEYS_DIR="$BASE_DIR/output/keys"

# Check AWS credentials and tools
# Returns:
#   0 - Success, 1 - Failure
check_aws_credentials() {
    log "Checking AWS credentials..."
    
    # Check for AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install it first."
        return 1
    fi
    
    # Check AWS credentials
    if $DRY_RUN; then
        log "DRY RUN: Skipping AWS credentials verification"
        return 0
    fi
    
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
        log_error "AWS credentials not configured. Please run 'aws configure' first."
        return 1
    fi
    
    log "AWS credentials verified"
    return 0
}

# Create or use existing SSH key pair
# Arguments:
#   $1 - Key name
# Returns:
#   0 - Success, 1 - Failure
create_key_pair() {
    local key_name=$(get_config "KEY_NAME" "facto-key")
    local region=$(get_config "AWS_REGION" "us-east-1")
    local key_file="$OUTPUT_KEYS_DIR/${key_name}.pem"
    
    # Create keys directory if it doesn't exist
    ensure_dir "$OUTPUT_KEYS_DIR"
    
    log "Setting up SSH key pair: $key_name"
    
    if $DRY_RUN; then
        log "DRY RUN: Would create or use key pair: $key_name"
        # In dry run mode, create a dummy key file for testing
        echo "DRY RUN MOCK KEY" > "$key_file"
        chmod 400 "$key_file"
        register_resource "key" "$key_name" "aws"
        set_config "KEY_PATH" "$key_file"
        return 0
    fi
    
    # Check if key pair already exists in AWS
    if aws ec2 describe-key-pairs --key-names "$key_name" --region "$region" &> /dev/null; then
        log "Using existing key pair: $key_name"
        
        # Check if we have the private key locally
        if [ ! -f "$key_file" ]; then
            log_warning "Using existing key pair but private key file $key_file not found locally."
            log_warning "You may need to provide the correct private key file for SSH access."
            return 1
        fi
    else
        log "Creating new key pair: $key_name"
        
        # Create new key pair
        local key_material=$(aws ec2 create-key-pair --key-name "$key_name" --query 'KeyMaterial' --output text --region "$region")
        
        if [ -z "$key_material" ]; then
            log_error "Failed to retrieve key material from AWS"
            return 1
        fi
        
        # Save key to file
        echo "$key_material" > "$key_file"
        
        if [ ! -f "$key_file" ]; then
            log_error "Failed to create key file $key_file"
            return 1
        fi
        
        # Set appropriate permissions
        chmod 400 "$key_file"
        
        # Verify key file
        if [ -r "$key_file" ]; then
            log "Key file verified: $key_file"
            register_resource "key" "$key_name" "aws"
        else
            log_error "Key file $key_file is not readable"
            return 1
        fi
    fi
    
    # Set key path in configuration
    set_config "KEY_PATH" "$key_file"
    
    return 0
}

# Create a security group
# Returns:
#   0 - Success, 1 - Failure
create_security_group() {
    local sg_name=$(get_config "SG_NAME" "facto-sg")
    local region=$(get_config "AWS_REGION" "us-east-1")
    local project=$(get_config "PROJECT_NAME" "facto")
    local env=$(get_config "ENVIRONMENT" "development")
    
    log "Creating security group: $sg_name"
    
    if $DRY_RUN; then
        log "DRY RUN: Would create security group: $sg_name"
        local mock_sg_id="sg-dry-run-12345"
        register_resource "sg" "$mock_sg_id" "aws"
        set_config "SG_ID" "$mock_sg_id"
        
        log "DRY RUN: Would add ingress rules for SSH (22), Bitcoin testnet (18333), and ICMP"
        return 0
    fi
    
    # Check if security group already exists
    local existing_sg=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$sg_name" \
        --query 'SecurityGroups[].GroupId' \
        --output text \
        --region "$region")
    
    if [ ! -z "$existing_sg" ]; then
        log "Deleting existing security group: $existing_sg"
        aws ec2 delete-security-group --group-id "$existing_sg" --region "$region" || true
    fi
    
    # Create security group
    local sg_id=$(aws ec2 create-security-group \
        --group-name "$sg_name" \
        --description "Security group for Facto verification node" \
        --region "$region" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$sg_name},{Key=Project,Value=$project},{Key=Environment,Value=$env}]" \
        --query 'GroupId' --output text)
    
    if [ -z "$sg_id" ]; then
        log_error "Failed to create security group"
        return 1
    fi
    
    log "Created security group: $sg_id"
    register_resource "sg" "$sg_id" "aws"
    
    # Add SSH rule
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --region "$region"
    log "Added SSH ingress rule"
    
    # Add Bitcoin testnet rule
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 18333 \
        --cidr 0.0.0.0/0 \
        --region "$region"
    log "Added Bitcoin testnet ingress rule"
    
    # Allow ICMP for ping
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol icmp \
        --port -1 \
        --cidr 0.0.0.0/0 \
        --region "$region"
    log "Added ICMP ingress rule (for ping)"
    
    # Set security group ID in configuration
    set_config "SG_ID" "$sg_id"
    
    return 0
}

# Launch EC2 instance
# Returns:
#   0 - Success, 1 - Failure
launch_instance() {
    local key_name=$(get_config "KEY_NAME" "facto-key")
    local sg_id=$(get_config "SG_ID")
    local instance_type=$(get_config "INSTANCE_TYPE" "m5.xlarge")
    local volume_size=$(get_config "VOLUME_SIZE" "500")
    local region=$(get_config "AWS_REGION" "us-east-1")
    local instance_name=$(get_config "INSTANCE_NAME" "facto-node")
    local project=$(get_config "PROJECT_NAME" "facto")
    local env=$(get_config "ENVIRONMENT" "development")
    local node_type=$(get_config "NODE_TYPE" "bitcoin")
    
    # Get user data script path
    local user_data_script=$(get_user_data_script "aws" "$node_type")
    
    log "Launching EC2 instance: $instance_name"
    log "Using user data script: $user_data_script"
    
    if $DRY_RUN; then
        log "DRY RUN: Would launch EC2 instance with the following parameters:"
        log "  - Instance type: $instance_type"
        log "  - Key name: $key_name"
        log "  - Security group: $sg_id"
        log "  - Volume size: $volume_size GB"
        log "  - Region: $region"
        log "  - User data script: $user_data_script"
        
        local mock_instance_id="i-dry-run-12345"
        local mock_public_ip="192.0.2.123" # Using TEST-NET-1 IP for simulation
        
        register_resource "instance" "$mock_instance_id" "aws"
        set_config "INSTANCE_ID" "$mock_instance_id"
        set_config "PUBLIC_IP" "$mock_public_ip"
        
        log "DRY RUN: Would tag EBS volumes"
        return 0
    fi
    
    # Common tags
    local common_tags="ResourceType=instance,Tags=[{Key=Name,Value=$instance_name},{Key=Project,Value=$project},{Key=Environment,Value=$env}]"
    
    # Launch instance
    local instance_id=$(aws ec2 run-instances \
        --image-id ami-0c7217cdde317cfec \
        --instance-type "$instance_type" \
        --key-name "$key_name" \
        --security-group-ids "$sg_id" \
        --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$volume_size,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
        --user-data "file://$user_data_script" \
        --region "$region" \
        --tag-specifications "$common_tags" \
        --query 'Instances[0].InstanceId' \
        --output text)
    
    if [ -z "$instance_id" ]; then
        log_error "Failed to launch instance"
        return 1
    fi
    
    log "Created instance: $instance_id"
    register_resource "instance" "$instance_id" "aws"
    
    # Set instance ID in configuration
    set_config "INSTANCE_ID" "$instance_id"
    
    # Wait for instance to start
    log "Waiting for instance to start..."
    aws ec2 wait instance-running --instance-ids "$instance_id" --region "$region"
    log "Instance is now running"
    
    # Get public IP
    local public_ip=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text \
        --region "$region")
    
    log "Instance public IP: $public_ip"
    set_config "PUBLIC_IP" "$public_ip"
    
    # Tag EBS volumes
    log "Tagging EBS volumes..."
    local volume_ids=$(aws ec2 describe-volumes \
        --filters "Name=attachment.instance-id,Values=$instance_id" \
        --query "Volumes[*].VolumeId" \
        --output text \
        --region "$region")
    
    for volume_id in $volume_ids; do
        log "Tagging volume: $volume_id"
        aws ec2 create-tags \
            --resources "$volume_id" \
            --tags "Key=Name,Value=facto-volume" "Key=Project,Value=$project" \
            --region "$region"
    done
    
    return 0
}

# Main AWS provision function
# Arguments:
#   $1 - Node type (bitcoin, ethereum, etc.)
# Returns:
#   0 - Success, 1 - Failure
provision_aws() {
    local node_type=${1:-bitcoin}
    
    # Set AWS defaults
    set_defaults "aws"
    
    # Override with node-specific settings
    set_config "NODE_TYPE" "$node_type"
    
    # Check requirements
    check_requirements "aws" "ssh" "jq" "ping" "nc" || return 1
    
    # Check AWS credentials
    check_aws_credentials || return 1
    
    # Process templates
    process_templates "aws" "$node_type" || return 1
    
    # Create key pair
    create_key_pair || return 1
    
    # Create security group
    create_security_group || return 1
    
    # Launch instance
    launch_instance || return 1
    
    log_success "AWS provisioning completed successfully"
    return 0
}

# AWS cleanup function - registered as cleanup hook
aws_cleanup() {
    local region=$(get_config "AWS_REGION" "us-east-1")
    
    # Get resources to clean up
    local instance_id=$(get_resource "instance" "aws")
    local sg_id=$(get_resource "sg" "aws")
    local key_name=$(get_resource "key" "aws")
    
    if $DRY_RUN; then
        log "DRY RUN: Would clean up the following resources:"
        [ ! -z "$instance_id" ] && log "  - Instance: $instance_id"
        [ ! -z "$sg_id" ] && log "  - Security Group: $sg_id"
        [ ! -z "$key_name" ] && log "  - Key Pair: $key_name"
        return 0
    fi
    
    # Terminate instance if created
    if [ ! -z "$instance_id" ]; then
        log "Terminating instance $instance_id..."
        aws ec2 terminate-instances --instance-ids "$instance_id" --region "$region"
        log "Waiting for instance termination..."
        aws ec2 wait instance-terminated --instance-ids "$instance_id" --region "$region"
    fi
    
    # Delete security group if created
    if [ ! -z "$sg_id" ]; then
        log "Deleting security group $sg_id..."
        aws ec2 delete-security-group --group-id "$sg_id" --region "$region" || log "Failed to delete security group"
    fi
    
    # Delete key pair if created
    if [ ! -z "$key_name" ]; then
        log "Deleting key pair $key_name..."
        aws ec2 delete-key-pair --key-name "$key_name" --region "$region"
    fi
}

# Register the AWS cleanup function as the cleanup hook
set_cleanup_hook aws_cleanup 