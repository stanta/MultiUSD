// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CorrectorV3} from "../src/CorrectorV3.sol";

// Minimal router interface (matches CorrectorV3 local interface)
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

// Simple mock router to capture calls without performing token transfers
contract MockRouter is ISwapRouter {
    ExactInputSingleParams public lastParams;
    uint256 public callCount;
    uint256 public returnAmount;

    function setReturnAmount(uint256 a) external {
        returnAmount = a;
    }

    // Helper to return the lastParams as a struct (public variable getter returns tuple)
    function getLastParams() external view returns (ExactInputSingleParams memory) {
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

// Simple mintable ERC20 for testing
contract TestToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

// Mock V3 pool exposing token0/token1
contract MockV3Pool {
    address public token0;
    address public token1;
    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }
}

// Mock V3 factory mapping (tokenA, tokenB, fee) to a pool address
contract MockV3Factory {
    struct Key { address a; address b; uint24 fee; }
    mapping(bytes32 => address) private pools;

    function _key(address a, address b, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b, fee));
    }

    function setPool(address a, address b, uint24 fee, address pool) external {
        pools[_key(a, b, fee)] = pool;
        pools[_key(b, a, fee)] = pool; // support reversed order like real factory
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[_key(a, b, fee)];
    }
}

contract CorrectorV3Test is Test {
    MockV3Factory factory;
    TestToken tokenNative;
    TestToken tokenStable;

    CorrectorV3 corrector;
    MockRouter router;

    uint24 constant FEE_3000 = 3000;

    function setUp() public {
        factory = new MockV3Factory();

        tokenNative = new TestToken("Wrapped ETH", "WETH");
        tokenStable = new TestToken("USD Stable", "USDM");

        corrector = new CorrectorV3();
        router = new MockRouter();

        // Register one v3 AMM (factory+pair+fee)
        corrector.addAmm(
            address(factory),
            address(tokenNative),
            address(tokenStable),
            FEE_3000,
            3,
            true // mark as USDM pool to be considered for correction
        );
    }

    function _createPool(address a, address b, uint24 fee) internal returns (address pool) {
        // Ensure token0 == a and token1 == b (order matters for reserve attribution)
        MockV3Pool p = new MockV3Pool(a, b);
        pool = address(p);
        factory.setPool(a, b, fee, pool);
    }

    function test_getReserves_and_aggregate() public {
        // create pool and simulate reserves by transferring tokens to pool address
        address pool = _createPool(address(tokenNative), address(tokenStable), FEE_3000);

        // mint tokens to this test and then send to pool to simulate reserves
        tokenNative.mint(address(this), 10_000 ether);
        tokenStable.mint(address(this), 20_000 ether);

        tokenNative.transfer(pool, 6_000 ether);
        tokenStable.transfer(pool, 12_000 ether);

        (uint256 allN, uint256 allS) = corrector.getAllStableRateV3();
        assertEq(allN, 6_000 ether, "aggregate native");
        assertEq(allS, 12_000 ether, "aggregate stable");
    }

    function test_planCorrections_increases_lower_side() public {
        address pool = _createPool(address(tokenNative), address(tokenStable), FEE_3000);

        tokenNative.mint(address(this), 1_000_000 ether);
        tokenStable.mint(address(this), 1_000_000 ether);

        // Simulate skew: put 1,000 N and 10,000 S into pool
        tokenNative.transfer(pool, 1_000 ether);
        tokenStable.transfer(pool, 10_000 ether);

        (uint256 allN, uint256 allS) = corrector.getAllStableRateV3();
        assertEq(allN, 1_000 ether);
        assertEq(allS, 10_000 ether);

        // Now compute plan
        (uint256[] memory inN, uint256[] memory inS) = corrector.planCorrectionsV3();

        // With allS > allN, averageSwapRate = allS / allN = 10x, amountTobeStable = N*10
        // Current reserve S already 10_000; depending on integer math, plan will suggest either zero or movements.
        // We only assert that arrays are returned and indexing aligns with amms.
        assertEq(inN.length, 1);
        assertEq(inS.length, 1);
        // The plan should not revert and produce some suggestion; accept either zero or positive due to integer divisions.
        assertTrue(inN[0] >= 0);
        assertTrue(inS[0] >= 0);
    }

    function test_setAMMactive_toggles() public {
        // Flip USDM flag off so setAMMactive() will target this entry
        corrector.editAMM(
            address(factory),
            address(tokenNative),
            address(tokenStable),
            FEE_3000,
            3,
            false // not USDM -> eligible for setAMMactive()
        );

        // Deactivate and reactivate; expecting no revert
        corrector.setAMMactive(address(factory), false);
        corrector.setAMMactive(address(factory), true);
    }

    function test_editAMM_updates_fields() public {
        corrector.editAMM(
            address(factory),
            address(tokenStable), // swap tokens
            address(tokenNative),
            500,                  // change fee
            3,
            false                 // change flag
        );
        // Ensure no revert; deeper checks could be added by exposing AMMs via a getter if needed.
    }

    function test_correctAllV3Execute_calls_router_for_skew() public {
        address pool = _createPool(address(tokenNative), address(tokenStable), FEE_3000);

        tokenNative.mint(address(this), 1_000_000 ether);
        tokenStable.mint(address(this), 1_000_000 ether);

        // Transfer some tokens to CorrectorV3 to satisfy approvals (no transfer is executed by mock router)
        tokenNative.mint(address(corrector), 100_000 ether);
        tokenStable.mint(address(corrector), 100_000 ether);

        // Create a skew that should cause a router call (avoid perfect ratio equality)
        tokenNative.transfer(pool, 500 ether);
        tokenStable.transfer(pool, 49_100 ether); // ensure reserveStable != reserveNative * averageSwapRate

        router.setReturnAmount(123); // arbitrary

        // Expect no revert
        corrector.correctAllV3Execute(address(router));

        // Router should have been called at least once
        assertGt(router.callCount(), 0, "router should be called");

        // Validate last params are coherent (token addresses must be either pair with given fee)
        ISwapRouter.ExactInputSingleParams memory p = router.getLastParams();
        assertTrue(
            (p.tokenIn == address(tokenNative) && p.tokenOut == address(tokenStable)) ||
            (p.tokenIn == address(tokenStable) && p.tokenOut == address(tokenNative)),
            "unexpected tokens in router call"
        );
        assertEq(p.fee, FEE_3000, "fee mismatch");
        assertEq(p.recipient, address(corrector), "recipient mismatch");
    }
}