#!/bin/bash
# facto-deploy/deploy.sh - Main deployment script for Facto nodes

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source core functionality
source "$SCRIPT_DIR/core/logging.sh"
source "$SCRIPT_DIR/core/cleanup.sh"
source "$SCRIPT_DIR/core/utils.sh"
source "$SCRIPT_DIR/core/config.sh"
source "$SCRIPT_DIR/core/template.sh"

# Initialize logging
init_logging "facto-deploy"

# Setup error traps
setup_error_traps

# Usage information
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -p, --provider PROVIDER    Cloud provider (aws, gcp, azure)"
    echo "  -t, --type NODE_TYPE       Node type (bitcoin)"
    echo "  -c, --config CONFIG_FILE   Configuration file"
    echo "  -r, --region REGION        Cloud provider region"
    echo "  -i, --instance-type TYPE   Instance type/size"
    echo "  -v, --volume-size SIZE     Volume size in GB"
    echo "  -n, --name NAME            Instance name"
    echo "  -d, --dry-run              Dry run mode (no resources created)"
    echo "  -h, --help                 Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --provider aws --type bitcoin --region us-east-1 --instance-type m5.xlarge --volume-size 500 --name facto-btc-node"
    echo ""
    echo "Dry run example:"
    echo "  $0 --provider aws --type bitcoin --dry-run"
    echo ""
}

# Process command-line arguments
process_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--provider)
                set_config "PROVIDER" "$2"
                shift 2
                ;;
            -t|--type)
                set_config "NODE_TYPE" "$2"
                shift 2
                ;;
            -c|--config)
                local config_file="$2"
                if [ ! -f "$config_file" ]; then
                    log_error "Configuration file not found: $config_file"
                    exit 1
                fi
                load_config_file "$config_file"
                shift 2
                ;;
            -r|--region)
                case "$(get_config "PROVIDER")" in
                    aws)
                        set_config "AWS_REGION" "$2"
                        ;;
                    gcp)
                        set_config "GCP_REGION" "$2"
                        ;;
                    azure)
                        set_config "AZURE_REGION" "$2"
                        ;;
                    *)
                        log_error "Provider must be specified before region"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            -i|--instance-type)
                case "$(get_config "PROVIDER")" in
                    aws)
                        set_config "INSTANCE_TYPE" "$2"
                        ;;
                    gcp)
                        set_config "MACHINE_TYPE" "$2"
                        ;;
                    azure)
                        set_config "VM_SIZE" "$2"
                        ;;
                    *)
                        log_error "Provider must be specified before instance type"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            -v|--volume-size)
                set_config "VOLUME_SIZE" "$2"
                shift 2
                ;;
            -n|--name)
                set_config "INSTANCE_NAME" "$2"
                shift 2
                ;;
            -d|--dry-run)
                set_dry_run true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Validate required configuration
validate_required_config() {
    local provider=$(get_config "PROVIDER")
    if [ -z "$provider" ]; then
        log_error "Provider is required"
        usage
        exit 1
    fi
    
    local node_type=$(get_config "NODE_TYPE")
    if [ -z "$node_type" ]; then
        log_error "Node type is required"
        usage
        exit 1
    fi
    
    # Add timestamp to configuration
    set_config "CREATION_DATE" "$(date)"
    
    # Validate provider-specific requirements
    case "$provider" in
        aws)
            # Source AWS provider module
            source "$SCRIPT_DIR/providers/aws/aws_provider.sh"
            source "$SCRIPT_DIR/providers/aws/aws_monitor.sh"
            
            # Load AWS-specific defaults if not set
            if [ -z "$(get_config "AWS_REGION")" ]; then
                set_config "AWS_REGION" "us-east-1"
            fi
            
            if [ -z "$(get_config "INSTANCE_TYPE")" ]; then
                set_config "INSTANCE_TYPE" "m5.xlarge"
            fi
            ;;
        gcp)
            log_error "GCP provider not yet implemented"
            exit 1
            ;;
        azure)
            log_error "Azure provider not yet implemented"
            exit 1
            ;;
        *)
            log_error "Unsupported provider: $provider"
            usage
            exit 1
            ;;
    esac
    
    # Set instance name if not provided
    if [ -z "$(get_config "INSTANCE_NAME")" ]; then
        set_config "INSTANCE_NAME" "facto-${provider}-${node_type}"
    fi
    
    # Set key name if not provided
    if [ -z "$(get_config "KEY_NAME")" ]; then
        set_config "KEY_NAME" "facto-${provider}-key"
    fi
    
    # Set security group name if not provided
    if [ -z "$(get_config "SG_NAME")" ]; then
        set_config "SG_NAME" "facto-${provider}-sg"
    fi
    
    return 0
}

# Run the deployment
run_deployment() {
    local provider=$(get_config "PROVIDER")
    local node_type=$(get_config "NODE_TYPE")
    
    log "Starting deployment: Provider=$provider, Node Type=$node_type"
    
    # Ensure template directories exist
    ensure_template_dirs
    
    # Run provider-specific deployment
    case "$provider" in
        aws)
            provision_aws "$node_type"
            ;;
        gcp)
            log_error "GCP provider not yet implemented"
            exit 1
            ;;
        azure)
            log_error "Azure provider not yet implemented"
            exit 1
            ;;
    esac
    
    # Check deployment result
    if [ $? -ne 0 ]; then
        log_error "Deployment failed"
        exit 1
    fi
    
    # Get deployment details
    local public_ip=$(get_config "PUBLIC_IP")
    local key_path=$(get_config "KEY_PATH")
    
    # If we have SSH access, check node setup
    if [ ! -z "$public_ip" ] && [ ! -z "$key_path" ]; then
        log "Checking SSH access to $public_ip..."
        
        if check_ssh "$public_ip" "$key_path" 30; then
            log "SSH access confirmed"
            
            # Monitor setup progress
            if monitor_setup "$public_ip" "$key_path" 1800; then
                log_success "Node setup completed successfully"
                
                # Get initial node status
                get_node_status "$public_ip" "$key_path"
            else
                log_warning "Node setup monitoring did not complete within timeout"
                log_warning "The node may still be setting up in the background"
            fi
        else
            log_warning "Could not confirm SSH access within timeout"
            log_warning "The node may still be initializing"
        fi
    fi
    
    # Generate summary
    generate_deployment_summary
    
    return 0
}

# Generate deployment summary
generate_deployment_summary() {
    local provider=$(get_config "PROVIDER")
    local node_type=$(get_config "NODE_TYPE")
    local public_ip=$(get_config "PUBLIC_IP")
    local key_path=$(get_config "KEY_PATH")
    local instance_id=$(get_config "INSTANCE_ID")
    
    echo ""
    echo "===== Facto Node Deployment Summary ====="
    if $DRY_RUN; then
        echo "MODE: DRY RUN (No resources were actually created)"
    fi
    echo "Provider: $provider"
    echo "Node Type: $node_type"
    if [ ! -z "$instance_id" ]; then
        echo "Instance ID: $instance_id"
    fi
    if [ ! -z "$public_ip" ]; then
        echo "Public IP: $public_ip"
    fi
    if [ ! -z "$public_ip" ] && [ ! -z "$key_path" ]; then
        echo "SSH Command: ssh -i $key_path ubuntu@$public_ip"
        echo "Status Command: ssh -i $key_path ubuntu@$public_ip '/usr/local/bin/facto-monitor'"
    fi
    echo ""
    echo "Deployment log saved to: $LOG_FILE"
    echo ""
    
    # Save configuration for future reference
    if ! $DRY_RUN; then
        save_config "$SCRIPT_DIR/output/state/$(get_config "INSTANCE_NAME").conf"
    else
        log "Skipping state file creation in dry run mode"
    fi
}

# Create cleanup script
create_cleanup_script() {
    local provider=$(get_config "PROVIDER")
    local instance_name=$(get_config "INSTANCE_NAME")
    local cleanup_script="$SCRIPT_DIR/output/generated_scripts/cleanup-${instance_name}.sh"
    
    if $DRY_RUN; then
        log "DRY RUN: Would create cleanup script: $cleanup_script"
        return 0
    fi
    
    # Ensure directory exists
    ensure_dir "$(dirname "$cleanup_script")"
    
    log "Creating cleanup script: $cleanup_script"
    
    # Generate script
    cat > "$cleanup_script" << EOF
#!/bin/bash
# Cleanup script for Facto node: $instance_name

# Source deployment script
SCRIPT_DIR="$SCRIPT_DIR"
source "\$SCRIPT_DIR/core/logging.sh"
source "\$SCRIPT_DIR/core/cleanup.sh"
source "\$SCRIPT_DIR/core/utils.sh"
source "\$SCRIPT_DIR/core/config.sh"
source "\$SCRIPT_DIR/providers/$provider/${provider}_provider.sh"

# Initialize logging
init_logging "facto-cleanup"

# Load configuration
load_config_file "$SCRIPT_DIR/output/state/${instance_name}.conf"

# Perform cleanup
aws_cleanup

echo "Cleanup complete for $instance_name"
EOF
    
    chmod +x "$cleanup_script"
    log "Cleanup script created: $cleanup_script"
}

# Main function
main() {
    log "Facto Deployment Script Started"
    
    # Process command-line arguments
    process_args "$@"
    
    # Validate required configuration
    validate_required_config
    
    # Run the deployment
    run_deployment
    
    # Create cleanup script
    create_cleanup_script
    
    if $DRY_RUN; then
        log_success "Dry run completed successfully"
    else
        log_success "Deployment completed successfully"
    fi
    return 0
}

# Run main function
main "$@" 