// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CorrectorV3} from "../src/CorrectorV3.sol";

// Minimal ERC20 with mint for tests
contract TestToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n; symbol = s; decimals = d;
    }
    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }
    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }
    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

// Minimal V3 pool exposing token0/token1 (reserves are simulated via token balances at pool address)
contract MockV3Pool {
    address public token0;
    address public token1;
    constructor(address _token0, address _token1) {
        token0 = _token0; token1 = _token1;
    }
}

// Minimal V3 factory mapping (tokenA, tokenB, fee) -> pool address
contract MockV3Factory {
    mapping(bytes32 => address) private pools;
    function _key(address a, address b, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b, fee));
    }
    function setPool(address a, address b, uint24 fee, address pool) external {
        pools[_key(a,b,fee)] = pool;
        pools[_key(b,a,fee)] = pool; // allow reversed order
    }
    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[_key(a,b,fee)];
    }
}

// Minimal router interface to satisfy CorrectorV3 execution method (not used in advanced tests but kept for parity)
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

contract CorrectorV3AdvancedTest is Test {
    CorrectorV3 public corrector;

    // Tokens
    TestToken public weth;
    TestToken public usdc;
    TestToken public usdt;
    TestToken public usdm; // act as USDM stable

    // V3 infra
    MockV3Factory public factory;
    address public poolWethUsdc;
    address public poolWethUsdt;
    address public poolWethUsdm;

    // constants
    uint24 constant FEE_3000 = 3000;
    uint256 constant PRECISION = 1e18;

    function setUp() public {
        corrector = new CorrectorV3();
        weth = new TestToken("Wrapped Ether", "WETH", 18);
        usdc = new TestToken("USD Coin", "USDC", 6);
        usdt = new TestToken("Tether USD", "USDT", 6);
        usdm = new TestToken("USDM", "USDM", 18);

        factory = new MockV3Factory();

        // Create pools (token0, token1) ordering matters for reserve attribution in getReservesV3
        poolWethUsdc = address(new MockV3Pool(address(weth), address(usdc)));
        poolWethUsdt = address(new MockV3Pool(address(weth), address(usdt)));
        poolWethUsdm = address(new MockV3Pool(address(weth), address(usdm)));

        // Register pools in factory
        factory.setPool(address(weth), address(usdc), FEE_3000, poolWethUsdc);
        factory.setPool(address(weth), address(usdt), FEE_3000, poolWethUsdt);
        factory.setPool(address(weth), address(usdm), FEE_3000, poolWethUsdm);

        // Add AMMs: external stables as not-USDM, USDM pool as USDM
        corrector.addAmm(address(factory), address(weth), address(usdc), FEE_3000, 3, false);
        corrector.addAmm(address(factory), address(weth), address(usdt), FEE_3000, 3, false);
        corrector.addAmm(address(factory), address(weth), address(usdm), FEE_3000, 3, true);

        // Seed balances to simulate reserves (transfer tokens to pool addresses)
        // USDC: 100 ETH, 200,000 USDC (18 vs 6 decimals)
        weth.mint(address(this), 1_000_000 ether);
        usdc.mint(address(this), 1_000_000_000_000); // 1e12 minimal large pool
        weth.transfer(poolWethUsdc, 100 ether);
        usdc.transfer(poolWethUsdc, 200_000 * 1e6);

        // USDT: 50 ETH, 100,000 USDT
        usdt.mint(address(this), 1_000_000_000_000);
        weth.transfer(poolWethUsdt, 50 ether);
        usdt.transfer(poolWethUsdt, 100_000 * 1e6);

        // USDM: 25 ETH, 50,000 USDM (initial equal to 2000)
        usdm.mint(address(this), 10_000_000 ether);
        weth.transfer(poolWethUsdm, 25 ether);
        usdm.transfer(poolWethUsdm, 50_000 * 1e18);
    }

    function testCalculateAverageRates() public {
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRateV3();
        // expected: 100 + 50 = 150 ETH
        assertEq(totalNative, 150 ether, "native sum");
        // expected: 200k USDC + 100k USDT = 300k (expressed in token units, but we don't normalize decimals in this proxy)
        // Our proxy sums raw balances; with mixed decimals this is an approximation test.
        assertEq(totalStable, 200_000 * 1e6 + 100_000 * 1e6, "stable sum");

        // averageRate approx: totalStable/totalNative in raw units (informational)
        uint256 avg = (totalStable * PRECISION) / totalNative;
        assertGt(avg, 0, "avg > 0");
    }

    function testUSDMOvervalued() public {
        // set USDM overvalued relative to blended (increase USDM per ETH)
        // Keep ETH the same, raise USDM
        usdm.mint(address(this), 100_000 * 1e18);
        usdm.transfer(poolWethUsdm, 22_000 * 1e18); // now ~ 2200 per ETH for this small pool portion

        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRateV3();
        uint256 averageRate = (totalStable * PRECISION) / totalNative;
        uint256 usdmRate = ( (getUSDMReserve() * PRECISION) / getETHReserveUSDM() ); // units in 18 per 18, informational

        assertTrue(usdmRate > averageRate, "USDM should be overvalued indication");
        // We only validate that correctAllV3Execute can be called if balances exist on contract.
        // Here we focus on planning output without executing swaps (router-less).
        (uint256[] memory inN, uint256[] memory inS) = corrector.planCorrectionsV3();
        assertEq(inN.length, 3);
        assertEq(inS.length, 3);
    }

    function testUSDMUndervalued() public {
        // undervalued -> reduce USDM amount
        // Remove some USDM by transferring away from pool (simulate by minting elsewhere and not pool)
        // Since we cannot burn from pool, simulate by increasing ETH to reduce ratio
        weth.transfer(poolWethUsdm, 5 ether); // increase ETH, so USDM per ETH falls

        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRateV3();
        uint256 averageRate = (totalStable * PRECISION) / totalNative;
        uint256 usdmRate = ( (getUSDMReserve() * PRECISION) / getETHReserveUSDM() );

        assertTrue(usdmRate < averageRate, "USDM should be undervalued indication");
        (uint256[] memory inN, uint256[] memory inS) = corrector.planCorrectionsV3();
        assertEq(inN.length, 3);
        assertEq(inS.length, 3);
    }

    function testMultiplePoolsInfluenceWeightedAverage() public {
        // Add a larger USDC pool that skews average up (2100)
        address bigPool = address(new MockV3Pool(address(weth), address(usdc)));
        factory.setPool(address(weth), address(usdc), 500, bigPool); // another fee tier
        corrector.addAmm(address(factory), address(weth), address(usdc), 500, 3, false);

        // seed big pool with 1000 ETH, 2.1M USDC
        weth.transfer(bigPool, 1000 ether);
        usdc.transfer(bigPool, 2_100_000 * 1e6);

        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRateV3();
        uint256 weighted = (totalStable * PRECISION) / totalNative;
        // should be greater than the 2000 average from initial two pools
        assertGt(weighted, ( (200_000*1e6 + 100_000*1e6) * PRECISION ) / (150 ether), "weighted should rise");
    }

    function testSmallNumbersPrecision() public {
        // Use another pool for small numbers
        address tinyPool = address(new MockV3Pool(address(weth), address(usdc)));
        factory.setPool(address(weth), address(usdc), 100, tinyPool);
        corrector.addAmm(address(factory), address(weth), address(usdc), 100, 3, false);

        // 0.001 ETH, 2 USDC
        weth.transfer(tinyPool, 1e15);
        usdc.transfer(tinyPool, 2 * 1e6);

        (uint256 allN, uint256 allS) = corrector.getAllStableRateV3();
        assertGt(allN, 0, "small N included");
        assertGt(allS, 0, "small S included");
    }

    function testActivationDeactivation() public {
        // Flip a non-USDM AMM's active flag (must be isUSDM == false)
        // Our first AMM entry is weth/usdc with isUSDM=false
        corrector.setAMMactive(address(factory), false);
        (uint256 nativeAfter, uint256 stableAfter) = corrector.getAllStableRateV3();
        // Should now reflect only USDT pool (50 ETH, 100k USDT) because USDC got deactivated
        assertEq(nativeAfter, 50 ether, "only usdt native");
        assertEq(stableAfter, 100_000 * 1e6, "only usdt stable");

        // Reactivate
        corrector.setAMMactive(address(factory), true);
        (uint256 nativeBack, uint256 stableBack) = corrector.getAllStableRateV3();
        assertEq(nativeBack, 150 ether);
        assertEq(stableBack, (200_000 * 1e6) + (100_000 * 1e6));
    }

    function testOverflowHandlingDoesNotRevert() public {
        // Push large amounts to one pool to simulate large reserves
        weth.mint(poolWethUsdc, type(uint96).max);
        usdc.mint(poolWethUsdc, uint256(type(uint112).max) * 1e6 / 1e6); // cap
        // Should not revert
        corrector.getAllStableRateV3();
    }

    function testFuzzReserves(uint112 ethReserve, uint112 stableReserve) public {
        vm.assume(ethReserve > 1e6 && stableReserve > 1e6);
        // Use a dedicated temp pool
        address fuzzPool = address(new MockV3Pool(address(weth), address(usdc)));
        factory.setPool(address(weth), address(usdc), 999, fuzzPool);
        corrector.addAmm(address(factory), address(weth), address(usdc), 999, 3, false);

        // fill reserves
        weth.mint(address(this), 1e24);
        usdc.mint(address(this), 1e24);
        weth.transfer(fuzzPool, uint256(ethReserve));
        usdc.transfer(fuzzPool, uint256(stableReserve));

        (uint256 allN, uint256 allS) = corrector.getAllStableRateV3();
        assertGt(allN, 0);
        assertGt(allS, 0);
    }

    function testPerformanceWithManyPools() public {
        // Add multiple pools to test gas
        for (uint i = 0; i < 12; i++) {
            address p = address(new MockV3Pool(address(weth), address(usdc)));
            factory.setPool(address(weth), address(usdc), uint24(1000 + i), p);
            corrector.addAmm(address(factory), address(weth), address(usdc), uint24(1000 + i), 3, false);
            // seed small balances
            weth.transfer(p, 1 ether);
            usdc.transfer(p, 2000 * 1e6);
        }
        uint256 gasBefore = gasleft();
        corrector.getAllStableRateV3();
        uint256 gasUsed = gasBefore - gasleft();
        assertLt(gasUsed, 1_000_000, "gas should be reasonable");
    }

    // helpers
    function getETHReserveUSDM() internal view returns (uint256) {
        return weth.balanceOf(poolWethUsdm);
    }
    function getUSDMReserve() internal view returns (uint256) {
        return usdm.balanceOf(poolWethUsdm);
    }
}