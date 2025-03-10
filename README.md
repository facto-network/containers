# Facto Deployment System

A modular deployment system for Facto blockchain verification nodes on multiple cloud providers.

## Directory Structure

```
facto-deploy/
├── core/                   # Core functionality shared across providers
│   ├── logging.sh          # Logging utilities
│   ├── cleanup.sh          # Resource cleanup and error handling
│   ├── utils.sh            # Common utility functions
│   ├── config.sh           # Configuration management
│   └── template.sh         # Template processing for scripts
├── providers/              # Cloud provider-specific implementations
│   ├── aws/                # AWS provider
│   │   ├── aws_provider.sh # AWS deployment implementation
│   │   └── aws_monitor.sh  # AWS monitoring implementation
│   ├── gcp/                # Google Cloud Platform provider (future)
│   └── azure/              # Azure provider (future)
├── templates/              # Templates for user-data scripts
│   ├── aws/
│   │   └── bitcoin/        # AWS Bitcoin templates
│   ├── gcp/                # GCP templates (future)
│   └── azure/              # Azure templates (future)
├── config/                 # Configuration files
│   └── aws-bitcoin.conf    # Sample AWS Bitcoin configuration
├── scripts/                # Additional utility scripts
├── ui-adapter/             # Interface for web applications
│   └── api.sh              # API for web integration
├── output/                 # Generated files and logs (not tracked in git)
│   ├── logs/               # Log files
│   ├── keys/               # SSH keys
│   ├── generated_scripts/  # Generated scripts
│   ├── state/              # Deployment state
│   └── ui/                 # UI adapter output
├── .gitignore              # Git exclusion patterns
├── init-structure.sh       # Directory structure initialization script
└── deploy.sh               # Main deployment script
```

## Getting Started

### First-time Setup

After cloning the repository, run the initialization script to create the necessary directory structure:

```bash
chmod +x init-structure.sh
./init-structure.sh
```

This script creates all required directories including those that are excluded from version control.

## Usage

### Command-line Usage

```bash
./deploy.sh --provider aws --type bitcoin --region us-east-1 --instance-type m5.xlarge --volume-size 500 --name facto-btc-node
```

### Configuration File Usage

```bash
./deploy.sh --config config/aws-bitcoin.conf
```

### Web API Usage

```bash
./ui-adapter/api.sh deploy '{"provider":"aws","node_type":"bitcoin","region":"us-east-1"}'
./ui-adapter/api.sh status 1234567890
./ui-adapter/api.sh list
```

## Features

- **Modular Design**: Each cloud provider has its own implementation
- **Customizable**: All parameters can be configured via command-line or config file
- **Error Handling**: Robust error handling and resource cleanup
- **Logging**: Comprehensive logging for troubleshooting
- **Monitoring**: Node status monitoring and verification
- **Web Integration**: API for integration with web applications

## Supported Cloud Providers

- AWS (Amazon Web Services) - fully implemented
- GCP (Google Cloud Platform) - planned
- Azure (Microsoft Azure) - planned

## Supported Node Types

- Bitcoin - fully implemented
- Ethereum - planned
- Other blockchains - planned

## Requirements

- Bash 4.0 or later
- AWS CLI, GCP CLI, or Azure CLI (depending on provider)
- jq for JSON processing
- ssh, ping, nc for connectivity checks

## Testing

You can test the deployment scripts without actually creating cloud resources using the dry run mode:

```bash
# Test a basic AWS Bitcoin deployment with no actual resource creation
./deploy.sh --provider aws --type bitcoin --dry-run
```

The dry run mode will:
- Validate configurations and parameters
- Process templates and generate scripts
- Simulate API calls to AWS/cloud providers
- Show you exactly what would happen in a real deployment
- Not create any actual cloud resources
- Not incur any cloud provider costs

### Automated Tests

For more comprehensive testing, use the test script:

```bash
# Run all tests
./scripts/test.sh --all

# Run specific test cases
./scripts/test.sh --aws-default
./scripts/test.sh --aws-custom 
./scripts/test.sh --aws-config
```

The test script runs multiple deployment scenarios in dry run mode and reports success or failure.

## Version Control Notes

- The `.gitignore` file excludes sensitive and generated files from version control:
  - All content in the `output/` directory (logs, keys, generated scripts, state files)
  - SSH keys and certificates (*.pem, *.key, etc.)
  - Log files and debugging output
  - Configuration files containing secrets or credentials
  - OS-specific and editor-specific files

- When deploying in production, make sure to:
  1. Run `init-structure.sh` to create required directories
  2. Set appropriate permissions on sensitive files and directories
  3. Consider using environment variables for sensitive information 