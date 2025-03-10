#!/bin/bash
# facto-deploy/core/template.sh - Template processing for user-data scripts

# Source logging functionality
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/logging.sh"
source "$SCRIPT_DIR/config.sh"

# Default template directory
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")/templates"
OUTPUT_DIR="$(dirname "$SCRIPT_DIR")/output/generated_scripts"

# Process a template file by replacing placeholders with configuration values
# Arguments:
#   $1 - Template file path
#   $2 - Output file path
process_template() {
    local template_file=$1
    local output_file=$2
    
    if [ ! -f "$template_file" ]; then
        log_error "Template file not found: $template_file"
        return 1
    fi
    
    # Ensure output directory exists
    ensure_dir "$(dirname "$output_file")"
    
    log "Processing template: $template_file -> $output_file"
    
    # Read template file
    local template_content=$(<"$template_file")
    
    # Replace placeholders with config values
    for key in "${!CONFIG[@]}"; do
        local placeholder="{{$key}}"
        local value="${CONFIG[$key]}"
        template_content="${template_content//$placeholder/$value}"
    done
    
    # Write processed template to output file
    echo "$template_content" > "$output_file"
    chmod +x "$output_file"
    
    log "Template processed and saved to $output_file"
    return 0
}

# Process all templates for a specific provider and node type
# Arguments:
#   $1 - Provider (aws, gcp, azure)
#   $2 - Node type (bitcoin, ethereum, etc.)
process_templates() {
    local provider=$1
    local node_type=$2
    
    local provider_template_dir="$TEMPLATE_DIR/$provider/$node_type"
    local output_base_dir="$OUTPUT_DIR/$provider/$node_type"
    
    if [ ! -d "$provider_template_dir" ]; then
        log_error "Template directory not found: $provider_template_dir"
        return 1
    fi
    
    ensure_dir "$output_base_dir"
    
    log "Processing templates for $provider/$node_type"
    
    # Process each template file
    for template_file in "$provider_template_dir"/*.sh.template; do
        if [ -f "$template_file" ]; then
            local filename=$(basename "$template_file" .template)
            local output_file="$output_base_dir/$filename"
            
            process_template "$template_file" "$output_file"
        fi
    done
    
    log "All templates processed for $provider/$node_type"
    return 0
}

# Get the path to the generated user-data script
# Arguments:
#   $1 - Provider
#   $2 - Node type
get_user_data_script() {
    local provider=$1
    local node_type=$2
    
    echo "$OUTPUT_DIR/$provider/$node_type/user-data.sh"
}

# Ensure template directories exist
ensure_template_dirs() {
    # Create base template directories for each provider and node type
    mkdir -p "$TEMPLATE_DIR/aws/bitcoin"
    mkdir -p "$TEMPLATE_DIR/gcp/bitcoin"
    mkdir -p "$TEMPLATE_DIR/azure/bitcoin"
    
    # Create output directories
    mkdir -p "$OUTPUT_DIR/aws/bitcoin"
    mkdir -p "$OUTPUT_DIR/gcp/bitcoin"
    mkdir -p "$OUTPUT_DIR/azure/bitcoin"
} 