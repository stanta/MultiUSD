// SPDX-License-Identifier: GPL-3.0
    pragma solidity ^0.8.24;

import "@openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-contracts/contracts/access/Ownable.sol";
import "@UniSwapV2/contracts/interfaces/IUniswapV2Pair.sol";
import "@UniSwapV2/contracts/UniswapV2Factory.sol";

contract Balancer is  Ownable {

    struct AMMs {
        address ammAddress;
        uint8 version;
        address tokenNative; // e.g. ETH, BNB
        address tokenStable; // e.g. USDC, USDT
        bool isActive;
        
    }

    // mapping(address => AMMs) public amms; //address ammAddress;
    AMMs[] public amms;
    constructor() Ownable(msg.sender) {
        // Initial setup if needed
    }

    function addAmm(address _ammAddress, address _token0, address _token1, uint8 _version) public onlyOwner {
        require(_ammAddress != address(0), "Invalid AMM address");
        require(_token0 != address(0), "Invalid token0 address");
        require(_token1 != address(0), "Invalid token1 address");
        //todo add check for interfaces of AMM
        amms.push(AMMs({
            ammAddress: _ammAddress,
            version: _version,
            tokenNative: _token0,
            tokenStable: _token1,
            isActive: true
        }));
    }

    function setAMMactive(address _ammAddress, bool _isActive) public onlyOwner {
        for (uint256 i = 0; i < amms.length; i++) {
            if (amms[i].ammAddress == _ammAddress) {
                amms[i].isActive = _isActive;
                return;
            }
        }
        revert("AMM not found");
    } 

    function getAllStableRate() public view returns (uint256 averageRate)   {
        uint256 reserveNative = 0;
        uint256 reserveStable = 0;

        for (uint256 i = 0; i < amms.length; i++) {
            if (amms[i].isActive) {
                if (amms[i].version == 2) {
                        UniswapV2Factory factory = UniswapV2Factory(amms[i].ammAddress);
                    
                        IUniswapV2Pair pair = factory.getPair(amms[i].tokenNative, amms[i].tokenStable);
                        (unit112 reserve0, uint112 reserve1 ) = pair.getReserves();
                        // (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
                        if (pair.token0() == amms[i].tokenNative) {
                            reserveNative += reserve0;
                            reserveStable += reserve1;
                        } else {
                            reserveNative += reserve1;
                            reserveStable += reserve0;
                        }
                        reserveNative += reserve0  ;
                        reserveStable +=  reserve1;
                    }
                // else if (amms[i].version == 3) {
                //         UniswapV3Factory factory = UniswapV3Factory(amms[i].ammAddress);
                //         IUniswapV3Pool pool = factory.getPool(amms[i].tokenNative, amms[i].tokenStable);
                //         (uint160 sqrtPriceX96, int24 tick) = pool.slot0();
                //         reserveNative += (sqrtPriceX96 * sqrtPriceX96) / 1e96;
                //         reserveStable += 1e18 / (sqrtPriceX96 * sqrtPriceX96);
                //     }
                // else if (amms[i].version == 4) {
                //         UniswapV4 amm = UniswapV4(amms[i].ammAddress);
                //     }
                // else {
                //         revert("Unsupported AMM version");
                //     }
                }

             

            }
        averageRate = reserveStable * 1e18 / reserveNative; // Assuming 18 decimals for stablecoin
    }
}
