#!/bin/bash
# init-structure.sh - Initialize directory structure for Facto deployment
# Creates the required directories that are excluded from version control

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Define output directories
OUTPUT_DIRS=(
    "output/logs"
    "output/keys"
    "output/generated_scripts"
    "output/state"
    "output/ui"
)

# Define provider directories
PROVIDER_DIRS=(
    "providers/aws"
    "providers/gcp"
    "providers/azure"
)

# Define template directories
TEMPLATE_DIRS=(
    "templates/aws/bitcoin"
    "templates/gcp/bitcoin"
    "templates/azure/bitcoin"
)

# Define other directories
OTHER_DIRS=(
    "config"
    "scripts"
    "ui-adapter"
)

echo "Initializing directory structure for Facto deployment system..."

# Create output directories
for dir in "${OUTPUT_DIRS[@]}"; do
    mkdir -p "$SCRIPT_DIR/$dir"
    echo "Created directory: $dir"
done

# Create provider directories
for dir in "${PROVIDER_DIRS[@]}"; do
    mkdir -p "$SCRIPT_DIR/$dir"
    echo "Created directory: $dir"
done

# Create template directories
for dir in "${TEMPLATE_DIRS[@]}"; do
    mkdir -p "$SCRIPT_DIR/$dir"
    echo "Created directory: $dir"
done

# Create other directories
for dir in "${OTHER_DIRS[@]}"; do
    mkdir -p "$SCRIPT_DIR/$dir"
    echo "Created directory: $dir"
done

# Create empty README files in empty directories to ensure they're tracked by Git
# This prevents empty directories from being ignored by Git
find "$SCRIPT_DIR" -type d -empty -not -path "*/output/*" -exec touch {}/.gitkeep \;

# Make this script executable
chmod +x "$SCRIPT_DIR/deploy.sh"
chmod +x "$SCRIPT_DIR/ui-adapter/api.sh"

echo "Directory structure initialization complete."
echo "Run './deploy.sh --help' for usage information." 