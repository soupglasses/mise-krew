#!/usr/bin/env bash
# Integration tests for mise-krew
# These tests verify end-to-end functionality

echo "=========================================="
echo "mise-krew Integration Tests"
echo "=========================================="

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Helper function to run a test
run_test() {
    local test_name="$1"
    local test_cmd="$2"
    
    echo ""
    echo "Testing: $test_name"
    echo "Command: $test_cmd"
    
    if eval "$test_cmd" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ PASS${NC}: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}: $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Test 1: Plugin is properly linked
echo ""
echo "------------------------------------------"
echo "Test Suite: Plugin Installation"
echo "------------------------------------------"

run_test "Plugin is linked" "mise plugin list | grep -q krew"

# Test 2: Version listing works
echo ""
echo "------------------------------------------"
echo "Test Suite: Version Listing"
echo "------------------------------------------"

run_test "Can list versions for tree" "mise ls-remote krew:tree | grep -q 'v0.4'"

# Test 3: Installation of latest
echo ""
echo "------------------------------------------"
echo "Test Suite: Installation (latest)"
echo "------------------------------------------"

# Clean up any existing test installation
rm -rf ~/.local/share/mise/installs/krew-tree/

run_test "Install tree@latest" "mise install krew:tree@latest"

# Find the actual installed version directory (mise resolves latest to a version)
TREE_INSTALL=$(mise where krew:tree@latest 2>/dev/null || echo "")
run_test "Binary exists after install" "test -f '${TREE_INSTALL}/kubectl-tree'"
run_test "Binary is executable" "test -x '${TREE_INSTALL}/kubectl-tree'"

# Test 4: Version execution
echo ""
echo "------------------------------------------"
echo "Test Suite: Version Execution"
echo "------------------------------------------"

run_test "Can execute installed tool" "mise exec krew:tree@latest -- kubectl-tree --version | grep -q 'v0.4'"

# Summary
echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
