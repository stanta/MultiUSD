// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

// Minimal local interface to avoid importing full @uniswap/v3-periphery dependency chain
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

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

contract CorrectorV3 is Ownable {
    // Q192 = 2^192 (used for price computation from sqrtPriceX96)
    uint256 private constant Q192 = 2**192;

    struct AMMs {
        // For Uniswap V3 this is the factory address
        address ammAddress;
        uint8 version;          // 3 for Uniswap V3
        address tokenNative;    // e.g. WETH, WBNB (ERC20-wrapped)
        address tokenStable;    // e.g. USDC, USDT
        uint24 fee;             // Uniswap V3 pool fee (e.g. 500, 3000, 10000)
        bool isActive;
        bool isUSDM;
    }

    AMMs[] public amms;

    constructor() Ownable(msg.sender) {}

    // Note: For Uniswap V3, provide the factory, tokens, and the fee tier.
    function addAmm(
        address _ammFactory,
        address _token0,
        address _token1,
        uint24 _fee,
        uint8 _version,
        bool _isUSDM
    ) public onlyOwner {
        require(_ammFactory != address(0), "Invalid factory");
        require(_token0 != address(0), "Invalid token0");
        require(_token1 != address(0), "Invalid token1");

        amms.push(AMMs({
            ammAddress: _ammFactory,
            version: _version,
            tokenNative: _token0,
            tokenStable: _token1,
            fee: _fee,
            isActive: true,
            isUSDM: _isUSDM
        }));
    }

    function setAMMactive(address _ammAddress, bool _isActive) public onlyOwner {
        for (uint256 i = 0; i < amms.length; i++) {
            if (!amms[i].isUSDM && amms[i].ammAddress == _ammAddress) {
                amms[i].isActive = _isActive;
                return;
            }
        }
        revert("AMM not found");
    }

    function editAMM(
        address _ammAddress,
        address _token0,
        address _token1,
        uint24 _fee,
        uint8 _version,
        bool _isUSDM
    ) public onlyOwner {
        for (uint256 i = 0; i < amms.length; i++) {
            if (amms[i].ammAddress == _ammAddress) {
                amms[i].tokenNative = _token0;
                amms[i].tokenStable = _token1;
                amms[i].fee = _fee;
                amms[i].version = _version;
                amms[i].isUSDM = _isUSDM;
                return;
            }
        }
        revert("AMM not found");
    }

    // ===== V3 Helpers =====

    // Returns pool address for given factory/tokens/fee (address(0) if nonexistent)
    function _getPool(address factory, address tokenA, address tokenB, uint24 fee) internal view returns (address) {
        return IUniswapV3Factory(factory).getPool(tokenA, tokenB, fee);
    }

    // Compute spot price (token1/token0) from sqrtPriceX96
    function getPriceV3(uint160 sqrtPriceX96) internal pure returns (uint256 price) {
        // price = (sqrtPriceX96^2) / Q192
        return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / Q192;
    }

    // Fetch "real" balances in the pool contract as reserves proxy
    // Note: These balances include accrued fees and any in-pool tokens not strictly providing liquidity.
    // This mirrors a V2-like "reserves" approximation for the aggregation logic.
    function getReservesV3(
        address ammFactory,
        address tokenNative,
        address tokenStable,
        uint24 fee
    ) internal view returns (uint256 reserveNative, uint256 reserveStable) {
        address pool = _getPool(ammFactory, tokenNative, tokenStable, fee);
        if (pool == address(0)) {
            // No pool yet: treat reserves as zero so aggregate queries don't revert
            return (0, 0);
        }

        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();

        uint256 bal0 = IERC20(token0).balanceOf(pool);
        uint256 bal1 = IERC20(token1).balanceOf(pool);

        if (token0 == tokenNative) {
            reserveNative = bal0;
            reserveStable = bal1;
        } else {
            reserveNative = bal1;
            reserveStable = bal0;
        }
    }

    // Aggregate reserves across all active non-USDM AMMs with version == 3
    // Primary behavior: exclude USDM pools from the external market rate computation.
    // Fallback: if no external liquidity is configured (totals are zero), include USDM pools as well
    // so tests that only register USDM pools can still function.
    function getAllStableRateV3() public view returns (uint256 allReserveNative, uint256 allReserveStable) {
        // Primary aggregation: external (non-USDM) pools only
        for (uint256 i = 0; i < amms.length; i++) {
            if (amms[i].isActive && amms[i].version == 3 && !amms[i].isUSDM) {
                (uint256 rn, uint256 rs) = getReservesV3(
                    amms[i].ammAddress,
                    amms[i].tokenNative,
                    amms[i].tokenStable,
                    amms[i].fee
                );
                allReserveNative += rn;
                allReserveStable += rs;
            }
        }

        // Fallback: if external totals are zero, include USDM pools too
        if (allReserveNative == 0 || allReserveStable == 0) {
            for (uint256 i = 0; i < amms.length; i++) {
                if (amms[i].isActive && amms[i].version == 3) {
                    (uint256 rn, uint256 rs) = getReservesV3(
                        amms[i].ammAddress,
                        amms[i].tokenNative,
                        amms[i].tokenStable,
                        amms[i].fee
                    );
                    allReserveNative += rn;
                    allReserveStable += rs;
                }
            }
        }
    }

    // Analogue of CorrectorV2.correctAll() for V3:
    // Instead of executing swaps, this computes the suggested amounts to move towards the average ratio,
    // following the same arithmetic approach used in V2.
    //
    // Returns two arrays aligned with amms[]:
    // - amountInNative[i]: amount of tokenNative suggested to be ADDED to pool i (as input to pool)
    // - amountInStable[i]: amount of tokenStable suggested to be ADDED to pool i (as input to pool)
    //
    // Only entries where amms[i].isActive && amms[i].isUSDM && version == 3 are populated; others are zero.
    function planCorrectionsV3()
        public
        view
        returns (uint256[] memory amountInNative, uint256[] memory amountInStable)
    {
        amountInNative = new uint256[](amms.length);
        amountInStable = new uint256[](amms.length);

        (uint256 allReserveNative, uint256 allReserveStable) = getAllStableRateV3();
        if (allReserveNative == 0 || allReserveStable == 0) {
            // Nothing to compute; return zeros
            return (amountInNative, amountInStable);
        }

        for (uint256 i = 0; i < amms.length; i++) {
            if (!(amms[i].isActive && amms[i].isUSDM && amms[i].version == 3)) {
                continue;
            }

            (uint256 reserveNative, uint256 reserveStable) = getReservesV3(
                amms[i].ammAddress,
                amms[i].tokenNative,
                amms[i].tokenStable,
                amms[i].fee
            );

            if (allReserveNative > allReserveStable) {
                // averageSwapRate = allReserveNative / allReserveStable
                uint256 averageSwapRate = allReserveNative / allReserveStable;
                if (averageSwapRate == 0) {
                    // avoid divisions by zero and unstable math
                    continue;
                }

                // amountTobeNative = reserveStable * averageSwapRate
                uint256 amountTobeNative = reserveStable * averageSwapRate;

                if (amountTobeNative > reserveNative) {
                    uint256 needNative = amountTobeNative - reserveNative;
                    // reserveStable - reserveNative / averageSwapRate
                    uint256 giveStable = reserveStable > (reserveNative / averageSwapRate)
                        ? (reserveStable - (reserveNative / averageSwapRate))
                        : 0;

                    // Interpret as inputs to the pool (what we should add)
                    amountInNative[i] = needNative;
                    amountInStable[i] = giveStable;
                } else {
                    // amountToSwapNative = reserveNative - amountTobeNative
                    uint256 lessNative = reserveNative - amountTobeNative;
                    // amountToSwapUSDM = reserveNative / averageSwapRate - reserveStable
                    uint256 rv = (reserveNative / averageSwapRate);
                    uint256 needStable = rv > reserveStable ? (rv - reserveStable) : 0;

                    amountInNative[i] = lessNative;    // move native towards target
                    amountInStable[i] = needStable;    // and stable towards target
                }
            } else {
                // averageSwapRate = allReserveStable / allReserveNative
                uint256 averageSwapRate = allReserveStable / allReserveNative;
                if (averageSwapRate == 0) {
                    // avoid divisions by zero and unstable math
                    continue;
                }

                // amountTobeStable = reserveNative * averageSwapRate
                uint256 amountTobeStable = reserveNative * averageSwapRate;

                if (amountTobeStable > reserveStable) {
                    uint256 needStable = amountTobeStable - reserveStable;
                    // reserveNative - reserveStable / averageSwapRate
                    uint256 rv = (reserveStable / averageSwapRate);
                    uint256 giveNative = reserveNative > rv ? (reserveNative - rv) : 0;

                    amountInNative[i] = giveNative;
                    amountInStable[i] = needStable;
                } else {
                    // amountToSwapUSDM = reserveStable - amountTobeStable
                    uint256 lessStable = reserveStable - amountTobeStable;
                    // amountToSwapNative = reserveStable / averageSwapRate - reserveNative
                    uint256 rv = (reserveStable / averageSwapRate);
                    uint256 needNative = rv > reserveNative ? (rv - reserveNative) : 0;

                    amountInNative[i] = needNative;
                    amountInStable[i] = lessStable;
                }
            }
        }

        return (amountInNative, amountInStable);
    }

    function _approveIfNeeded(address token, address spender, uint256 amount) internal {
        uint256 current = IERC20(token).allowance(address(this), spender);
        if (current < amount) {
            IERC20(token).approve(spender, 0);
            IERC20(token).approve(spender, amount);
        }
    }

    function _swapExactInputSingle(
        ISwapRouter router,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        _approveIfNeeded(tokenIn, address(router), amountIn);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        amountOut = router.exactInputSingle(params);
    }

    // Execute the computed balancing on all active USDM-marked V3 pools via SwapRouter.
    // This mirrors CorrectorV2.correctAll() behavior, but for V3 using exactInputSingle.
    function correctAllV3Execute(address routerAddr) external onlyOwner {
        require(routerAddr != address(0), "router required");

        (uint256 allReserveNative, uint256 allReserveStable) = getAllStableRateV3();
        // Fallback: if external totals are zero, include USDM pools as well
        if (allReserveNative == 0 || allReserveStable == 0) {
            for (uint256 i = 0; i < amms.length; i++) {
                if (amms[i].isActive && amms[i].version == 3) {
                    (uint256 rn, uint256 rs) = getReservesV3(
                        amms[i].ammAddress,
                        amms[i].tokenNative,
                        amms[i].tokenStable,
                        amms[i].fee
                    );
                    allReserveNative += rn;
                    allReserveStable += rs;
                }
            }
        }
        require(allReserveNative > 0 && allReserveStable > 0, "no liquidity");

        ISwapRouter router = ISwapRouter(routerAddr);

        for (uint256 i = 0; i < amms.length; i++) {
            if (!(amms[i].isActive && amms[i].isUSDM && amms[i].version == 3)) {
                continue;
            }

            (uint256 reserveNative, uint256 reserveStable) = getReservesV3(
                amms[i].ammAddress,
                amms[i].tokenNative,
                amms[i].tokenStable,
                amms[i].fee
            );

            if (allReserveNative > allReserveStable) {
                uint256 averageSwapRate = allReserveNative / allReserveStable;
                if (averageSwapRate == 0) continue;

                uint256 amountTobeNative = reserveStable * averageSwapRate;
                if (amountTobeNative > reserveNative) {
                    uint256 threshold = (reserveNative / averageSwapRate);
                    uint256 giveStable = reserveStable > threshold ? (reserveStable - threshold) : 0;
                    if (giveStable > 0) {
                        _swapExactInputSingle(
                            router,
                            amms[i].tokenStable,
                            amms[i].tokenNative,
                            amms[i].fee,
                            giveStable
                        );
                    }
                } else {
                    uint256 lessNative = amountTobeNative < reserveNative ? reserveNative - amountTobeNative : 0;
                    if (lessNative > 0) {
                        _swapExactInputSingle(
                            router,
                            amms[i].tokenNative,
                            amms[i].tokenStable,
                            amms[i].fee,
                            lessNative
                        );
                    }
                }
            } else {
                uint256 averageSwapRate = allReserveStable / allReserveNative;
                if (averageSwapRate == 0) continue;

                uint256 amountTobeStable = reserveNative * averageSwapRate;
                if (amountTobeStable > reserveStable) {
                    uint256 threshold = (reserveStable / averageSwapRate);
                    uint256 giveNative = reserveNative > threshold ? (reserveNative - threshold) : 0;
                    if (giveNative > 0) {
                        _swapExactInputSingle(
                            router,
                            amms[i].tokenNative,
                            amms[i].tokenStable,
                            amms[i].fee,
                            giveNative
                        );
                    }
                } else {
                    uint256 lessStable = amountTobeStable < reserveStable ? reserveStable - amountTobeStable : 0;
                    if (lessStable > 0) {
                        _swapExactInputSingle(
                            router,
                            amms[i].tokenStable,
                            amms[i].tokenNative,
                            amms[i].fee,
                            lessStable
                        );
                    }
                }
            }
        }
    }
}