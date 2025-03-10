#!/bin/bash
# facto-deploy/scripts/test.sh - Script to test deployment scripts in dry run mode

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Source core functionality
source "$BASE_DIR/core/logging.sh"

# Initialize logging
init_logging "facto-test"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored message
print_colored() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Run a test case
# Arguments:
#   $1 - Test case name
#   $2+ - Arguments to pass to deploy.sh
run_test() {
    local test_name=$1
    shift
    
    print_colored $BLUE "=== Running test case: $test_name ==="
    print_colored $YELLOW "Command: $BASE_DIR/deploy.sh $@ --dry-run"
    
    # Run deployment with dry run flag
    "$BASE_DIR/deploy.sh" "$@" --dry-run
    
    if [ $? -eq 0 ]; then
        print_colored $GREEN "✓ Test passed: $test_name"
        return 0
    else
        print_colored $RED "✗ Test failed: $test_name"
        return 1
    fi
}

# Test AWS Bitcoin deployment with default parameters
test_aws_bitcoin_default() {
    run_test "AWS Bitcoin - Default Parameters" \
        --provider aws \
        --type bitcoin
}

# Test AWS Bitcoin deployment with custom parameters
test_aws_bitcoin_custom() {
    run_test "AWS Bitcoin - Custom Parameters" \
        --provider aws \
        --type bitcoin \
        --region us-west-2 \
        --instance-type t3.large \
        --volume-size 250 \
        --name facto-test-node
}

# Test AWS Bitcoin deployment with config file
test_aws_bitcoin_config() {
    run_test "AWS Bitcoin - From Config File" \
        --config "$BASE_DIR/config/aws-bitcoin.conf"
}

# Test invalid configuration
test_invalid_config() {
    run_test "Invalid Configuration - Missing Type" \
        --provider aws
    
    # Since we expect this to fail, invert the return code
    if [ $? -ne 0 ]; then
        print_colored $GREEN "✓ Test passed: Invalid Configuration correctly rejected"
        return 0
    else
        print_colored $RED "✗ Test failed: Invalid Configuration was accepted"
        return 1
    fi
}

# Run all tests
run_all_tests() {
    local passed=0
    local failed=0
    local total=0
    
    print_colored $BLUE "=== Starting Test Suite ==="
    
    # Ensure the correct directory structure exists
    "$BASE_DIR/init-structure.sh" > /dev/null
    
    # Run individual tests and count results
    test_aws_bitcoin_default
    if [ $? -eq 0 ]; then ((passed++)); else ((failed++)); fi
    ((total++))
    
    test_aws_bitcoin_custom
    if [ $? -eq 0 ]; then ((passed++)); else ((failed++)); fi
    ((total++))
    
    test_aws_bitcoin_config
    if [ $? -eq 0 ]; then ((passed++)); else ((failed++)); fi
    ((total++))
    
    test_invalid_config
    if [ $? -eq 0 ]; then ((passed++)); else ((failed++)); fi
    ((total++))
    
    # Print summary
    print_colored $BLUE "=== Test Suite Summary ==="
    print_colored $GREEN "Passed: $passed"
    print_colored $RED "Failed: $failed"
    print_colored $BLUE "Total:  $total"
    
    if [ $failed -eq 0 ]; then
        print_colored $GREEN "✓ All tests passed!"
        return 0
    else
        print_colored $RED "✗ Some tests failed."
        return 1
    fi
}

# Usage information
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --all                Run all tests"
    echo "  --aws-default        Test AWS Bitcoin deployment with default parameters"
    echo "  --aws-custom         Test AWS Bitcoin deployment with custom parameters"
    echo "  --aws-config         Test AWS Bitcoin deployment with config file"
    echo "  --invalid            Test invalid configuration"
    echo "  -h, --help           Show this help message"
    echo ""
}

# Parse command-line arguments
if [ $# -eq 0 ]; then
    usage
    exit 1
fi

case $1 in
    --all)
        run_all_tests
        ;;
    --aws-default)
        test_aws_bitcoin_default
        ;;
    --aws-custom)
        test_aws_bitcoin_custom
        ;;
    --aws-config)
        test_aws_bitcoin_config
        ;;
    --invalid)
        test_invalid_config
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
esac 