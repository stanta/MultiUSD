// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CorrectorV3} from "../src/CorrectorV3.sol";

// Simple ERC20 mock (decimals configurable)
contract TestToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) { name=n; symbol=s; decimals=d; }
    function mint(address to, uint256 amt) external { balanceOf[to]+=amt; totalSupply+=amt; }
    function approve(address spender, uint256 amt) external returns (bool){ allowance[msg.sender][spender]=amt; return true; }
    function transfer(address to, uint256 amt) external returns (bool){ balanceOf[msg.sender]-=amt; balanceOf[to]+=amt; return true; }
    function transferFrom(address from, address to, uint256 amt) external returns (bool){
        allowance[from][msg.sender]-=amt; balanceOf[from]-=amt; balanceOf[to]+=amt; return true;
    }
}

// Minimal V3 pool: reserves simulated by token balances held at this contract
contract MockV3Pool {
    address public token0;
    address public token1;
    constructor(address _token0, address _token1){ token0=_token0; token1=_token1; }
}

// Minimal V3 factory: (tokenA, tokenB, fee) -> pool
contract MockV3Factory {
    mapping(bytes32 => address) public pools;
    function _key(address a, address b, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a,b,fee));
    }
    function setPool(address a, address b, uint24 fee, address pool) external {
        pools[_key(a,b,fee)] = pool;
        pools[_key(b,a,fee)] = pool;
    }
    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[_key(a,b,fee)];
    }
}

contract CorrectorV3IntegrationSimpleTest is Test {
    CorrectorV3 public corrector;

    MockV3Factory public factory;
    TestToken public weth;
    TestToken public usdc;
    TestToken public usdt;
    TestToken public usdm;

    address public poolUSDC;
    address public poolUSDT;
    address public poolUSDM;

    // addresses (mock tokens)
    address constant WETH_ADDR_SENTINEL = address(0x1);
    address constant USDC_ADDR_SENTINEL = address(0x2);
    address constant USDT_ADDR_SENTINEL = address(0x3);

    // constants
    uint24 constant FEE_3000 = 3000;
    uint256 constant PRECISION = 1e18;
    uint256 constant USDC_DECIMALS = 1e6;

    function setUp() public {
        corrector = new CorrectorV3();

        // tokens
        weth = new TestToken("Wrapped ETH", "WETH", 18);
        usdc = new TestToken("USDC", "USDC", 6);
        usdt = new TestToken("USDT", "USDT", 6);
        usdm = new TestToken("USDM", "USDM", 18);

        factory = new MockV3Factory();

        // pools (order matters: token0/token1 reflect provided addresses)
        poolUSDC = address(new MockV3Pool(address(weth), address(usdc)));
        poolUSDT = address(new MockV3Pool(address(weth), address(usdt)));
        poolUSDM = address(new MockV3Pool(address(weth), address(usdm)));

        // register pools
        factory.setPool(address(weth), address(usdc), FEE_3000, poolUSDC);
        factory.setPool(address(weth), address(usdt), FEE_3000, poolUSDT);
        factory.setPool(address(weth), address(usdm), FEE_3000, poolUSDM);

        // add AMMs: two external stables (not USDM), one USDM pool
        corrector.addAmm(address(factory), address(weth), address(usdc), FEE_3000, 3, false);
        corrector.addAmm(address(factory), address(weth), address(usdt), FEE_3000, 3, false);
        corrector.addAmm(address(factory), address(weth), address(usdm), FEE_3000, 3, true);

        // seed reserves: USDC/ETH: 100 ETH, 200k USDC
        weth.mint(address(this), 1_000_000 ether);
        usdc.mint(address(this), 1_000_000_000_000);
        usdt.mint(address(this), 1_000_000_000_000);
        usdm.mint(address(this), 1_000_000 ether);

        weth.transfer(poolUSDC, 100 ether);
        usdc.transfer(poolUSDC, 200_000 * USDC_DECIMALS);

        // USDT/ETH: 50 ETH, 100k USDT
        weth.transfer(poolUSDT, 50 ether);
        usdt.transfer(poolUSDT, 100_000 * USDC_DECIMALS);

        // USDM/ETH: 25 ETH, 50k USDM (initially not used in average since we aggregate only non-USDM)
        weth.transfer(poolUSDM, 25 ether);
        usdm.transfer(poolUSDM, 50_000 * 1e18);
    }

    // === Basic average rate calculation across external stablecoin pools ===
    function testCalculateAverageRates() public {
        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRateV3();
        // Expected native: 100 + 50 = 150 ETH
        assertEq(totalNative, 150 ether, "native total mismatch");
        // Expected stable: 200k + 100k (scaled to 18 decimals)
        assertEq(totalStable, (200_000 * USDC_DECIMALS * 1e12) + (100_000 * USDC_DECIMALS * 1e12), "stable total mismatch");

        // Derived average (informational)
        uint256 avg = (totalStable * PRECISION) / totalNative;
        assertGt(avg, 0);
    }

    // === USDM overvalued: increase USDM amount in pool (USDM per ETH higher) ===
    function testUSDMOvervalued() public {
        // Make USDM pool show higher USDM/ETH
        usdm.mint(address(this), 22_000 * 1e18);
        usdm.transfer(poolUSDM, 22_000 * 1e18);

        (uint256 allN, uint256 allS) = corrector.getAllStableRateV3();
        uint256 avgRate = (allS * PRECISION) / allN;

        // Just call planner; assert arrays returned correctly
        (uint256[] memory inN, uint256[] memory inS) = corrector.planCorrectionsV3();
        assertEq(inN.length, 3);
        assertEq(inS.length, 3);
        // Expect some plan suggested
        bool any = (inN[0]+inN[1]+inN[2]+inS[0]+inS[1]+inS[2]) > 0;
        assertTrue(any, "should produce suggestions");
        // silence avgRate warning
        avgRate;
    }

    // === USDM undervalued: increase ETH in pool (USDM per ETH smaller) ===
    function testUSDMUndervalued() public {
        weth.transfer(poolUSDM, 5 ether);

        (uint256[] memory inN, uint256[] memory inS) = corrector.planCorrectionsV3();
        assertEq(inN.length, 3);
        assertEq(inS.length, 3);
    }

    // === Multiple pools influence weighted average ===
    function testMultiplePools() public {
        // Add a larger USDC pool at different fee
        address bigUSDC = address(new MockV3Pool(address(weth), address(usdc)));
        factory.setPool(address(weth), address(usdc), 500, bigUSDC);
        corrector.addAmm(address(factory), address(weth), address(usdc), 500, 3, false);

        // seed bigger pool: 1000 ETH, 2.1M USDC (rate ~ 2100)
        weth.transfer(bigUSDC, 1000 ether);
        usdc.mint(bigUSDC, 2_100_000 * USDC_DECIMALS);

        (uint256 totalNative, uint256 totalStable) = corrector.getAllStableRateV3();
        uint256 weightedAvg = (totalStable * PRECISION) / totalNative;
        // Should exceed ~2000-ish baseline from first two pools
        assertGt(weightedAvg, ( (200_000*USDC_DECIMALS + 100_000*USDC_DECIMALS) * PRECISION ) / (150 ether) );
    }

    // === Pool deactivation ===
    function testPoolDeactivation() public {
        (uint256 beforeN, ) = corrector.getAllStableRateV3();
        corrector.setAMMactive(address(factory), false); // only targets non-USDM entries
        (uint256 afterN, ) = corrector.getAllStableRateV3();
        assertLt(afterN, beforeN, "deactivation should reduce native total");
    }

    // === Small numbers precision ===
    function testSmallNumbers() public {
        // Add tiny pool
        address tiny = address(new MockV3Pool(address(weth), address(usdc)));
        factory.setPool(address(weth), address(usdc), 100, tiny);
        corrector.addAmm(address(factory), address(weth), address(usdc), 100, 3, false);

        weth.transfer(tiny, 1e15); // 0.001 ETH
        usdc.transfer(tiny, 2 * USDC_DECIMALS); // 2 USDC

        (uint256 n, uint256 s) = corrector.getAllStableRateV3();
        assertGt(n, 0);
        assertGt(s, 0);
    }

    // === Fuzz reserves for an extra pool ===
    function testFuzzReserves(uint112 ethReserve, uint112 stableReserve) public {
        vm.assume(ethReserve > 1e6 && stableReserve > 1e6);
        address fuzz = address(new MockV3Pool(address(weth), address(usdc)));
        factory.setPool(address(weth), address(usdc), 9999, fuzz);
        corrector.addAmm(address(factory), address(weth), address(usdc), 9999, 3, false);

        weth.mint(fuzz, uint256(ethReserve));
        usdc.mint(fuzz, uint256(stableReserve));

        (uint256 n, uint256 s) = corrector.getAllStableRateV3();
        assertGt(n, 0);
        assertGt(s, 0);
    }

    // === Performance smoke test ===
    function testPerformance() public {
        for (uint i=0;i<20;i++){
            address p = address(new MockV3Pool(address(weth), address(usdc)));
            factory.setPool(address(weth), address(usdc), uint24(4000+i), p);
            corrector.addAmm(address(factory), address(weth), address(usdc), uint24(4000+i), 3, false);
            weth.transfer(p, 1 ether);
            usdc.transfer(p, 2000 * USDC_DECIMALS);
        }
        uint256 gasBefore = gasleft();
        corrector.getAllStableRateV3();
        uint256 gasUsed = gasBefore - gasleft();
        assertLt(gasUsed, 2_000_000, "gas should be reasonable");
    }

    // === Security: only owner can mutate AMMs ===
    function testSecurity() public {
        address attacker = address(0xBEEF);
        vm.prank(attacker);
        vm.expectRevert();
        corrector.addAmm(address(factory), address(weth), address(usdc), FEE_3000, 3, false);

        vm.prank(attacker);
        // reading is allowed
        corrector.getAllStableRateV3();
    }
}