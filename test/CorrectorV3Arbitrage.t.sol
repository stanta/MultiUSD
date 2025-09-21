// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CorrectorV3} from "../src/CorrectorV3.sol";

// Minimal ERC20 for testing
contract TestERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) { name = n; symbol = s; decimals = d; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender]-=a; balanceOf[to]+=a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) { allowance[f][msg.sender]-=a; balanceOf[f]-=a; balanceOf[t]+=a; return true; }
}

// Mock V3 Pool
contract MockV3Pool {
    address public token0;
    address public token1;
    constructor(address _token0, address _token1) { token0 = _token0; token1 = _token1; }
}

// Mock V3 Factory
contract MockV3Factory {
    mapping(bytes32 => address) public pools;
    function _key(address a, address b, uint24 fee) internal pure returns (bytes32) { return keccak256(abi.encodePacked(a,b,fee)); }
    function setPool(address a, address b, uint24 fee, address pool) external { pools[_key(a,b,fee)]=pool; pools[_key(b,a,fee)]=pool; }
    function getPool(address a, address b, uint24 fee) external view returns (address) { return pools[_key(a,b,fee)]; }
}

// Minimal Router interface, matches CorrectorV3 local interface
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 deadline;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

// Mock Router to capture calls
contract MockRouter is ISwapRouter {
    ExactInputSingleParams public lastParams;
    uint256 public callCount;
    uint256 public returnAmount = 1;

    function setReturnAmount(uint256 a) external { returnAmount = a; }
    function getLast() external view returns (ExactInputSingleParams memory) { return lastParams; }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable override returns (uint256 amountOut) {
        lastParams = params; callCount++; return returnAmount;
    }
}

contract CorrectorV3ArbitrageTest is Test {
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
    uint256 constant USDC_DECIMALS = 1e6;

    function setUp() public {
        corrector = new CorrectorV3();
        factory = new MockV3Factory();
        router = new MockRouter();

        weth = new TestERC20("WETH","WETH",18);
        usdc = new TestERC20("USDC","USDC",6);
        usdt = new TestERC20("USDT","USDT",6);
        usdm = new TestERC20("USDM","USDM",18);

        poolUsdc = address(new MockV3Pool(address(weth), address(usdc)));
        poolUsdt = address(new MockV3Pool(address(weth), address(usdt)));
        poolUsdm = address(new MockV3Pool(address(weth), address(usdm)));

        factory.setPool(address(weth), address(usdc), FEE, poolUsdc);
        factory.setPool(address(weth), address(usdt), FEE, poolUsdt);
        factory.setPool(address(weth), address(usdm), FEE, poolUsdm);

        // add AMMs (USDC/USDT non-USDM, USDM pool as USDM)
        corrector.addAmm(address(factory), address(weth), address(usdc), FEE, 3, false);
        corrector.addAmm(address(factory), address(weth), address(usdt), FEE, 3, false);
        corrector.addAmm(address(factory), address(weth), address(usdm), FEE, 3, true);

        // seed pool balances
        // USDC pool: 100 ETH, 2,000,000 USDC (rate ~ 2000)
        _mintTo(address(this), 1_000_000 ether, 10_000_000 * PRECISION);
        weth.transfer(poolUsdc, 100 ether);
        usdc.mint(poolUsdc, 2_000_000 * USDC_DECIMALS);

        // USDT pool: 50 ETH, 1,000,000 USDT (rate ~ 2000)
        weth.transfer(poolUsdt, 50 ether);
        usdt.transfer(poolUsdt, 1_000_000 * USDC_DECIMALS);

        // USDM pool: start at 100 ETH, 200k USDM
        weth.transfer(poolUsdm, 100 ether);
        usdm.transfer(poolUsdm, 200_000 * PRECISION);

        // fund corrector to allow swaps
        weth.mint(address(corrector), 1_000_000 ether);
        usdc.mint(address(corrector), 10_000_000 * USDC_DECIMALS);
        usdt.mint(address(corrector), 10_000_000 * USDC_DECIMALS);
        usdm.mint(address(corrector), 10_000_000 * PRECISION);
    }

    function testSimpleArbitrageOvervalued() public {
        // Make USDM overvalued (increase USDM per ETH)
        usdm.mint(address(this), 30_000 * PRECISION);
        usdm.transfer(poolUsdm, 30_000 * PRECISION);

        router.setReturnAmount(123);
        corrector.correctAllV3Execute(address(router));

        assertGt(router.callCount(), 0, "router should be called for overvalued case");
        ISwapRouter.ExactInputSingleParams memory p = router.getLast();
        assertTrue(p.tokenIn == address(usdm) || p.tokenIn == address(weth) || p.tokenIn == address(usdc) || p.tokenIn == address(usdt), "unexpected tokenIn");
        assertEq(p.recipient, address(corrector), "recipient");
    }

    function testSimpleArbitrageUndervalued() public {
        // Make USDM undervalued (decrease USDM per ETH) by adding more ETH to pool
        weth.transfer(poolUsdm, 50 ether);

        router.setReturnAmount(77);
        corrector.correctAllV3Execute(address(router));

        assertGt(router.callCount(), 0, "router should be called for undervalued case");
    }

    function testMultipleArbitrageOpportunities() public {
        // Create second USDM pool at different fee tier
        address pool2 = address(new MockV3Pool(address(weth), address(usdm)));
        factory.setPool(address(weth), address(usdm), 500, pool2);
        corrector.addAmm(address(factory), address(weth), address(usdm), 500, 3, true);

        // Overvalued on first pool; undervalued on second by changing ETH
        usdm.mint(address(this), 20_000 * PRECISION);
        usdm.transfer(poolUsdm, 20_000 * PRECISION);           // overvalued on poolUsdm
        weth.transfer(pool2, 25 ether);                         // undervalued behavior on pool2

        router.setReturnAmount(5);
        corrector.correctAllV3Execute(address(router));

        assertGt(router.callCount(), 0, "router called across multi-pool scenario");
    }

    function testArbitrageWithSlippageLikeScenario() public {
        // thin pool: move to small liquidity
        // reset USDM pool to small balances by transferring out (simulate by adding to another address)
        // we can't remove from pool directly, but we can increase ETH supply or ratio to cause skew
        weth.transfer(poolUsdm, 1 ether); // make ratio shift

        router.setReturnAmount(1);
        corrector.correctAllV3Execute(address(router));
        assertGt(router.callCount(), 0, "router call in slippage-like scenario");
    }

    function testMEVFrontRunScenario() public {
        // simulate MEV front-run by changing pool balances prior to correction
        usdm.mint(address(this), 100_000 * PRECISION);
        usdm.transfer(poolUsdm, 100_000 * PRECISION); // push overvaluation
        // front-run modifies reserves further
        weth.transfer(poolUsdm, 10 ether);

        corrector.correctAllV3Execute(address(router));
        assertGt(router.callCount(), 0, "router call even with MEV manipulation");
    }

    function testFlashLoanLikeManipulation() public {
        // "Flash loan" simulate by large USDM mint then push to pool and expect safe behavior (no reverts)
        usdm.mint(address(this), 1_000_000 * PRECISION);
        usdm.transfer(poolUsdm, 1_000_000 * PRECISION);

        corrector.correctAllV3Execute(address(router));
        assertGt(router.callCount(), 0, "router call after manipulation");
    }

    function testGasEfficiencyRough() public {
        // Add additional small pools to test gas headroom
        for (uint i=0;i<10;i++) {
            address p = address(new MockV3Pool(address(weth), address(usdc)));
            factory.setPool(address(weth), address(usdc), uint24(4000+i), p);
            corrector.addAmm(address(factory), address(weth), address(usdc), uint24(4000+i), 3, false);
            weth.transfer(p, 1 ether);
            usdc.transfer(p, 2_000 * USDC_DECIMALS);
        }
        uint256 gasBefore = gasleft();
        corrector.correctAllV3Execute(address(router));
        uint256 gasUsed = gasBefore - gasleft();
        assertLt(gasUsed, 3_000_000, "gas should be under ~3M for this scenario");
    }

    // Utility
    function _mintTo(address to, uint256 ethAmt, uint256 big) internal {
        weth.mint(to, ethAmt);
        usdc.mint(to, big);
        usdt.mint(to, big);
        usdm.mint(to, big);
    }
}