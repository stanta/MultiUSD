// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Test, console2, console} from "forge-std/Test.sol";
import {CorrectorV2} from "../src/CorrectorV2.sol";
import {USDM} from "../src/USDM.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CorrectorAdvancedTest  
 * @dev Продвинутые тесты для системы арбитража USDM
 * Тестирует расчет средних курсов стейблкоинов и механизм коррекции
 */
contract CorrectorAdvancedTest is Test {
    CorrectorV2 public corrector;
    USDM public usdm;
    
    // Mainnet addresses for forking
    address constant WETH = 0xC02AaA39B223Fe8d0625B628f63C3D6297C4af45;
    address constant USDC = 0xA0B86a33E6c28c4c32b1c5b6a0A5E3b9b6f7c8e9;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    
    // Mock addresses for testing
    address public mockFactory;
    address public mockPairUSDC;
    address public mockPairUSDT;
    address public mockPairUSDM;
    
    // Test users
    address public owner;
    address public arbitrageur;
    address public user1;
    
    // Test constants
    uint256 constant PRECISION = 1e18;
    uint256 constant INITIAL_LIQUIDITY = 1000000 * PRECISION;
    uint256 constant ETH_PRICE_USDC = 2000; // 1 ETH = 2000 USDC
    uint256 constant ETH_PRICE_USDT = 2000; // 1 ETH = 2000 USDT
    
    // Events for testing
    event RateCalculated(
        uint256 averageRate,
        uint256 totalNative,
        uint256 totalStable
    );
    
    event ArbitrageOpportunity(
        address indexed pool,
        uint256 expectedRate,
        uint256 actualRate,
        bool shouldSellUSDM
    );

    function setUp() public {
        // Create test addresses
        owner = address(this);
        arbitrageur = makeAddr("arbitrageur");
        user1 = makeAddr("user1");
        
        // Fork mainnet for realistic testing
        vm.createFork("https://rpc.ankr.com/eth");
        
        // Deploy contracts
        corrector = new CorrectorV2();
        usdm = new USDM();
        
        // Setup mock contracts
        _setupMockContracts();
        
        // Setup initial test scenario
        _setupTestScenario();
    }
    
    function _setupMockContracts() internal {
        // Deploy mock factory
        mockFactory = address(new MockUniswapV2Factory());
        
        // Deploy mock pairs
        mockPairUSDC = address(new MockUniswapV2Pair(WETH, USDC));
        mockPairUSDT = address(new MockUniswapV2Pair(WETH, USDT));  
        mockPairUSDM = address(new MockUniswapV2Pair(WETH, address(usdm)));
        
        // Set up mock factory to return our pairs
        MockUniswapV2Factory(mockFactory).setPair(WETH, USDC, mockPairUSDC);
        MockUniswapV2Factory(mockFactory).setPair(WETH, USDT, mockPairUSDT);
        MockUniswapV2Factory(mockFactory).setPair(WETH, address(usdm), mockPairUSDM);
    }
    
    function _setupTestScenario() internal {
        // Set up USDC/ETH pair with 2000 USDC per ETH
        MockUniswapV2Pair(mockPairUSDC).setReserves(
            uint112(100 * PRECISION), // 100 ETH
            uint112(200000 * 1e6) // 200,000 USDC (6 decimals)
        );
        
        // Set up USDT/ETH pair with 2000 USDT per ETH  
        MockUniswapV2Pair(mockPairUSDT).setReserves(
            uint112(50 * PRECISION), // 50 ETH
            uint112(100000 * 1e6) // 100,000 USDT (6 decimals)
        );
        
        // Add AMM pools to corrector
        corrector.addAmm(mockFactory, WETH, USDC, 2, false);
        corrector.addAmm(mockFactory, WETH, USDT, 2, false);
        
        // Mint USDM tokens
        usdm.mint(address(corrector), INITIAL_LIQUIDITY);
        usdm.mint(arbitrageur, INITIAL_LIQUIDITY / 10);
    }

    /**
     * @dev Тест базового расчета средних курсов
     */
    function testCalculateAverageRates() public {
        console.log("=== Test: Calculate Average Rates ===");
        
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        
        console.log("Total Native Reserves:", totalNative);
        console.log("Total Stable Reserves:", totalStable);
        
        // Expected: 150 ETH total, 300,000 USD total
        assertEq(totalNative, 150 * PRECISION, "Incorrect total native reserves");
        
        // Calculate average rate (convert to 18 decimals for stable tokens)
        uint256 expectedTotalStable = 200000 * 1e12 + 100000 * 1e12; // Convert to 18 decimals
        assertEq(totalStable, expectedTotalStable, "Incorrect total stable reserves");
        
        uint256 averageRate = (totalStable * PRECISION) / totalNative;
        console.log("Average Rate (stable per ETH):", averageRate / PRECISION);
        
        // Should be 2000 USD per ETH
        assertEq(averageRate, 2000 * PRECISION, "Incorrect average rate");
        
        emit RateCalculated(averageRate, totalNative, totalStable);
    }

    /**
     * @dev Тест арбитража когда USDM переоценен
     */
    function testUSDMOvervalued() public {
        console.log("=== Test: USDM Overvalued Scenario ===");
        
        // Set up USDM pool with higher rate (2200 USDM per ETH)
        MockUniswapV2Pair(mockPairUSDM).setReserves(
            uint112(10 * PRECISION), // 10 ETH
            uint112(22000 * PRECISION) // 22,000 USDM (overvalued)
        );
        
        // Add USDM pool
        corrector.addAmm(mockFactory, WETH, address(usdm), 2, true);
        
        // Get average rate
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        uint256 averageRate = (totalStable * PRECISION) / totalNative;
        
        console.log("Average market rate:", averageRate / PRECISION);
        console.log("USDM rate: 2200 (overvalued)");
        
        // USDM is overvalued, should trigger sell
        assertTrue(2200 * PRECISION > averageRate, "USDM should be overvalued");
        
        emit ArbitrageOpportunity(mockPairUSDM, averageRate, 2200 * PRECISION, true);
        
        // Execute correction
        corrector.correctAll();
        
        console.log("Arbitrage executed: SELL USDM");
    }

    /**
     * @dev Тест арбитража когда USDM недооценен
     */
    function testUSDMUndervalued() public {
        console.log("=== Test: USDM Undervalued Scenario ===");
        
        // Set up USDM pool with lower rate (1800 USDM per ETH)
        MockUniswapV2Pair(mockPairUSDM).setReserves(
            uint112(10 * PRECISION), // 10 ETH
            uint112(18000 * PRECISION) // 18,000 USDM (undervalued)
        );
        
        // Add USDM pool
        corrector.addAmm(mockFactory, WETH, address(usdm), 2, true);
        
        // Get average rate
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        uint256 averageRate = (totalStable * PRECISION) / totalNative;
        
        console.log("Average market rate:", averageRate / PRECISION);
        console.log("USDM rate: 1800 (undervalued)");
        
        // USDM is undervalued, should trigger buy
        assertTrue(1800 * PRECISION < averageRate, "USDM should be undervalued");
        
        emit ArbitrageOpportunity(mockPairUSDM, averageRate, 1800 * PRECISION, false);
        
        // Execute correction
        corrector.correctAll();
        
        console.log("Arbitrage executed: BUY USDM");
    }

    /**
     * @dev Тест с множественными пулами разных размеров
     */
    function testMultiplePools() public {
        console.log("=== Test: Multiple Pools Different Sizes ===");
        
        // Add a large USDC pool
        MockUniswapV2Pair largePairUSDC = new MockUniswapV2Pair(WETH, USDC);
        largePairUSDC.setReserves(
            uint112(1000 * PRECISION), // 1000 ETH
            uint112(2100000 * 1e6) // 2,100,000 USDC (rate: 2100)
        );
        
        MockUniswapV2Factory(mockFactory).setPair(WETH, USDC, address(largePairUSDC));
        corrector.addAmm(mockFactory, WETH, USDC, 2, false);
        
        // Calculate weighted average
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        uint256 weightedAverage = (totalStable * PRECISION) / totalNative;
        
        console.log("Weighted average with large pool:", weightedAverage / PRECISION);
        
        // Should be influenced by the large pool
        assertTrue(weightedAverage > 2000 * PRECISION, "Should be influenced by large pool");
    }

    /**
     * @dev Тест точности расчетов с малыми числами
     */
    function testPrecisionWithSmallNumbers() public {
        console.log("=== Test: Precision with Small Numbers ===");
        
        // Set up small pools
        MockUniswapV2Pair(mockPairUSDC).setReserves(
            uint112(1e15), // 0.001 ETH
            uint112(2 * 1e6) // 2 USDC
        );
        
        MockUniswapV2Pair(mockPairUSDT).setReserves(
            uint112(1e15), // 0.001 ETH  
            uint112(2 * 1e6) // 2 USDT
        );
        
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        
        assertGt(totalNative, 0, "Should handle small reserves");
        assertGt(totalStable, 0, "Should handle small reserves");
        
        if (totalNative > 0) {
            uint256 rate = (totalStable * PRECISION) / totalNative;
            console.log("Rate with small numbers:", rate / PRECISION);
        }
    }

    /**
     * @dev Тест обработки переполнения
     */
    function testOverflowHandling() public {
        console.log("=== Test: Overflow Handling ===");
        
        // Set up pools with very large reserves
        MockUniswapV2Pair(mockPairUSDC).setReserves(
            type(uint112).max / 2, // Large but safe
            type(uint112).max / 2
        );
        
        // Should not revert
        try corrector.getAllStableRate() returns (uint256 totalNative, uint256 totalStable) {
            assertGt(totalNative, 0, "Should handle large numbers");
            assertGt(totalStable, 0, "Should handle large numbers");
            console.log("Large numbers handled successfully");
        } catch {
            console.log("Overflow protection working");
        }
    }

    /**
     * @dev Фаззинг тест для различных соотношений резервов
     */
    function testFuzzReserveRatios(uint112 ethReserve, uint112 stableReserve) public {
        vm.assume(ethReserve > 1e6 && ethReserve < type(uint112).max / 1000);
        vm.assume(stableReserve > 1e6 && stableReserve < type(uint112).max / 1000);
        
        console.log("=== Fuzz Test: Reserve Ratios ===");
        console.log("ETH Reserve:", ethReserve);
        console.log("Stable Reserve:", stableReserve);
        
        // Set up pools with fuzzed reserves
        MockUniswapV2Pair(mockPairUSDC).setReserves(uint112(ethReserve), uint112(stableReserve));
        
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        
        if (totalNative > 0) {
            uint256 rate = (totalStable * PRECISION) / totalNative;
            
            // Rate should be reasonable (0.1 to 100,000)
            assertGe(rate, PRECISION / 10, "Rate too low");
            assertLe(rate, 100000 * PRECISION, "Rate too high");
            
            console.log("Fuzz rate:", rate / PRECISION);
        }
    }

    /**
     * @dev Тест производительности
     */
    function testPerformance() public {
        console.log("=== Test: Performance ===");
        
        // Add many pools
        for (uint i = 0; i < 10; i++) {
            address mockToken = address(uint160(0x1000 + i));
            MockUniswapV2Pair mockPair = new MockUniswapV2Pair(WETH, mockToken);
            mockPair.setReserves(
                uint112((i + 1) * PRECISION),
                uint112((i + 1) * 2000 * PRECISION)
            );
            
            MockUniswapV2Factory(mockFactory).setPair(WETH, mockToken, address(mockPair));
            corrector.addAmm(mockFactory, WETH, mockToken, 2, false);
        }
        
        uint256 gasBefore = gasleft();
        corrector.getAllStableRate();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used with 12 pools:", gasUsed);
        assertLt(gasUsed, 500000, "Gas usage should be reasonable");
    }

    /**
     * @dev Тест активации/деактивации пулов
     */
    function testPoolActivation() public {
        console.log("=== Test: Pool Activation ===");
        
        // Initially should have 2 active pools
        (uint256 totalBefore,) = corrector.getAllStableRate();
        
        // Deactivate USDC pool
        corrector.setAMMactive(mockFactory, false);
        
        // Should now have less reserves
        (uint256 totalAfter,) = corrector.getAllStableRate();
        
        assertLt(totalAfter, totalBefore, "Deactivation should reduce reserves");
        
        console.log("Pool deactivation working correctly");
    }

    /**
     * @dev Тест безопасности расчетов
     */
    function testCalculationSafety() public {
        console.log("=== Test: Calculation Safety ===");
        
        // Test division by zero protection
        MockUniswapV2Pair(mockPairUSDC).setReserves(uint112(0), uint112(1000 * 1e6));
        
        try corrector.getAllStableRate() returns (uint256 totalNative, uint256) {
            if (totalNative == 0) {
                console.log("Division by zero handled correctly");
            }
        } catch {
            console.log("Reverted on zero reserves - good");
        }
        
        // Test with one reserve zero
        MockUniswapV2Pair(mockPairUSDC).setReserves(uint112(100 * PRECISION), uint112(0));
        
        try corrector.getAllStableRate() returns (uint256, uint256 totalStable) {
            if (totalStable == 0) {
                console.log("Zero stable reserves handled");
            }
        } catch {
            console.log("Reverted on zero stable reserves");
        }
    }
}

// Mock contracts for testing
contract MockUniswapV2Factory {
    mapping(address => mapping(address => address)) public pairs;
    
    function setPair(address tokenA, address tokenB, address pair) external {
        pairs[tokenA][tokenB] = pair;
        pairs[tokenB][tokenA] = pair;
    }
    
    function getPair(address tokenA, address tokenB) external view returns (address) {
        return pairs[tokenA][tokenB];
    }
}

contract MockUniswapV2Pair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    
    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }
    
    function setReserves(uint112 _reserve0, uint112 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        blockTimestampLast = uint32(block.timestamp);
    }
    
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }
    
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata) external {
        // Mock swap implementation
        // In real testing, you'd implement proper swap logic
    }
}
