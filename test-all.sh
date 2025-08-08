#!/bin/bash

# USDM Corrector Test Suite
# Комплексное тестирование системы арбитража USDM

echo "🚀 Starting USDM Corrector Test Suite..."
echo "========================================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results tracking
PASSED=0
FAILED=0
TOTAL=0

# Function to run test and track results
run_test() {
    local test_name="$1"
    local test_command="$2"
    local description="$3"
    
    echo -e "\n${BLUE}📋 Running: $test_name${NC}"
    echo "   Description: $description"
    echo "   Command: $test_command"
    echo "----------------------------------------"
    
    TOTAL=$((TOTAL + 1))
    
    if eval $test_command; then
        echo -e "${GREEN}✅ PASSED: $test_name${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}❌ FAILED: $test_name${NC}"
        FAILED=$((FAILED + 1))
    fi
}

# Compile contracts first
echo -e "${YELLOW}🔨 Compiling contracts...${NC}"
if forge build; then
    echo -e "${GREEN}✅ Compilation successful${NC}"
else
    echo -e "${RED}❌ Compilation failed${NC}"
    exit 1
fi

# 1. Unit Tests - Fast execution with mocks
echo -e "\n${YELLOW}🧪 UNIT TESTS${NC}"
echo "=================================="

run_test "Basic Integration Tests" \
    "forge test --match-contract CorrectorIntegrationSimple -v" \
    "Быстрые тесты с простыми моками для проверки базовой функциональности"

run_test "Advanced Algorithm Tests" \
    "forge test --match-contract CorrectorAdvanced -v" \
    "Продвинутые тесты алгоритмов расчета курсов и арбитража"

run_test "Arbitrage Strategy Tests" \
    "forge test --match-contract CorrectorArbitrage -v" \
    "Специализированные тесты арбитражных стратегий и MEV защиты"

# 2. Integration Tests - With mainnet forks
echo -e "\n${YELLOW}🌐 INTEGRATION TESTS (MAINNET FORK)${NC}"
echo "=================================="

run_test "Ethereum Mainnet Fork Tests" \
    "forge test --match-contract CorrectorMainnetFork --fork-url https://rpc.ankr.com/eth -v" \
    "Тесты с форком Ethereum мейннета для реальных данных"

# 3. Fuzz Testing
echo -e "\n${YELLOW}🎲 FUZZ TESTING${NC}"
echo "=================================="

run_test "Rate Calculation Fuzz Tests" \
    "forge test --match-test testFuzz --fuzz-runs 1000 -v" \
    "Фаззинг тесты для проверки устойчивости к различным входным данным"

# 4. Gas Optimization Tests
echo -e "\n${YELLOW}⛽ GAS OPTIMIZATION TESTS${NC}"
echo "=================================="

run_test "Gas Usage Analysis" \
    "forge test --match-test testPerformance --gas-report -v" \
    "Анализ газовых затрат для оптимизации"

# 5. Security Tests
echo -e "\n${YELLOW}🔒 SECURITY TESTS${NC}"
echo "=================================="

run_test "Access Control Tests" \
    "forge test --match-test testSecurity -v" \
    "Проверка безопасности и контроля доступа"

run_test "Flash Loan Protection Tests" \
    "forge test --match-test testFlashLoan -v" \
    "Тесты защиты от атак с флэш-займами"

# 6. Edge Cases
echo -e "\n${YELLOW}⚠️  EDGE CASE TESTING${NC}"
echo "=================================="

run_test "Extreme Market Conditions" \
    "forge test --match-test testExtreme -v" \
    "Тесты экстремальных рыночных условий"

run_test "Overflow Protection Tests" \
    "forge test --match-test testOverflow -v" \
    "Проверка защиты от переполнения"

# 7. Multi-chain Tests (if configured)
if [ -n "$BSC_RPC_URL" ] && [ -n "$POLYGON_RPC_URL" ]; then
    echo -e "\n${YELLOW}🌍 MULTI-CHAIN TESTS${NC}"
    echo "=================================="
    
    run_test "BSC Fork Tests" \
        "forge test --match-contract CorrectorMainnetFork --fork-url $BSC_RPC_URL -v" \
        "Тесты с форком BSC"
    
    run_test "Polygon Fork Tests" \
        "forge test --match-contract CorrectorMainnetFork --fork-url $POLYGON_RPC_URL -v" \
        "Тесты с форком Polygon"
fi

# 8. Coverage Analysis
echo -e "\n${YELLOW}📊 COVERAGE ANALYSIS${NC}"
echo "=================================="

run_test "Code Coverage Report" \
    "forge coverage --report lcov" \
    "Генерация отчета о покрытии кода тестами"

# Performance Benchmarks
echo -e "\n${YELLOW}🏁 PERFORMANCE BENCHMARKS${NC}"
echo "=================================="

echo "Running gas snapshots..."
forge snapshot --match-contract Corrector

# Test Summary
echo -e "\n${BLUE}📈 TEST SUMMARY${NC}"
echo "========================================"
echo -e "Total Tests: $TOTAL"
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"

if [ $FAILED -eq 0 ]; then
    echo -e "\n${GREEN}🎉 ALL TESTS PASSED! 🎉${NC}"
    echo "System is ready for production deployment."
    exit 0
else
    echo -e "\n${RED}❌ SOME TESTS FAILED${NC}"
    echo "Please review failed tests before deployment."
    exit 1
fi

# Additional commands for manual testing:
echo -e "\n${YELLOW}🔧 MANUAL TESTING COMMANDS${NC}"
echo "========================================"
echo "Run specific test:"
echo "  forge test --match-test testCalculateAverageRates -vvv"
echo ""
echo "Run with detailed traces:"
echo "  forge test --match-contract CorrectorIntegration -vvv"
echo ""
echo "Run with mainnet fork (specific block):"
echo "  forge test --fork-url https://rpc.ankr.com/eth --fork-block-number 18500000 -v"
echo ""
echo "Run gas profiling:"
echo "  forge test --gas-report --match-contract Corrector"
echo ""
echo "Generate coverage HTML report:"
echo "  forge coverage --report html"
