// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Corrector} from "../src/Corrector.sol";
import {USDM} from "../src/USDM.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


/**
 * @title MockERC20
 * @dev Mock ERC20 для тестирования
 */
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/**
 * @title MockUniswapV2Pair
 * @dev Mock Uniswap V2 Pair для тестирования
 */
contract MockUniswapV2Pair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    
    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
        blockTimestampLast = uint32(block.timestamp);
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
        if (amount0Out > 0) {
            MockERC20(token0).mint(to, amount0Out);
        }
        if (amount1Out > 0) {
            MockERC20(token1).mint(to, amount1Out);
        }
    }
}

/**
 * @title MockUniswapV2Factory
 * @dev Mock Uniswap V2 Factory для тестирования
 */
contract MockUniswapV2Factory {
    mapping(address => mapping(address => address)) public pairs;
    address[] public allPairs;
    
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "Identical tokens");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "Zero address");
        require(pairs[token0][token1] == address(0), "Pair exists");
        
        pair = address(new MockUniswapV2Pair(token0, token1));
        pairs[token0][token1] = pair;
        pairs[token1][token0] = pair;
        allPairs.push(pair);
    }
    
    function getPair(address tokenA, address tokenB) external view returns (address) {
        return pairs[tokenA][tokenB];
    }
    
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }
}

/**
 * @title CorrectorUnitTest
 * @dev Unit тесты для Corrector с mock контрактами
 */
contract CorrectorUnitTest is Test {
    Corrector public corrector;
    USDM public usdm;
    MockUniswapV2Factory public factory;
    
    MockERC20 public weth;
    MockERC20 public usdc;
    MockERC20 public usdt;
    
    MockUniswapV2Pair public usdcWethPair;
    MockUniswapV2Pair public usdtWethPair;
    MockUniswapV2Pair public usdmWethPair;
    
    address public owner;
    address public trader;
    
    // Test constants
    uint256 constant INITIAL_RESERVES_ETH = 100 ether;
    uint256 constant INITIAL_RESERVES_USDC = 300000 * 1e6; // 300k USDC (rate: 3000 USDC/ETH)
    uint256 constant INITIAL_RESERVES_USDT = 310000 * 1e6; // 310k USDT (rate: 3100 USDT/ETH)
    uint256 constant INITIAL_RESERVES_USDM = 280000 * 1e18; // 280k USDM (rate: 2800 USDM/ETH - undervalued)

    function setUp() public {
        owner = address(this);
        trader = makeAddr("trader");
        
        // Deploy contracts
        corrector = new Corrector();
        usdm = new USDM();
        factory = new MockUniswapV2Factory();
        
        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH");
        usdc = new MockERC20("USD Coin", "USDC");
        usdt = new MockERC20("Tether USD", "USDT");
        
        // Create pairs
        usdcWethPair = MockUniswapV2Pair(factory.createPair(address(weth), address(usdc)));
        usdtWethPair = MockUniswapV2Pair(factory.createPair(address(weth), address(usdt)));
        usdmWethPair = MockUniswapV2Pair(factory.createPair(address(weth), address(usdm)));
        
        // Set initial reserves
        _setupInitialReserves();
        
        // Add AMMs to corrector
        _setupAMMs();
        
        // Mint tokens for testing
        _mintTestTokens();
    }
    
    function _setupInitialReserves() internal {
        // USDC/WETH pair: 3000 USDC per ETH
        usdcWethPair.setReserves(
            uint112(INITIAL_RESERVES_ETH),
            uint112(INITIAL_RESERVES_USDC)
        );
        
        // USDT/WETH pair: 3100 USDT per ETH
        usdtWethPair.setReserves(
            uint112(INITIAL_RESERVES_ETH),
            uint112(INITIAL_RESERVES_USDT)
        );
        
        // USDM/WETH pair: 2800 USDM per ETH (undervalued)
        usdmWethPair.setReserves(
            uint112(INITIAL_RESERVES_ETH),
            uint112(INITIAL_RESERVES_USDM)
        );
    }
    
    function _setupAMMs() internal {
        // Add external stablecoin pools
        corrector.addAmm(
            address(factory),
            address(weth),
            address(usdc),
            2, // version
            false // not USDM
        );
        
        corrector.addAmm(
            address(factory),
            address(weth),
            address(usdt),
            2, // version
            false // not USDM
        );
        
        // Add USDM pool
        corrector.addAmm(
            address(factory),
            address(weth),
            address(usdm),
            2, // version
            true // is USDM
        );
    }
    
    function _mintTestTokens() internal {
        uint256 mintAmount = 10000000 * 1e18; // 10M tokens
        
        weth.mint(address(corrector), mintAmount);
        usdc.mint(address(corrector), mintAmount);
        usdt.mint(address(corrector), mintAmount);
        usdm.mint(address(corrector), mintAmount);
        
        weth.mint(trader, mintAmount);
        usdc.mint(trader, mintAmount);
        usdt.mint(trader, mintAmount);
        usdm.mint(trader, mintAmount);
    }

    /**
     * @dev Тест базового расчета средних курсов
     */
    function testGetAllStableRateBasic() public view {
        console.log("=== Test Basic Average Rate Calculation ===");
        
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        
        // Expected: ETH + ETH = 200 ETH, USDC + USDT = 610k stable
        uint256 expectedNative = INITIAL_RESERVES_ETH * 2; // Two pools
        uint256 expectedStable = INITIAL_RESERVES_USDC + INITIAL_RESERVES_USDT;
        
        assertEq(totalNative, expectedNative, "Total native reserves should match");
        assertEq(totalStable, expectedStable, "Total stable reserves should match");
        
        // Calculate average rate
        uint256 averageRate = (totalStable * 1e18) / totalNative;
        uint256 expectedAverage = (610000 * 1e6 * 1e18) / (200 ether); // 3050 per ETH
        
        assertEq(averageRate, expectedAverage, "Average rate should be 3050");
        
        console.log("Total Native:", totalNative);
        console.log("Total Stable:", totalStable); 
        console.log("Average Rate:", averageRate);
    }

    /**
     * @dev Тест сценария недооцененного USDM
     */
    function testUSDMUndervaluedCorrection() public {
        console.log("=== Test USDM Undervalued Correction ===");
        
        // Get initial rates
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        uint256 averageRate = (totalStable * 1e18) / totalNative; // 3050 USDC/ETH
        
        // USDM current rate: 2800 USDM/ETH (undervalued vs 3050 average)
        console.log("Average market rate:", averageRate);
        console.log("USDM rate: 2800 (undervalued)");
        
        // Execute correction
        uint256 gasBefore = gasleft();
        corrector.correctAll();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for correction:", gasUsed);
        console.log("USDM correction executed for undervalued scenario");
        
        // Verify gas usage is reasonable
        assertLt(gasUsed, 1000000, "Gas usage should be reasonable");
    }

    /**
     * @dev Тест сценария переоцененного USDM
     */
    function testUSDMOvervaluedCorrection() public {
        console.log("=== Test USDM Overvalued Correction ===");
        
        // Set USDM to be overvalued (3500 USDM per ETH vs 3050 average)
        usdmWethPair.setReserves(
            uint112(INITIAL_RESERVES_ETH),
            uint112(350000 * 1e18) // 3500 USDM/ETH - overvalued
        );
        
        // Get rates
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        uint256 averageRate = (totalStable * 1e18) / totalNative;
        
        console.log("Average market rate:", averageRate);
        console.log("USDM rate: 3500 (overvalued)");
        
        // Execute correction
        corrector.correctAll();
        
        console.log("USDM correction executed for overvalued scenario");
    }

    /**
     * @dev Тест добавления и управления AMM пулами
     */
    function testAMMManagement() public {
        console.log("=== Test AMM Management ===");
        
        // Test adding new AMM
        address newFactory = address(0x123);
        corrector.addAmm(newFactory, address(weth), address(usdc), 3, false);
        
        // Test editing existing AMM
        corrector.editAMM(
            address(factory),
            address(weth), 
            address(usdc),
            2,
            false
        );
        
        // Test deactivating AMM
        corrector.setAMMactive(address(factory), false);
        
        // Test that deactivated AMM doesn't contribute to rates
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        
        // Should only include USDT pool now (USDC pool deactivated)
        assertEq(totalNative, INITIAL_RESERVES_ETH, "Should only have USDT pool reserves");
        assertEq(totalStable, INITIAL_RESERVES_USDT, "Should only have USDT pool reserves");
        
        console.log("AMM management tested successfully");
    }

    /**
     * @dev Тест расчетов арбитража
     */
    function testArbitrageCalculations() public {
        console.log("=== Test Arbitrage Calculations ===");
        
        // Create scenario where USDM is significantly undervalued
        usdmWethPair.setReserves(
            uint112(100 ether), // 100 ETH
            uint112(250000 * 1e18) // 250k USDM = 2500 USDM/ETH
        );
        
        // Average should be (300k + 310k) / (100 + 100) = 3050
        // USDM is at 2500, so should buy USDM (sell ETH for USDM)
        
        (uint256 avgNative, uint256 avgStable) = corrector.getAllStableRate();
        uint256 avgRate = (avgStable * 1e18) / avgNative;
        
        console.log("Average rate:", avgRate);
        console.log("USDM rate: 2500 (significantly undervalued)");
        
        // Execute correction and verify it doesn't revert
        corrector.correctAll();
        
        console.log("Arbitrage calculations completed");
    }

    /**
     * @dev Тест edge cases
     */
    function testEdgeCases() public {
        console.log("=== Test Edge Cases ===");
        
        // Test with zero reserves
        usdcWethPair.setReserves(0, 0);
        
        // Should handle gracefully
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        assertEq(totalNative, INITIAL_RESERVES_ETH, "Should only count non-zero reserves");
        assertEq(totalStable, INITIAL_RESERVES_USDT, "Should only count non-zero reserves");
        
        // Test with very large numbers
        usdcWethPair.setReserves(
            uint112(type(uint112).max),
            uint112(type(uint112).max)
        );
        
        // Should not overflow
        corrector.getAllStableRate();
        
        console.log("Edge cases handled successfully");
    }

    /**
     * @dev Тест контроля доступа
     */
    function testAccessControl() public {
        console.log("=== Test Access Control ===");
        
        // Test that non-owner cannot add AMM
        vm.prank(trader);
        vm.expectRevert();
        corrector.addAmm(address(0x456), address(weth), address(usdc), 2, false);
        
        // Test that non-owner cannot edit AMM
        vm.prank(trader);
        vm.expectRevert();
        corrector.editAMM(address(factory), address(weth), address(usdc), 2, false);
        
        // Test that non-owner cannot deactivate AMM
        vm.prank(trader);
        vm.expectRevert();
        corrector.setAMMactive(address(factory), false);
        
        // Test that anyone can read rates
        vm.prank(trader);
        corrector.getAllStableRate();
        
        // Test that anyone can execute corrections (if intended)
        vm.prank(trader);
        corrector.correctAll();
        
        console.log("Access control working correctly");
    }

    /**
     * @dev Фаззинг тест для различных резервов
     */
    function testFuzzReserves(uint112 reserve0, uint112 reserve1) public {
        // Bound to reasonable ranges
        reserve0 = uint112(bound(reserve0, 1e15, 1000 ether));
        reserve1 = uint112(bound(reserve1, 1e15, 1000000 * 1e18));
        
        // Set new reserves
        usdcWethPair.setReserves(reserve0, reserve1);
        
        // Should not revert
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        
        // Basic sanity checks
        assertGe(totalNative, uint256(reserve0), "Total native should include new reserves");
        assertGe(totalStable, uint256(reserve1), "Total stable should include new reserves");
    }

    /**
     * @dev Тест производительности
     */
    function testPerformance() public {
        console.log("=== Test Performance ===");
        
        // Add many AMM pools
        for (uint i = 0; i < 50; i++) {
            address mockFactory = address(uint160(0x1000 + i));
            corrector.addAmm(mockFactory, address(weth), address(usdc), 2, false);
        }
        
        // Measure gas for rate calculation
        uint256 gasBefore = gasleft();
        corrector.getAllStableRate();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used with 50+ pools:", gasUsed);
        
        // Should be reasonable even with many pools
        assertLt(gasUsed, 2000000, "Should handle many pools efficiently");
    }

    /**
     * @dev Тест математической точности
     */
    function testMathematicalPrecision() public {
        console.log("=== Test Mathematical Precision ===");
        
        // Test with small reserves (potential precision loss)
        usdcWethPair.setReserves(1e15, 3000 * 1e6); // 0.001 ETH, 3000 USDC
        usdtWethPair.setReserves(1e15, 3100 * 1e6); // 0.001 ETH, 3100 USDT
        
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        
        // Should handle small numbers correctly
        assertGt(totalNative, 0, "Should handle small reserves");
        assertGt(totalStable, 0, "Should handle small reserves");
        
        // Test with large reserves (potential overflow)
        usdcWethPair.setReserves(1000 ether, 3000000 * 1e6); // 1000 ETH, 3M USDC
        usdtWethPair.setReserves(1000 ether, 3100000 * 1e6); // 1000 ETH, 3.1M USDT
        
        (totalNative, totalStable) = corrector.getAllStableRate();
        
        // Should handle large numbers correctly
        assertGt(totalNative, 0, "Should handle large reserves");
        assertGt(totalStable, 0, "Should handle large reserves");
        
        console.log("Mathematical precision verified");
    }

    /**
     * @dev Тест сценариев реального использования
     */
    function testRealWorldScenarios() public {
        console.log("=== Test Real World Scenarios ===");
        
        // Scenario 1: Market crash (all stable rates increase)
        usdcWethPair.setReserves(50 ether, 300000 * 1e6); // 6000 USDC/ETH
        usdtWethPair.setReserves(50 ether, 310000 * 1e6); // 6200 USDT/ETH
        usdmWethPair.setReserves(50 ether, 280000 * 1e18); // 5600 USDM/ETH
        
        corrector.correctAll();
        
        // Scenario 2: Bull market (all stable rates decrease)
        usdcWethPair.setReserves(200 ether, 300000 * 1e6); // 1500 USDC/ETH
        usdtWethPair.setReserves(200 ether, 310000 * 1e6); // 1550 USDT/ETH
        usdmWethPair.setReserves(200 ether, 280000 * 1e18); // 1400 USDM/ETH
        
        corrector.correctAll();
        
        // Scenario 3: Stable market with small deviations
        usdcWethPair.setReserves(100 ether, 300000 * 1e6); // 3000 USDC/ETH
        usdtWethPair.setReserves(100 ether, 305000 * 1e6); // 3050 USDT/ETH
        usdmWethPair.setReserves(100 ether, 302500 * 1e18); // 3025 USDM/ETH
        
        corrector.correctAll();
        
        console.log("Real world scenarios tested");
    }

    // Helper functions
    function _assertApproxEqual(uint256 a, uint256 b, uint256 tolerance) internal pure {
        uint256 diff = a > b ? a - b : b - a;
        uint256 maxAllowed = (a * tolerance) / 10000; // tolerance in basis points
        assertLe(diff, maxAllowed, "Values should be approximately equal");
    }
}
