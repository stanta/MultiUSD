// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CorrectorV3} from "../src/CorrectorV3.sol";

// Minimal ERC20 with mint/burn for tests
contract TestERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n; symbol = s; decimals = d;
    }
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
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
}

// Mock V3 pool exposing token0/token1; reserves are balances at this contract
contract MockV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    uint128 public maxLiquidityPerTick;

    constructor(address _token0, address _token1, uint24 _fee) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = 60; // Default tick spacing
        maxLiquidityPerTick = type(uint128).max;
    }

    // IUniswapV3PoolImmutables interface functions
    function factory() external view returns (address) {
        return address(0); // Not needed for this test
    }
}

// Mock V3 factory with (tokenA, tokenB, fee) mapping to pool address
contract MockV3Factory {
    mapping(bytes32 => address) public pools;
    function _key(address a, address b, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b, fee));
    }
    function createPool(address a, address b, uint24 fee) external returns (address pool) {
        require(a != b, "identical");
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        require(pools[_key(t0, t1, fee)] == address(0), "exists");
        pool = address(new MockV3Pool(t0, t1, fee));
        pools[_key(t0, t1, fee)] = pool;
        pools[_key(t1, t0, fee)] = pool;
    }
    function setPool(address a, address b, uint24 fee, address pool) external {
        pools[_key(a, b, fee)] = pool;
        pools[_key(b, a, fee)] = pool;
    }
    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[_key(a, b, fee)];
    }
}

// Minimal router interface to satisfy executor
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

// Mock router capturing params
contract MockRouter is ISwapRouter {
    ExactInputSingleParams public lastParams;
    uint256 public callCount;
    uint256 public returnAmount = 1;

    function setReturnAmount(uint256 a) external {
        returnAmount = a;
    }

    function getLast() external view returns (ExactInputSingleParams memory) {
        return lastParams;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        lastParams = params;
        callCount++;
        return returnAmount;
    }
}

contract CorrectorV3UnitTest is Test {
    CorrectorV3 public corrector;
    MockV3Factory public factory;
    MockRouter public router;

    TestERC20 public weth;
    TestERC20 public usdc;
    TestERC20 public usdt;
    TestERC20 public usdm;

    address public poolUsdc;
    address public poolUsdt;
    address public poolUsdm;

    uint24 constant FEE = 3000;
    uint256 constant PRECISION = 1e18;

    function setUp() public {
        corrector = new CorrectorV3();
        factory = new MockV3Factory();
        router = new MockRouter();

        weth = new TestERC20("Wrapped Ether", "WETH", 18);
        usdc = new TestERC20("USD Coin", "USDC", 6);
        usdt = new TestERC20("Tether USD", "USDT", 6);
        usdm = new TestERC20("USDM", "USDM", 18);

        // create pools
        poolUsdc = factory.createPool(address(weth), address(usdc), FEE);
        poolUsdt = factory.createPool(address(weth), address(usdt), FEE);
        poolUsdm = factory.createPool(address(weth), address(usdm), FEE);

        // add amms
        corrector.addAmm(address(factory), address(weth), address(usdc), FEE, 3, false);
        corrector.addAmm(address(factory), address(weth), address(usdt), FEE, 3, false);
        corrector.addAmm(address(factory), address(weth), address(usdm), FEE, 3, true);

        // seed balances - use smaller amounts to avoid overflow
        // USDC pool: 100 ETH, 300k USDC
        _mintTo(address(this), 1_000_000 ether, 10_000_000_000); // ample funds
        weth.transfer(poolUsdc, 100 ether);
        usdc.mint(poolUsdc, 300_000 * 1e6);

        // USDT pool: 100 ETH, 310k USDT
        weth.transfer(poolUsdt, 100 ether);
        usdt.mint(poolUsdt, 310_000 * 1e6);

        // USDM pool: 100 ETH, 280k USDM (undervalued vs ~3050 average)
        weth.transfer(poolUsdm, 100 ether);
        usdm.mint(poolUsdm, 280_000 * 1e18);

        // give balances to corrector for potential swaps
        weth.mint(address(corrector), 1_000_000 ether);
        usdm.mint(address(corrector), 1_000_000 * 1e18);
        usdc.mint(address(corrector), 1_000_000 * 1e6);
        usdt.mint(address(corrector), 1_000_000 * 1e6);
    }

    function _mintTo(address to, uint256 ethAmt, uint256 stableAmt) internal {
        weth.mint(to, ethAmt);
        usdc.mint(to, stableAmt);
        usdt.mint(to, stableAmt);
        usdm.mint(to, stableAmt);
    }

    // Basic average rate calculation across external stables
    function testGetAllStableRateV3Basic() public {
        // Test with minimal setup - just check that the function doesn't revert
        (uint256 totalN, uint256 totalS) = corrector.getAllStableRateV3();
        // Should return scaled values
        assertEq(totalN, 200 ether, "total native");
        assertEq(totalS, ((300_000 * 1e6) + (310_000 * 1e6)) * 1e12, "total stable");
    }

    // USDM undervalued: rate lower than average -> plan corrections should compute suggestions
    function testUSDMUndervaluedPlan() public {
        (uint256[] memory inN, uint256[] memory inS) = corrector.planCorrectionsV3();
        assertEq(inN.length, 3);
        assertEq(inS.length, 3);
        // Some values should be > 0 in presence of undervaluation
        bool anyPositive = (inN[0] + inN[1] + inN[2] + inS[0] + inS[1] + inS[2]) > 0;
        assertTrue(anyPositive, "should produce non-zero plan");
    }

    // Overvalued USDM scenario
    function testUSDMOvervaluedPlan() public {
        // Make USDM overvalued by increasing USDM balance in pool
        usdm.mint(address(this), 200_000 * 1e18);
        usdm.transfer(poolUsdm, 200_000 * 1e18);
        (uint256[] memory inN, uint256[] memory inS) = corrector.planCorrectionsV3();
        assertEq(inN.length, 3);
        assertEq(inS.length, 3);
    }

    // AMM management: edit and toggle activation states
    function testAMMManagement() public {
        // deactivate non-USDM amms (by factory address) and re-activate
        corrector.setAMMactive(address(factory), false);
        (uint256 nAfter, uint256 sAfter) = corrector.getAllStableRateV3();
        // With only one non-USDM deactivated, the other remains; cannot assert exact but must be reduced from 200 ETH
        assertLt(nAfter, 200 ether, "reduced native after deactivation");

        corrector.setAMMactive(address(factory), true);
        (uint256 nBack, uint256 sBack) = corrector.getAllStableRateV3();
        assertEq(nBack, 200 ether);
        assertEq(sBack, ((300_000 * 1e6) + (310_000 * 1e6)) * 1e12);
    }

    // Edge cases: zero reserves on one pool should not revert; getReservesV3 returns (0,0) if pool missing
    function testEdgeCasesZeroReserves() public {
        // create additional fee tier but no pool set => should be ignored gracefully
        corrector.addAmm(address(factory), address(weth), address(usdc), 500, 3, false);
        (uint256 tn, uint256 ts) = corrector.getAllStableRateV3();
        assertEq(tn, 200 ether);
        assertEq(ts, ((300_000 * 1e6) + (310_000 * 1e6)) * 1e12);
    }

    // Fuzz: add a temp pool with random reserves and ensure aggregation doesn't revert
    function testFuzzReserves(uint112 ethReserve, uint112 stableReserve) public {
        vm.assume(ethReserve > 1e6 && stableReserve > 1e6);
        address fuzzPool = factory.createPool(address(weth), address(usdc), 9999);
        corrector.addAmm(address(factory), address(weth), address(usdc), 9999, 3, false);

        // fund pool
        weth.mint(fuzzPool, uint256(ethReserve));
        usdc.mint(fuzzPool, uint256(stableReserve));

        (uint256 allN, uint256 allS) = corrector.getAllStableRateV3();
        assertGt(allN, 200 ether); // new pool adds reserves
        assertGt(allS, ((300_000 * 1e6) + (310_000 * 1e6)) * 1e12);
    }

    // Performance: many pools
    function testPerformanceManyPools() public {
        for (uint i = 0; i < 25; i++) {
            address p = factory.createPool(address(weth), address(usdc), uint24(10_000 + i));
            corrector.addAmm(address(factory), address(weth), address(usdc), uint24(10_000 + i), 3, false);
            weth.mint(p, 1 ether);
            usdc.mint(p, 2000 * 1e6);
        }
        uint256 gasBefore = gasleft();
        corrector.getAllStableRateV3();
        uint256 gasUsed = gasBefore - gasleft();
        assertLt(gasUsed, 2_000_000, "should be efficient with many pools");
    }

    // Execute: ensure router is called when skew exists
    function testExecuteCorrectionCallsRouter() public {
        // small skew: make USDM undervalued or overvalued
        usdm.mint(address(this), 50_000 * 1e18);
        usdm.transfer(poolUsdm, 50_000 * 1e18); // push overvaluation

        // ensure contract has source tokens to spend
        usdc.mint(address(corrector), 1_000_000 * 1e6);
        weth.mint(address(corrector), 500_000 ether);

        router.setReturnAmount(123);
        corrector.correctAllV3Execute(address(router));
        assertGt(router.callCount(), 0, "router should be invoked");
    }
}