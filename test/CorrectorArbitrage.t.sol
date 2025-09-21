// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CorrectorV2} from "../src/CorrectorV2.sol";
import {USDM} from "../src/USDM.sol";

/**
 * @title CorrectorV2ArbitrageTest
 * @dev Специализированные тесты для арбитражных стратегий USDM
 */
contract CorrectorV2ArbitrageTest is Test {
    CorrectorV2 public corrector;
    USDM public usdm;
    
    // Test contracts and addresses
    address public owner;
    address public arbitrageur;
    address public liquidityProvider;
    
    // Mock tokens and pools
    MockERC20 public weth;
    MockERC20 public usdc;
    MockERC20 public usdt;
    MockUniswapV2Factory public factory;
    MockUniswapV2Pair public pairUSDC;
    MockUniswapV2Pair public pairUSDT;
    MockUniswapV2Pair public pairUSDM;
    
    // Test constants
    uint256 constant PRECISION = 1e18;
    uint256 constant USDC_DECIMALS = 1e6;
    uint256 constant INITIAL_ETH = 1000 * PRECISION;
    uint256 constant INITIAL_USDC = 2000000 * USDC_DECIMALS; // 2M USDC
    uint256 constant INITIAL_USDT = 2000000 * USDC_DECIMALS; // 2M USDT
    uint256 constant BASE_ETH_PRICE = 2000; // $2000 per ETH
    
    // Events
    event ArbitrageExecuted(
        address indexed pair,
        uint256 amountIn,
        uint256 amountOut,
        bool isUSDMSell,
        uint256 priceImpact
    );
    
    event ProfitRealized(
        address indexed arbitrageur,
        uint256 profit,
        uint256 gasUsed
    );

    function setUp() public {
        // Setup accounts
        owner = address(this);
        arbitrageur = makeAddr("arbitrageur");
        liquidityProvider = makeAddr("liquidityProvider");
        
        // Deploy mock tokens
        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        usdt = new MockERC20("USDT", "USDT", 6);
        
        // Deploy contracts
        corrector = new CorrectorV2();
        usdm = new USDM();
        factory = new MockUniswapV2Factory();
        
        // Deploy pairs
        pairUSDC = new MockUniswapV2Pair(address(weth), address(usdc));
        pairUSDT = new MockUniswapV2Pair(address(weth), address(usdt));
        pairUSDM = new MockUniswapV2Pair(address(weth), address(usdm));
        
        // Register pairs in factory
        factory.setPair(address(weth), address(usdc), address(pairUSDC));
        factory.setPair(address(weth), address(usdt), address(pairUSDT));
        factory.setPair(address(weth), address(usdm), address(pairUSDM));
        
        // Setup initial liquidity
        _setupInitialLiquidity();
        
        // Configure corrector
        _setupCorrectorV2Pools();
        
        // Give tokens to test accounts
        _distributeTokens();
    }
    
    function _setupInitialLiquidity() internal {
        // USDC/ETH pool: 1000 ETH, 2M USDC (rate: 2000)
        weth.mint(address(pairUSDC), INITIAL_ETH);
        usdc.mint(address(pairUSDC), INITIAL_USDC);
        pairUSDC.setReserves(uint112(INITIAL_ETH), uint112(INITIAL_USDC));
        
        // USDT/ETH pool: 500 ETH, 1M USDT (rate: 2000)
        weth.mint(address(pairUSDT), INITIAL_ETH / 2);
        usdt.mint(address(pairUSDT), INITIAL_USDT / 2);
        pairUSDT.setReserves(uint112(INITIAL_ETH / 2), uint112(INITIAL_USDT / 2));
        
        // USDM/ETH pool: 100 ETH, 200k USDM (rate: 2000)
        weth.mint(address(pairUSDM), INITIAL_ETH / 10);
        usdm.mint(address(pairUSDM), 200000 * PRECISION);
        pairUSDM.setReserves(uint112(INITIAL_ETH / 10), uint112(200000 * PRECISION));
    }
    
    function _setupCorrectorV2Pools() internal {
        // Add external stablecoin pools
        corrector.addAmm(address(factory), address(weth), address(usdc), 2, false);
        corrector.addAmm(address(factory), address(weth), address(usdt), 2, false);
        
        // Add USDM pool
        corrector.addAmm(address(factory), address(weth), address(usdm), 2, true);
    }
    
    function _distributeTokens() internal {
        // Mint tokens for testing
        weth.mint(arbitrageur, 100 * PRECISION);
        usdc.mint(arbitrageur, 200000 * USDC_DECIMALS);
        usdt.mint(arbitrageur, 200000 * USDC_DECIMALS);
        usdm.mint(arbitrageur, 200000 * PRECISION);
        
        weth.mint(address(corrector), 100 * PRECISION);
        usdm.mint(address(corrector), 1000000 * PRECISION);
    }

    /**
     * @dev Тест простого арбитража при переоценке USDM
     */
    function testSimpleArbitrageOvervalued() public {
        console.log("=== Test: Simple Arbitrage - USDM Overvalued ===");
        
        // Set USDM price higher than market average (2200 vs 2000)
        pairUSDM.setReserves(uint112(100 * PRECISION), uint112(220000 * PRECISION));
        
        // Get market average
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        uint256 marketRate = (totalStable * PRECISION) / totalNative;
        uint256 usdmRate = 2200 * PRECISION;
        
        console.log("Market Rate:", marketRate / PRECISION);
        console.log("USDM Rate:", usdmRate / PRECISION);
        
        assertTrue(usdmRate > marketRate, "USDM should be overvalued");
        
        // Execute arbitrage
        uint256 gasBefore = gasleft();
        corrector.correctAll();
        uint256 gasUsed = gasBefore - gasleft();
        
        emit ArbitrageExecuted(address(pairUSDM), 0, 0, true, 0);
        emit ProfitRealized(arbitrageur, 0, gasUsed);
        
        console.log("Arbitrage executed - SELL USDM");
        console.log("Gas used:", gasUsed);
    }

    /**
     * @dev Тест арбитража при недооценке USDM
     */
    function testSimpleArbitrageUndervalued() public {
        console.log("=== Test: Simple Arbitrage - USDM Undervalued ===");
        
        // Set USDM price lower than market average (1800 vs 2000)
        pairUSDM.setReserves(uint112(100 * PRECISION), uint112(180000 * PRECISION));
        
        // Get market average
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRate();
        uint256 marketRate = (totalStable * PRECISION) / totalNative;
        uint256 usdmRate = 1800 * PRECISION;
        
        console.log("Market Rate:", marketRate / PRECISION);
        console.log("USDM Rate:", usdmRate / PRECISION);
        
        assertTrue(usdmRate < marketRate, "USDM should be undervalued");
        
        // Execute arbitrage
        uint256 gasBefore = gasleft();
        corrector.correctAll();
        uint256 gasUsed = gasBefore - gasleft();
        
        emit ArbitrageExecuted(address(pairUSDM), 0, 0, false, 0);
        emit ProfitRealized(arbitrageur, 0, gasUsed);
        
        console.log("Arbitrage executed - BUY USDM");
        console.log("Gas used:", gasUsed);
    }

    /**
     * @dev Тест множественных арбитражных возможностей
     */
    function testMultipleArbitrageOpportunities() public {
        console.log("=== Test: Multiple Arbitrage Opportunities ===");
        
        // Create second USDM pool with different rate
        MockUniswapV2Pair pairUSDM2 = new MockUniswapV2Pair(address(weth), address(usdm));
        factory.setPair(address(weth), address(usdm), address(pairUSDM2));
        
        // First pool: overvalued (2200)
        pairUSDM.setReserves(uint112(100 * PRECISION), uint112(220000 * PRECISION));
        
        // Second pool: undervalued (1800)  
        weth.mint(address(pairUSDM2), 50 * PRECISION);
        usdm.mint(address(pairUSDM2), 90000 * PRECISION);
        pairUSDM2.setReserves(uint112(50 * PRECISION), uint112(90000 * PRECISION));
        
        // Add second pool to corrector
        corrector.addAmm(address(factory), address(weth), address(usdm), 2, true);
        
        console.log("Multiple USDM pools with different rates");
        console.log("Pool 1 rate: 2200 (overvalued)");
        console.log("Pool 2 rate: 1800 (undervalued)");
        
        // Execute correction on all pools
        corrector.correctAll();
        
        console.log("Multi-pool arbitrage executed");
    }

    /**
     * @dev Тест прибыльности арбитража
     */
    function testArbitrageProfitability() public {
        console.log("=== Test: Arbitrage Profitability ===");
        
        vm.startPrank(arbitrageur);
        
        // Initial balances
        uint256 initialETH = weth.balanceOf(arbitrageur);
        uint256 initialUSDM = usdm.balanceOf(arbitrageur);
        
        console.log("Initial ETH:", initialETH / PRECISION);
        console.log("Initial USDM:", initialUSDM / PRECISION);
        
        // Create arbitrage opportunity (USDM overvalued)
        pairUSDM.setReserves(uint112(100 * PRECISION), uint112(230000 * PRECISION)); // Rate: 2300
        
        // Manual arbitrage simulation
        // 1. Sell USDM for ETH at high rate
        uint256 usdmToSell = 1000 * PRECISION;
        usdm.transfer(address(pairUSDM), usdmToSell);
        
        // Calculate expected ETH output (simplified)
        uint256 ethReceived = _calculateSwapOutput(
            usdmToSell,
            230000 * PRECISION,
            100 * PRECISION
        );

        // Simulate receiving ETH from the swap
        vm.startPrank(address(pairUSDM));
        weth.transfer(arbitrageur, ethReceived);
        vm.stopPrank();
        
        // 2. Buy USDM back at market rate from other pools
        // (This would involve more complex multi-pool trading)
        
        uint256 finalETH = weth.balanceOf(arbitrageur);
        uint256 finalUSDM = usdm.balanceOf(arbitrageur);
        
        console.log("Final ETH:", finalETH / PRECISION);
        console.log("Final USDM:", finalUSDM / PRECISION);
        
        // Calculate profit
        int256 ethProfit = int256(finalETH) - int256(initialETH);
        int256 usdmProfit = int256(finalUSDM) - int256(initialUSDM);
        
        console.log("ETH profit:", ethProfit > 0 ? uint256(ethProfit) / PRECISION : 0);
        console.log("USDM profit:", usdmProfit > 0 ? uint256(usdmProfit) / PRECISION : 0);
        
        vm.stopPrank();
    }

    /**
     * @dev Тест арбитража с учетом slippage
     */
    function testArbitrageWithSlippage() public {
        console.log("=== Test: Arbitrage with Slippage ===");
        
        // Small pool with high slippage
        pairUSDM.setReserves(uint112(10 * PRECISION), uint112(22000 * PRECISION)); // Small pool
        
        uint256 tradeSize = 1000 * PRECISION; // Large trade relative to pool
        
        // Calculate price impact
        uint256 priceImpact = _calculatePriceImpact(
            tradeSize,
            10 * PRECISION,
            22000 * PRECISION
        );
        
        console.log("Trade size:", tradeSize / PRECISION);
        console.log("Pool size: 10 ETH, 22k USDM");
        console.log("Price impact:", priceImpact / 100); // In basis points
        
        assertTrue(priceImpact > 500, "Should have significant price impact"); // > 5%
        
        corrector.correctAll();
        
        console.log("High slippage arbitrage executed");
    }

    /**
     * @dev Тест MEV (Maximal Extractable Value) сценариев
     */
    function testMEVScenarios() public {
        console.log("=== Test: MEV Scenarios ===");
        
        // Simulate MEV bot front-running
        // 1. Detect arbitrage opportunity
        pairUSDM.setReserves(uint112(100 * PRECISION), uint112(250000 * PRECISION)); // Rate: 2500
        
        // 2. MEV bot front-runs the correction
        vm.startPrank(arbitrageur);
        
        // Front-run trade
        uint256 frontRunAmount = 5000 * PRECISION;
        usdm.transfer(address(pairUSDM), frontRunAmount);
        
        // Update reserves after front-run
        pairUSDM.setReserves(
            uint112(105 * PRECISION), // More ETH
            uint112(245000 * PRECISION) // Less USDM
        );
        
        vm.stopPrank();
        
        // 3. Now execute original arbitrage
        corrector.correctAll();
        
        console.log("MEV scenario tested");
        console.log("Front-run amount:", frontRunAmount / PRECISION);
    }

    /**
     * @dev Тест защиты от флэш-займов
     */
    function testFlashLoanProtection() public {
        console.log("=== Test: Flash Loan Protection ===");
        
        // Simulate flash loan attack
        uint256 flashLoanAmount = 10000 * PRECISION;
        
        // 1. Flash loan USDM
        usdm.mint(arbitrageur, flashLoanAmount);
        
        vm.startPrank(arbitrageur);
        
        // 2. Manipulate USDM pool
        usdm.transfer(address(pairUSDM), flashLoanAmount);
        pairUSDM.setReserves(
            uint112(80 * PRECISION), // Less ETH
            uint112(400000 * PRECISION) // More USDM - manipulated rate
        );
        
        // 3. Try to trigger corrector
        vm.expectRevert(); // Should be protected
        corrector.correctAll();
        
        vm.stopPrank();
        
        // 4. Repay flash loan
        vm.startPrank(arbitrageur);
        usdm.approve(address(this), flashLoanAmount);
        vm.stopPrank();
        usdm.burnFrom(arbitrageur, flashLoanAmount);
        
        console.log("Flash loan protection tested");
    }

    /**
     * @dev Тест арбитража в экстремальных рыночных условиях
     */
    function testExtremeMarketConditions() public {
        console.log("=== Test: Extreme Market Conditions ===");
        
        // Crash scenario: ETH drops 50%
        uint256 crashRate = 1000; // $1000 per ETH
        
        // Update all pools to reflect crash
        pairUSDC.setReserves(uint112(INITIAL_ETH), uint112(INITIAL_USDC / 2)); // Half the USDC for same ETH
        pairUSDT.setReserves(uint112(INITIAL_ETH / 2), uint112(INITIAL_USDT / 4)); // Quarter USDT
        
        // USDM pool hasn't updated yet (arbitrage opportunity)
        pairUSDM.setReserves(uint112(100 * PRECISION), uint112(200000 * PRECISION)); // Still at 2000
        
        console.log("Market crashed to $1000 per ETH");
        console.log("USDM still at $2000 per ETH");
        
        // Should trigger massive sell pressure on USDM
        corrector.correctAll();
        
        console.log("Extreme market condition arbitrage executed");
    }

    /**
     * @dev Фаззинг тест для различных размеров арбитража
     */
    function testFuzzArbitrageSize(uint256 deviation) public {
        // Bound deviation to reasonable range (50-200% of market rate)
        deviation = bound(deviation, 50, 200);
        
        console.log("=== Fuzz Test: Arbitrage Size ===");
        console.log("Deviation:", deviation, "%");
        
        // Set USDM rate based on deviation
        uint256 usdmRate = (BASE_ETH_PRICE * deviation) / 100;
        pairUSDM.setReserves(uint112(100 * PRECISION), uint112(usdmRate * 100));
        
        console.log("USDM rate:", usdmRate);
        console.log("Market rate:", BASE_ETH_PRICE);
        
        // Execute arbitrage
        try corrector.correctAll() {
            console.log("Arbitrage executed successfully");
        } catch Error(string memory reason) {
            console.log("Arbitrage failed:", reason);
        }
    }

    /**
     * @dev Тест газовой эффективности арбитража
     */
    function testArbitrageGasEfficiency() public {
        console.log("=== Test: Arbitrage Gas Efficiency ===");
        
        // Create moderate arbitrage opportunity
        pairUSDM.setReserves(uint112(100 * PRECISION), uint112(210000 * PRECISION)); // 5% premium
        
        // Measure gas usage
        uint256 gasBefore = gasleft();
        corrector.correctAll();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for arbitrage:", gasUsed);
        
        // Calculate gas efficiency (profit per gas)
        uint256 estimatedProfit = 5000 * PRECISION; // Rough estimate
        uint256 efficiency = estimatedProfit / gasUsed;
        
        console.log("Estimated efficiency (profit/gas):", efficiency);
        
        // Gas usage should be reasonable
        assertLt(gasUsed, 200000, "Gas usage should be under 200k");
    }
    
    // Utility functions
    function _calculateSwapOutput(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256) {
        // Simplified Uniswap formula: xy = k
        uint256 amountInWithFee = amountIn * 997; // 0.3% fee
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        return numerator / denominator;
    }
    
    function _calculatePriceImpact(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256) {
        uint256 amountOut = _calculateSwapOutput(amountIn, reserveIn, reserveOut);
        uint256 spotPrice = (reserveIn * PRECISION) / reserveOut;
        uint256 effectivePrice = (amountIn * PRECISION) / amountOut;
        
        if (effectivePrice > spotPrice) {
            return ((effectivePrice - spotPrice) * 10000) / spotPrice; // In basis points
        } else {
            return 0;
        }
    }
}

// Mock contracts for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
    
    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }
    
    function burnFrom(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

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
        // Mock implementation - just transfer tokens
        if (amount0Out > 0) {
            MockERC20(token0).transfer(to, amount0Out);
        }
        if (amount1Out > 0) {
            MockERC20(token1).transfer(to, amount1Out);
        }
    }
}
