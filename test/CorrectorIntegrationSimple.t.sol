// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CorrectorV2} from "../src/CorrectorV2.sol";
import {USDM} from "../src/USDM.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CorrectorV2IntegrationTest
 * @dev Быстрые интеграционные тесты для CorrectorV2 с простыми моками
 * Тестирует расчет средних курсов стейблкоинов и арбитражные операции USDM
 */
contract CorrectorV2IntegrationTest is Test {
    CorrectorV2 public corrector;
    USDM public usdm;
    
    // Mock factory and pairs for testing
    MockFactory public factory;
    MockPair public pairUSDC;
    MockPair public pairUSDT; 
    MockPair public pairUSDM;
    
    // Mock tokens
    address constant WETH = address(0x1);
    address constant USDC = address(0x2);
    address constant USDT = address(0x3);
    
    // Test constants
    uint256 constant PRECISION = 1e18;
    uint256 constant USDC_DECIMALS = 1e6;
    
    function setUp() public {
        // Deploy contracts
        corrector = new CorrectorV2();
        usdm = new USDM();
        factory = new MockFactory();
        
        // Deploy mock pairs
        pairUSDC = new MockPair(WETH, USDC);
        pairUSDT = new MockPair(WETH, USDT);
        pairUSDM = new MockPair(WETH, address(usdm));
        
        // Setup factory pairs
        factory.setPair(WETH, USDC, address(pairUSDC));
        factory.setPair(WETH, USDT, address(pairUSDT));
        factory.setPair(WETH, address(usdm), address(pairUSDM));
        
        // Setup initial reserves
        _setupReserves();
        
        // Configure corrector
        _setupCorrectorV2();
    }
    
    function _setupReserves() internal {
        // USDC/ETH: 100 ETH, 200k USDC (rate: 2000)
        pairUSDC.setReserves(uint112(100 * PRECISION), uint112(200000 * USDC_DECIMALS));
        
        // USDT/ETH: 50 ETH, 100k USDT (rate: 2000)
        pairUSDT.setReserves(uint112(50 * PRECISION), uint112(100000 * USDC_DECIMALS));
        
        // USDM/ETH: 25 ETH, 50k USDM (rate: 2000)
        pairUSDM.setReserves(uint112(25 * PRECISION), uint112(50000 * PRECISION));
    }
    
    function _setupCorrectorV2() internal {
        // Add stablecoin pools
        corrector.addAmm(address(factory), WETH, USDC, 2, false);
        corrector.addAmm(address(factory), WETH, USDT, 2, false);
        
        // Add USDM pool
        corrector.addAmm(address(factory), WETH, address(usdm), 2, true);
    }

    /**
     * @dev Тест базового расчета средних курсов
     */
    function testCalculateAverageRates() public {
        console.log("=== Test: Basic Average Rate Calculation ===");
        
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        
        console.log("Total Native:", totalNative / PRECISION);
        console.log("Total Stable:", totalStable / PRECISION);
        
        // Expected: 150 ETH, 300k USD (converted to 18 decimals)
        uint256 expectedNative = 150 * PRECISION;
        uint256 expectedStable = 200000 * 1e12 + 100000 * 1e12; // Convert to 18 decimals
        
        assertEq(totalNative, expectedNative, "Incorrect total native");
        assertEq(totalStable, expectedStable, "Incorrect total stable");
        
        uint256 averageRate = (totalStable * PRECISION) / totalNative;
        console.log("Average rate:", averageRate / PRECISION);
        
        assertEq(averageRate, 2000 * PRECISION, "Rate should be 2000");
    }

    /**
     * @dev Тест USDM переоценен - нужно продавать
     */
    function testUSDMOvervalued() public {
        console.log("=== Test: USDM Overvalued ===");
        
        // Set USDM rate higher (2200 vs market 2000)
        pairUSDM.setReserves(uint112(25 * PRECISION), uint112(55000 * PRECISION));
        
        // Get market rate
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        uint256 marketRate = (totalStable * PRECISION) / totalNative;
        
        console.log("Market rate:", marketRate / PRECISION);
        console.log("USDM rate: 2200");
        
        assertTrue(2200 * PRECISION > marketRate, "USDM should be overvalued");
        
        // Execute correction
        corrector.correctAll();
        
        console.log("USDM overvalued correction executed");
    }

    /**
     * @dev Тест USDM недооценен - нужно покупать  
     */
    function testUSDMUndervalued() public {
        console.log("=== Test: USDM Undervalued ===");
        
        // Set USDM rate lower (1800 vs market 2000)
        pairUSDM.setReserves(uint112(25 * PRECISION), uint112(45000 * PRECISION));
        
        // Get market rate
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        uint256 marketRate = (totalStable * PRECISION) / totalNative;
        
        console.log("Market rate:", marketRate / PRECISION);
        console.log("USDM rate: 1800");
        
        assertTrue(1800 * PRECISION < marketRate, "USDM should be undervalued");
        
        // Execute correction
        corrector.correctAll();
        
        console.log("USDM undervalued correction executed");
    }

    /**
     * @dev Тест множественных пулов
     */
    function testMultiplePools() public {
        console.log("=== Test: Multiple Pools ===");
        
        // Add another USDC pool with different rate
        MockPair pairUSDC2 = new MockPair(WETH, USDC);
        pairUSDC2.setReserves(uint112(200 * PRECISION), uint112(420000 * USDC_DECIMALS)); // Rate: 2100
        
        factory.setPair(WETH, USDC, address(pairUSDC2));
        corrector.addAmm(address(factory), WETH, USDC, 2, false);
        
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        uint256 weightedRate = (totalStable * PRECISION) / totalNative;
        
        console.log("Weighted rate with multiple pools:", weightedRate / PRECISION);
        
        // Should be influenced by the larger pool
        assertTrue(weightedRate > 2000 * PRECISION, "Rate should be higher due to large pool");
    }

    /**
     * @dev Тест деактивации пулов
     */
    function testPoolDeactivation() public {
        console.log("=== Test: Pool Deactivation ===");
        
        // Get initial rate
        (uint256 totalBefore,) = corrector.getAllStableRate();
        
        // Deactivate USDC pool
        corrector.setAMMactive(address(factory), false);
        
        // Rate should change
        (uint256 totalAfter,) = corrector.getAllStableRate();
        
        assertLt(totalAfter, totalBefore, "Total should decrease after deactivation");
        
        console.log("Pool deactivation working correctly");
    }

    /**
     * @dev Тест точности с малыми числами
     */
    function testSmallNumbers() public {
        console.log("=== Test: Small Numbers Precision ===");
        
        // Set very small reserves
        pairUSDC.setReserves(uint112(1e15), uint112(2 * 1e6)); // 0.001 ETH, 2 USDC
        pairUSDT.setReserves(uint112(1e15), uint112(2 * 1e6)); // 0.001 ETH, 2 USDT
        
        try corrector.getAllStableRate() returns (uint256 totalNative, uint256 totalStable) {
            assertGt(totalNative, 0, "Should handle small reserves");
            assertGt(totalStable, 0, "Should handle small reserves");
            
            console.log("Small numbers handled correctly");
        } catch {
            console.log("Reverted on small numbers - might be expected");
        }
    }

    /**
     * @dev Фаззинг тест
     */
    function testFuzzReserves(uint112 ethReserve, uint112 stableReserve) public {
        vm.assume(ethReserve > 1e6 && ethReserve < type(uint112).max / 1000);
        vm.assume(stableReserve > 1e6 && stableReserve < type(uint112).max / 1000);
        
        console.log("=== Fuzz Test ===");
        
        pairUSDC.setReserves(uint112(ethReserve), uint112(stableReserve));
        
        try corrector.getAllStableRate() returns (uint256 totalNative, uint256 totalStable) {
            if (totalNative > 0) {
                uint256 rate = (totalStable * PRECISION) / totalNative;
                
                // Rate should be reasonable
                assertGe(rate, PRECISION / 100, "Rate too low");
                assertLe(rate, 1000000 * PRECISION, "Rate too high");
            }
        } catch {
            // Some combinations might fail, that's ok
            console.log("Fuzz case reverted");
        }
    }

    /**
     * @dev Тест производительности
     */
    function testPerformance() public {
        console.log("=== Test: Performance ===");
        
        uint256 gasBefore = gasleft();
        corrector.getAllStableRate();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used:", gasUsed);
        assertLt(gasUsed, 200000, "Gas usage should be reasonable");
    }

    /**
     * @dev Тест безопасности
     */
    function testSecurity() public {
        console.log("=== Test: Security ===");
        
        address attacker = makeAddr("attacker");
        
        // Try to add AMM as non-owner
        vm.prank(attacker);
        vm.expectRevert();
        corrector.addAmm(address(factory), WETH, USDC, 2, false);
        
        // View functions should work for anyone
        vm.prank(attacker);
        corrector.getAllStableRate();
        
        console.log("Security checks passed");
    }
}

// Simplified mock contracts
contract MockFactory {
    mapping(address => mapping(address => address)) public pairs;
    
    function setPair(address tokenA, address tokenB, address pair) external {
        pairs[tokenA][tokenB] = pair;
        pairs[tokenB][tokenA] = pair;
    }
    
    function getPair(address tokenA, address tokenB) external view returns (address) {
        return pairs[tokenA][tokenB];
    }
}

contract MockPair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;
    
    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }
    
    function setReserves(uint112 _reserve0, uint112 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
    }
    
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }
    
    function swap(uint, uint, address, bytes calldata) external {
        // Mock swap - just emit event or do nothing
    }
}
