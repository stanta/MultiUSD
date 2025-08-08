# USDM Corrector Testing Suite

Комплексная система тестирования для функционала расчета средних курсов стейблкоинов и арбитража USDM.

## 🎯 Цели Тестирования

Данная система тестов проверяет:

1. **Расчет средних курсов** - точность агрегации курсов USDT/USDC к нативным коинам
2. **Арбитражные алгоритмы** - корректность определения и исполнения арбитража USDM
3. **Производительность** - газовые затраты и скорость выполнения
4. **Безопасность** - защита от атак и некорректного использования
5. **Устойчивость** - работа в экстремальных рыночных условиях

## 📁 Структура Тестов

### 1. Unit Tests (Быстрые)

- `CorrectorIntegrationSimple.t.sol` - Базовые тесты с простыми моками
- `CorrectorAdvanced.t.sol` - Продвинутые алгоритмические тесты
- `CorrectorArbitrage.t.sol` - Специализированные тесты арбитража

### 2. Integration Tests (С форками мейннета)

- `CorrectorMainnetFork.t.sol` - Тесты с реальными данными блокчейна
- `CorrectorMultichain.t.sol` - Тесты на разных сетях (BSC, Polygon)

### 3. Security Tests

- Flash loan protection
- MEV resistance
- Access control
- Overflow protection

## 🚀 Быстрый Старт

### Запуск всех тестов

```bash
./test-all.sh
```

### Запуск отдельных групп тестов

#### Быстрые unit тесты

```bash
forge test --match-contract CorrectorIntegrationSimple -v
```

#### Продвинутые тесты алгоритмов

```bash
forge test --match-contract CorrectorAdvanced -v
```

#### Арбитражные стратегии

```bash
forge test --match-contract CorrectorArbitrage -v
```

#### Тесты с мейннет форком

```bash
forge test --match-contract CorrectorMainnetFork --fork-url https://rpc.ankr.com/eth -v
```

## 🔧 Специфические Тесты

### Тест расчета средних курсов

```bash
forge test --match-test testCalculateAverageRates -vvv
```

### Тест арбитража при переоценке USDM

```bash
forge test --match-test testUSDMOvervalued -vvv
```

### Тест арбитража при недооценке USDM

```bash
forge test --match-test testUSDMUndervalued -vvv
```

### Фаззинг тесты

```bash
forge test --match-test testFuzz --fuzz-runs 1000 -v
```

### Тесты производительности

```bash
forge test --match-test testPerformance --gas-report -v
```

## 📊 Анализ Покрытия

### Генерация отчета о покрытии

```bash
forge coverage
```

### HTML отчет

```bash
forge coverage --report html
```

### LCOV отчет

```bash
forge coverage --report lcov
```

## ⛽ Анализ Газа

### Снимок газовых затрат

```bash
forge snapshot
```

### Детальный газовый отчет

```bash
forge test --gas-report
```

## 🌐 Тестирование с Форками

### Ethereum Mainnet

```bash
forge test --fork-url https://rpc.ankr.com/eth --fork-block-number 18500000 -v
```

### BSC

```bash
forge test --fork-url https://rpc.ankr.com/bsc -v
```

### Polygon

```bash
forge test --fork-url https://rpc.ankr.com/polygon -v
```

## 🎯 Ключевые Сценарии Тестирования

### 1. Базовый Расчет Курсов

- ✅ Агрегация резервов USDC/ETH и USDT/ETH пулов
- ✅ Расчет средневзвешенного курса
- ✅ Точность при различных размерах пулов
- ✅ Обработка малых чисел

### 2. Арбитраж USDM Переоценен

```
Сценарий: USDM торгуется по 2200 USD/ETH, рынок - 2000 USD/ETH
Ожидание: Система должна продать USDM за ETH
Проверка: Исполнение swap операций в правильном направлении
```

### 3. Арбитраж USDM Недооценен

```
Сценарий: USDM торгуется по 1800 USD/ETH, рынок - 2000 USD/ETH
Ожидание: Система должна купить USDM за ETH
Проверка: Исполнение swap операций в правильном направлении
```

### 4. Множественные Пулы

- ✅ Корректная агрегация данных с нескольких DEX
- ✅ Средневзвешенные расчеты
- ✅ Влияние крупных пулов на общий курс

### 5. Экстремальные Условия

- ✅ Обвал рынка (-50% за ETH)
- ✅ Высокая волатильность
- ✅ Очень малые/большие пулы
- ✅ Переполнение чисел

## 🔒 Тесты Безопасности

### Access Control

```bash
forge test --match-test testSecurity -v
```

### Flash Loan Protection

```bash
forge test --match-test testFlashLoan -v
```

### MEV Resistance

```bash
forge test --match-test testMEV -v
```

## 📈 Метрики Производительности

| Операция             | Ожидаемый газ | Тест                           |
| -------------------- | ------------- | ------------------------------ |
| `getAllStableRate()` | < 200,000     | `testPerformance`              |
| `correctAll()`       | < 500,000     | `testArbitrageGasEfficiency`   |
| Множественные пулы   | < 300,000     | `testPerformanceWithManyPools` |

## 🐛 Отладка

### Детальные логи

```bash
forge test --match-test testCalculateAverageRates -vvvv
```

### Трейсы выполнения

```bash
forge test --match-test testUSDMOvervalued --debug
```

### Проверка state changes

```bash
forge test --match-test testArbitrage --trace
```

## 🔄 Непрерывная Интеграция

Для CI/CD pipeline используйте:

```yaml
- name: Run USDM Tests
  run: |
    forge test --match-contract CorrectorIntegrationSimple
    forge test --match-contract CorrectorAdvanced
    forge snapshot --check
```

## 📝 Добавление Новых Тестов

### Шаблон для нового теста:

```solidity
function testNewScenario() public {
    console.log("=== Test: New Scenario ===");

    // Setup
    // ... prepare test conditions

    // Execute
    // ... call functions being tested

    // Assert
    // ... verify expected outcomes

    console.log("New scenario tested successfully");
}
```

### Рекомендации:

1. Используйте описательные имена тестов
2. Добавляйте console.log для отладки
3. Тестируйте граничные случаи
4. Измеряйте газовые затраты
5. Проверяйте безопасность

## 🎪 Mock Contracts

Система использует специализированные mock контракты для быстрого тестирования:

- `MockFactory` - Имитация Uniswap V2 Factory
- `MockPair` - Имитация Uniswap V2 Pair с настраиваемыми резервами
- `MockERC20` - Базовый ERC20 токен для тестов

## 📚 Дополнительные Ресурсы

- [Foundry Book](https://book.getfoundry.sh/)
- [Forge Testing Guide](https://book.getfoundry.sh/forge/tests)
- [Uniswap V2 Documentation](https://docs.uniswap.org/protocol/V2/introduction)
- [OpenZeppelin Test Helpers](https://docs.openzeppelin.com/test-helpers/)

---

**Автор**: @stanta  
**Лицензия**: GPL-3.0  
**Версия тестов**: v1.0.0

## Структура тестов

### 1. Unit тесты (`CorrectorUnit.t.sol`)

- **Назначение**: Тестирование изолированных компонентов с mock контрактами
- **Покрытие**: Базовая логика, математические расчеты, контроль доступа
- **Запуск**: `forge test --match-contract CorrectorUnitTest`

### 2. Интеграционные тесты (`CorrectorIntegration.t.sol`)

- **Назначение**: Тестирование с реальными данными форка мейннета
- **Покрытие**: Взаимодействие с настоящими DEX протоколами
- **Запуск**: `forge test --match-contract CorrectorIntegrationTest --fork-url https://rpc.ankr.com/eth`

### 3. Мультичейн тесты (`CorrectorMultichain.t.sol`)

- **Назначение**: Тестирование на различных блокчейн сетях
- **Покрытие**: Ethereum, BSC, Polygon
- **Запуск**: `forge test --match-contract CorrectorMultichainTest`

## Настройка окружения

### Требования

```bash
# Установка Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Клонирование и настройка проекта
git clone <repository>
cd MultiUSD
forge install
```

### Переменные окружения

Создайте файл `.env` с RPC URL:

```bash
ETH_RPC_URL=https://rpc.ankr.com/eth
BSC_RPC_URL=https://rpc.ankr.com/bsc
POLYGON_RPC_URL=https://rpc.ankr.com/polygon
```

## Запуск тестов

### Быстрый запуск

```bash
# Все тесты
./test-runner.sh

# Только unit тесты
./test-runner.sh unit

# Только интеграционные тесты
./test-runner.sh integration
```

### Ручной запуск

#### Unit тесты

```bash
forge test --match-contract CorrectorUnitTest -vv
```

#### Интеграционные тесты с форком

```bash
forge test --match-contract CorrectorIntegrationTest \
  --fork-url https://rpc.ankr.com/eth \
  --fork-block-number 18500000 \
  -vv
```

#### Тесты производительности

```bash
forge test --match-test "testPerformance" --gas-report
```

#### Фаззинг тесты

```bash
forge test --match-test "testFuzz" --fuzz-runs 10000
```

## Ключевые тестовые сценарии

### 1. Расчет средних курсов

```solidity
function testCalculateAverageStablecoinRates() public {
    // Тестирует агрегацию резервов из нескольких AMM пулов
    // Проверяет точность расчета средневзвешенного курса
}
```

### 2. Арбитраж USDM

```solidity
function testUSDMUndervaluedScenario() public {
    // Сценарий: USDM недооценен относительно средней цены
    // Ожидание: система должна покупать USDM (продавать ETH)
}

function testUSDMOvervaluedScenario() public {
    // Сценарий: USDM переоценен относительно средней цены
    // Ожидание: система должна продавать USDM (покупать ETH)
}
```

### 3. Мультичейн интеграция

```solidity
function testEthereumMainnet() public {
    // Тестирование на Ethereum с реальными Uniswap пулами
}

function testBSCMainnet() public {
    // Тестирование на BSC с PancakeSwap пулами
}
```

## Метрики и отчеты

### Покрытие кода

```bash
forge coverage --report lcov
genhtml lcov.info --output-directory coverage-report
```

### Использование газа

```bash
forge test --gas-report
forge snapshot
```

### Статический анализ

```bash
slither . --exclude-dependencies
```

## Интерпретация результатов

### Успешные тесты

- ✅ Все assert'ы прошли
- ✅ Газ в разумных пределах (< 500k для основных операций)
- ✅ Нет ревертов в нормальных условиях

### Ожидаемые результаты

- **Средний курс**: Должен быть в диапазоне 1000-10000 для USDC/ETH
- **Арбитраж**: Должен выполняться только при отклонении > 1%
- **Производительность**: < 500k газа для getAllStableRate()

### Потенциальные проблемы

- ❌ Очень высокое потребление газа (> 1M)
- ❌ Неточные расчеты при малых резервах
- ❌ Ревертимость при нормальных условиях

## Отладка

### Включение детального вывода

```bash
forge test -vvvv  # Максимальная детализация
```

### Логирование в тестах

```solidity
console.log("Current rate:", rate);
console.log("Expected rate:", expectedRate);
```

### Анализ транзакций

```bash
cast run <transaction_hash> --rpc-url <rpc_url>
```

## Продвинутые сценарии

### Тестирование MEV устойчивости

```solidity
function testMEVResistance() public {
    // Симуляция sandwich атак
    // Проверка защиты от манипуляций
}
```

### Стресс тестирование

```solidity
function testExtremeMarketConditions() public {
    // Тестирование в периоды высокой волатильности
    // Использование исторических данных критических событий
}
```

### Кросс-чейн арбитраж

```solidity
function testCrossChainArbitrage() public {
    // Концептуальное тестирование возможностей
    // между разными блокчейнами
}
```

## Автоматизация

### CI/CD интеграция

```yaml
# .github/workflows/tests.yml
name: Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
      - name: Run tests
        run: ./test-runner.sh all
```

### Pre-commit хуки

```bash
# .git/hooks/pre-commit
#!/bin/bash
./test-runner.sh unit
```

## Рекомендации

1. **Всегда запускайте unit тесты** перед коммитами
2. **Используйте форк тесты** для проверки интеграции
3. **Мониторьте потребление газа** регулярно
4. **Тестируйте граничные случаи** с фаззингом
5. **Проверяйте поведение** на исторических данных

## Troubleshooting

### Проблемы с RPC

- Используйте альтернативные RPC провайдеры
- Проверьте лимиты запросов
- Попробуйте разные блоки для форка

### Проблемы с памятью

- Уменьшите количество фаззинг запусков
- Используйте более поздние блоки для форка
- Очистите кэш: `forge clean`

### Проблемы с компиляцией

- Проверьте версии solidity
- Обновите зависимости: `forge update`
- Проверьте remappings в foundry.toml
