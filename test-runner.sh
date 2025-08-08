#!/bin/bash

# MultiUSD Test Runner
# Скрипт для запуска всех тестов системы USDM/Corrector

set -e

echo "🚀 MultiUSD Test Suite Runner"
echo "============================="

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для логирования
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Проверка зависимостей
check_dependencies() {
    log_info "Проверка зависимостей..."
    
    if ! command -v forge &> /dev/null; then
        log_error "Forge не найден. Установите Foundry: https://book.getfoundry.sh/"
        exit 1
    fi
    
    if ! command -v cast &> /dev/null; then
        log_error "Cast не найден. Установите Foundry: https://book.getfoundry.sh/"
        exit 1
    fi
    
    log_success "Все зависимости установлены"
}

# Компиляция контрактов
compile_contracts() {
    log_info "Компиляция контрактов..."
    
    if forge build; then
        log_success "Контракты скомпилированы успешно"
    else
        log_error "Ошибка компиляции контрактов"
        exit 1
    fi
}

# Unit тесты
run_unit_tests() {
    log_info "Запуск unit тестов..."
    
    echo "📋 Тестирование основного функционала..."
    if forge test --match-contract CorrectorUnitTest -vv; then
        log_success "Unit тесты пройдены"
    else
        log_error "Unit тесты провалены"
        return 1
    fi
}

# Интеграционные тесты с форком мейннета
run_integration_tests() {
    log_info "Запуск интеграционных тестов с форком мейннета..."
    
    # Проверяем наличие RPC URL
    if [ -z "$ETH_RPC_URL" ]; then
        log_warning "ETH_RPC_URL не установлен. Используем публичный RPC..."
        export ETH_RPC_URL="https://rpc.ankr.com/eth"
    fi
    
    echo "🌐 Тестирование с форком Ethereum..."
    if forge test --match-contract CorrectorIntegrationTest --fork-url $ETH_RPC_URL --fork-block-number 18500000 -vv; then
        log_success "Интеграционные тесты пройдены"
    else
        log_error "Интеграционные тесты провалены"
        return 1
    fi
}

# Тесты производительности
run_performance_tests() {
    log_info "Запуск тестов производительности..."
    
    echo "⚡ Измерение газа и производительности..."
    if forge test --match-test "testPerformance" --gas-report -vv; then
        log_success "Тесты производительности пройдены"
    else
        log_warning "Некоторые тесты производительности провалены"
    fi
}

# Фаззинг тесты
run_fuzz_tests() {
    log_info "Запуск фаззинг тестов..."
    
    echo "🎲 Фаззинг тестирование..."
    if forge test --match-test "testFuzz" --fuzz-runs 1000 -vv; then
        log_success "Фаззинг тесты пройдены"
    else
        log_warning "Некоторые фаззинг тесты провалены"
    fi
}

# Мультичейн тесты
run_multichain_tests() {
    log_info "Запуск мультичейн тестов..."
    
    # Ethereum
    echo "🔗 Тестирование на Ethereum..."
    if forge test --match-test "testEthereumMainnet" --fork-url "https://rpc.ankr.com/eth" --fork-block-number 18500000 -vv; then
        log_success "Ethereum тесты пройдены"
    else
        log_warning "Ethereum тесты провалены"
    fi
    
    # BSC (если доступен RPC)
    echo "🔗 Тестирование на BSC..."
    if forge test --match-test "testBSCMainnet" --fork-url "https://rpc.ankr.com/bsc" --fork-block-number 35000000 -vv 2>/dev/null; then
        log_success "BSC тесты пройдены"
    else
        log_warning "BSC тесты пропущены или провалены"
    fi
    
    # Polygon (если доступен RPC)
    echo "🔗 Тестирование на Polygon..."
    if forge test --match-test "testPolygonMainnet" --fork-url "https://rpc.ankr.com/polygon" --fork-block-number 50000000 -vv 2>/dev/null; then
        log_success "Polygon тесты пройдены"
    else
        log_warning "Polygon тесты пропущены или провалены"
    fi
}

# Генерация отчета о покрытии
generate_coverage() {
    log_info "Генерация отчета о покрытии кода..."
    
    if forge coverage --report lcov; then
        log_success "Отчет о покрытии создан"
        
        # Конвертируем в HTML если доступен genhtml
        if command -v genhtml &> /dev/null; then
            genhtml lcov.info --output-directory coverage-report
            log_success "HTML отчет создан в ./coverage-report/"
        fi
    else
        log_warning "Не удалось создать отчет о покрытии"
    fi
}

# Генерация снимков газа
generate_gas_snapshots() {
    log_info "Создание снимков использования газа..."
    
    if forge snapshot; then
        log_success "Снимки газа созданы в .gas-snapshot"
    else
        log_warning "Не удалось создать снимки газа"
    fi
}

# Статический анализ
run_static_analysis() {
    log_info "Запуск статического анализа..."
    
    # Slither (если установлен)
    if command -v slither &> /dev/null; then
        echo "🔍 Анализ с помощью Slither..."
        if slither . --exclude-dependencies; then
            log_success "Slither анализ завершен"
        else
            log_warning "Slither обнаружил потенциальные проблемы"
        fi
    else
        log_warning "Slither не установлен, пропускаем статический анализ"
    fi
}

# Основная функция
main() {
    local test_type="${1:-all}"
    
    echo "🎯 Запуск тестов: $test_type"
    echo ""
    
    check_dependencies
    compile_contracts
    
    case $test_type in
        "unit")
            run_unit_tests
            ;;
        "integration")
            run_integration_tests
            ;;
        "performance")
            run_performance_tests
            ;;
        "fuzz")
            run_fuzz_tests
            ;;
        "multichain")
            run_multichain_tests
            ;;
        "coverage")
            generate_coverage
            ;;
        "all")
            echo "🔄 Запуск полного набора тестов..."
            
            # Основные тесты
            run_unit_tests || log_warning "Unit тесты провалены"
            run_integration_tests || log_warning "Интеграционные тесты провалены"
            
            # Дополнительные тесты
            run_performance_tests || log_warning "Тесты производительности провалены"
            run_fuzz_tests || log_warning "Фаззинг тесты провалены"
            run_multichain_tests || log_warning "Мультичейн тесты провалены"
            
            # Анализ и отчеты
            generate_gas_snapshots
            generate_coverage
            run_static_analysis
            ;;
        *)
            log_error "Неизвестный тип тестов: $test_type"
            echo ""
            echo "Доступные типы:"
            echo "  unit        - Unit тесты"
            echo "  integration - Интеграционные тесты с форком"
            echo "  performance - Тесты производительности"
            echo "  fuzz        - Фаззинг тесты"
            echo "  multichain  - Мультичейн тесты"
            echo "  coverage    - Отчет о покрытии"
            echo "  all         - Все тесты (по умолчанию)"
            exit 1
            ;;
    esac
    
    echo ""
    log_success "Тестирование завершено!"
}

# Запуск
main "$@"
