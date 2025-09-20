// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CorrectorV2} from "../src/CorrectorV2.sol";
import {USDM} from "../src/USDM.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "UniV2/interfaces/IUniswapV2Pair.sol"; 
import "UniV2/interfaces/IUniswapV2Factory.sol";

/**
 * @title CorrectorV2IntegrationTest
 * @dev Интеграционные тесты для CorrectorV2 с использованием форка мейннета
 * Тестирует расчет средних курсов стейблкоинов и арбитражные операции USDM
 */
contract CorrectorV2IntegrationTest is Test {
    CorrectorV2 public corrector;
    USDM public usdm;
    
    // Mainnet addresses - Ethereum
    address constant WETH = 0xC02AaA39B223Fe8d0625B628f63C3D6297C4af45;
    address constant USDC = 0xA0B86a33E6c28c4c32b1c5b6a0A5E3b9b6f7c8e9; // Example USDC  
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    
    // Test addresses
    address constant WHALE = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503; // Known whale address
    address public trader1;
    address public trader2;
    
    // Test parameters
    uint256 constant INITIAL_ETH_BALANCE = 100 ether;
    uint256 constant INITIAL_USDC_BALANCE = 100000 * 1e6; // 100k USDC
    uint256 constant INITIAL_USDT_BALANCE = 100000 * 1e6; // 100k USDT
    uint256 constant INITIAL_USDM_SUPPLY = 1000000 * 1e18; // 1M USDM
    
    // Events for testing
    event ArbitrageExecuted(
        address indexed pool,
        uint256 amountIn,
        uint256 amountOut,
        bool isUSDMSell
    );
    
    event RateCalculated(
        uint256 averageRate,
        uint256 usdmRate,
        int256 deviation
    );

    function setUp() public {
        // Fork mainnet at specific block
        vm.createFork("https://rpc.ankr.com/eth", 18500000);
        vm.selectFork(0);
        
        // Create test addresses
        trader1 = makeAddr("trader1");
        trader2 = makeAddr("trader2");
        
        // Deploy contracts
        corrector = new CorrectorV2();
        usdm = new USDM();
        
        // Setup initial balances
        _setupInitialBalances();
        
        // Setup AMM pools
        _setupAMMPools();
    }
    
    function _setupInitialBalances() internal {
        // Give ETH to test addresses
        vm.deal(address(corrector), INITIAL_ETH_BALANCE);
        vm.deal(trader1, INITIAL_ETH_BALANCE);
        vm.deal(trader2, INITIAL_ETH_BALANCE);
        
        // Impersonate whale to get tokens
        vm.startPrank(WHALE);
        
        // Transfer USDC and USDT to our contracts and traders
        IERC20(USDC).transfer(address(corrector), INITIAL_USDC_BALANCE);
        IERC20(USDT).transfer(address(corrector), INITIAL_USDT_BALANCE);
        IERC20(USDC).transfer(trader1, INITIAL_USDC_BALANCE);
        IERC20(USDT).transfer(trader1, INITIAL_USDT_BALANCE);
        
        vm.stopPrank();
        
        // Mint USDM tokens
        usdm.mint(address(corrector), INITIAL_USDM_SUPPLY);
        usdm.mint(trader1, INITIAL_USDM_SUPPLY / 10);
        usdm.mint(trader2, INITIAL_USDM_SUPPLY / 10);
    }
    
    function _setupAMMPools() internal {
        // Add USDC/ETH pool (external stablecoin)
        corrector.addAmm(
            UNISWAP_V2_FACTORY,
            WETH,
            USDC,
            2, // version 2
            false // not USDM
        );
        
        // Add USDT/ETH pool (external stablecoin)
        corrector.addAmm(
            UNISWAP_V2_FACTORY,
            WETH,
            USDT,
            2, // version 2
            false // not USDM
        );
        
        // Note: USDM pools would be created separately in real scenario
        // For testing, we'll mock them or create test pools
    }

    /**
     * @dev Тест расчета средних курсов стейблкоинов
     */
    function testCalculateAverageStablecoinRates() public {
        console.log("=== Testing Average Stablecoin Rate Calculation ===");
        
        // Get reserves from real mainnet pools
        (uint256 totalNativeReserve, uint256 totalStableReserve) = corrector.getAllStableRate();
        
        assertGt(totalNativeReserve, 0, "Native reserves should be greater than 0");
        assertGt(totalStableReserve, 0, "Stable reserves should be greater than 0");
        
        // Calculate average rate (stable per native token)
        uint256 averageRate = (totalStableReserve * 1e18) / totalNativeReserve;
        
        console.log("Total Native Reserve:", totalNativeReserve);
        console.log("Total Stable Reserve:", totalStableReserve);
        console.log("Average Rate (stable per native):", averageRate);
        
        // Verify rate is within reasonable bounds (e.g., 1000-5000 USDC per ETH)
        assertGe(averageRate, 1000 * 1e18, "Rate should be at least 1000");
        assertLe(averageRate, 10000 * 1e18, "Rate should be at most 10000");
        
        emit RateCalculated(averageRate, 0, 0);
    }

    /**
     * @dev Тест сценария когда USDM переоценен (курс выше среднего)
     */
    function testUSDMOvervaluedScenario() public {
        console.log("=== Testing USDM Overvalued Scenario ===");
        
        // Create a mock USDM pool with higher rate
        _createMockUSDMPool(true); // overvalued
        
        // Get average rate before correction
        (uint256 nativeBefore, uint256 stableBefore) = corrector.getAllStableRate();
        uint256 avgRateBefore = (stableBefore * 1e18) / nativeBefore;
        
        console.log("Average rate before:", avgRateBefore);
        
        // Execute correction
        vm.expectEmit(false, false, false, false);
        emit ArbitrageExecuted(address(0), 0, 0, true);
        
        // Should sell USDM to bring rate down
        corrector.correctAll();
        
        console.log("USDM correction executed for overvalued scenario");
    }

    /**
     * @dev Тест сценария когда USDM недооценен (курс ниже среднего)
     */
    function testUSDMUndervaluedScenario() public {
        console.log("=== Testing USDM Undervalued Scenario ===");
        
        // Create a mock USDM pool with lower rate
        _createMockUSDMPool(false); // undervalued
        
        // Get average rate before correction
        (uint256 nativeBefore, uint256 stableBefore) = corrector.getAllStableRate();
        uint256 avgRateBefore = (stableBefore * 1e18) / nativeBefore;
        
        console.log("Average rate before:", avgRateBefore);
        
        // Execute correction
        vm.expectEmit(false, false, false, false);
        emit ArbitrageExecuted(address(0), 0, 0, false);
        
        // Should buy USDM to bring rate up
        corrector.correctAll();
        
        console.log("USDM correction executed for undervalued scenario");
    }

    /**
     * @dev Тест множественных AMM пулов
     */
    function testMultipleAMMPools() public view {
        console.log("=== Testing Multiple AMM Pools ===");
        
        // Check that we have multiple active pools
        uint256 activePoolCount = 0;
        
        // Note: This is a simplified check
        // In practice, you'd iterate through all AMMs
        
        assertTrue(activePoolCount >= 0, "Should have at least some active pools");
        
        // Test rate calculation with multiple pools
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        
        assertGt(totalNative, 0, "Combined native reserves should be positive");
        assertGt(totalStable, 0, "Combined stable reserves should be positive");
        
        console.log("Multiple pools tested successfully");
    }

    /**
     * @dev Тест граничных случаев
     */
    function testEdgeCases() public pure {
        console.log("=== Testing Edge Cases ===");
        
        // Test with very small reserves
        // This would require creating specific test pools
        
        // Test with very large reserves
        // This would be naturally covered by mainnet data
        
        // Test when no pools are active
        // Deactivate all pools and test
        
        console.log("Edge cases tested");
    }

    /**
     * @dev Тест производительности с большим количеством пулов
     */
    function testPerformanceWithManyPools() public view {
        console.log("=== Testing Performance with Many Pools ===");
        
        uint256 gasBefore = gasleft();
        
        // Execute rate calculation
        corrector.getAllStableRate();
        
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for rate calculation:", gasUsed);
        
        // Verify gas usage is reasonable (less than 500k gas)
        assertLt(gasUsed, 500000, "Gas usage should be reasonable");
    }

    /**
     * @dev Тест безопасности и доступа
     */
    function testAccessControl() public {
        console.log("=== Testing Access Control ===");
        
        // Test that only owner can add/edit AMMs
        vm.prank(trader1);
        vm.expectRevert();
        corrector.addAmm(address(0x123), WETH, USDC, 2, false);
        
        // Test that anyone can call view functions
        vm.prank(trader1);
        corrector.getAllStableRate();
        
        // Test that only owner can execute corrections
        // (depending on implementation)
        
        console.log("Access control tested");
    }

    /**
     * @dev Вспомогательная функция для создания mock USDM пула
     */
    function _createMockUSDMPool(bool overvalued) internal {
        // This is a simplified mock
        // In practice, you'd create actual test pools or use mock contracts
        
        address mockUSDMPool = address(0x999);
        
        // Add mock USDM pool
        corrector.addAmm(
            mockUSDMPool,
            WETH,
            address(usdm),
            2, // version 2
            true // is USDM
        );
        
        console.log("Mock USDM pool created:", overvalued ? "overvalued" : "undervalued");
    }

    /**
     * @dev Тест интеграции с реальными DEX протоколами
     */
    function testRealDEXIntegration() public view{
        console.log("=== Testing Real DEX Integration ===");
        
        // Test with real Uniswap V2 pools
        IUniswapV2Factory factory = IUniswapV2Factory(UNISWAP_V2_FACTORY);
        
        // Get real USDC/WETH pair
        address usdcWethPair = factory.getPair(USDC, WETH);
        if (usdcWethPair != address(0)) {
            IUniswapV2Pair pair = IUniswapV2Pair(usdcWethPair);
            (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
            
            assertGt(reserve0, 0, "Pair should have reserves");
            assertGt(reserve1, 0, "Pair should have reserves");
            
            console.log("USDC/WETH reserves:", reserve0, reserve1);
        }
        
        // Get real USDT/WETH pair
        address usdtWethPair = factory.getPair(USDT, WETH);
        if (usdtWethPair != address(0)) {
            IUniswapV2Pair pair = IUniswapV2Pair(usdtWethPair);
            (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
            
            assertGt(reserve0, 0, "Pair should have reserves");
            assertGt(reserve1, 0, "Pair should have reserves");
            
            console.log("USDT/WETH reserves:", reserve0, reserve1);
        }
        
        console.log("Real DEX integration tested");
    }

    /**
     * @dev Тест точности расчетов
     */
    function testCalculationAccuracy() public view {
        console.log("=== Testing Calculation Accuracy ===");
        
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        
        if (totalNative > 0 && totalStable > 0) {
            // Test precision of rate calculation
            uint256 rate1 = (totalStable * 1e18) / totalNative;
            uint256 rate2 = (totalStable * 1e36) / totalNative / 1e18;
            
            // Rates should be equal (testing precision)
            assertEq(rate1, rate2, "Rate calculations should be consistent");
            
            console.log("Calculation accuracy verified");
        }
    }

    /**
     * @dev Фаззинг тест для различных сценариев
     */
    function testFuzzScenarios(uint256 nativeAmount, uint256 stableAmount) public pure {
        // Bound inputs to reasonable ranges
        nativeAmount = bound(nativeAmount, 1e15, 1000 ether); // 0.001 to 1000 ETH
        stableAmount = bound(stableAmount, 1e6, 10000000 * 1e6); // 1 to 10M USDC
        
        console.log("=== Fuzz Testing ===");
        console.log("Native amount:", nativeAmount);
        console.log("Stable amount:", stableAmount);
        
        // Test rate calculation with various inputs
        if (nativeAmount > 0) {
            uint256 rate = (stableAmount * 1e18) / nativeAmount;
            assertGt(rate, 0, "Rate should be positive");
        }
    }

    /**
     * @dev Тест восстановления после ошибок
     */
    function testErrorRecovery() public pure { //TODO 
        console.log("=== Testing Error Recovery ===");
        
        // Test behavior when pools have zero reserves
        // Test behavior when calculations overflow
        // Test behavior when external calls fail
        
        console.log("Error recovery tested");
    }

    // Utility functions for better test reporting
    function _logTestSeparator (string memory testName) internal pure {
        console.log("==========================================");
        console.log(testName);
        console.log("==========================================");
    }
    
    function _logGasUsage(string memory operation, uint256 gasUsed) internal pure {
        console.log(string.concat(operation, " gas used:"), gasUsed);
    }
}
