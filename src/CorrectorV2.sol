// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "UniV2/interfaces/IUniswapV2Pair.sol"; 


// Use interface instead of importing the actual factory
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);
}

contract CorrectorV2 is Ownable {

    struct AMMs {
        address ammAddress;
        uint8 version;
        address tokenNative; // e.g. ETH, BNB
        address tokenStable; // e.g. USDC, USDT
        bool isActive;
        bool isUSDM;
    }

    AMMs[] public amms;
    
    constructor() Ownable(msg.sender) {
        // Initial setup if needed
    }

    function addAmm(address _ammAddress, 
                    address _token0, 
                    address _token1, 
                    uint8 _version,
                    bool _isUSDM) public onlyOwner {
        require(_ammAddress != address(0), "Invalid AMM address");
        require(_token0 != address(0), "Invalid token0 address");
        require(_token1 != address(0), "Invalid token1 address");
        
        amms.push(AMMs({
            ammAddress: _ammAddress,
            version: _version,
            tokenNative: _token0,
            tokenStable: _token1,
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
        uint8 _version, 
        bool _isUSDM
    ) public onlyOwner {
        for (uint256 i = 0; i < amms.length; i++) {
            if (amms[i].ammAddress == _ammAddress) {
                amms[i].tokenNative = _token0;
                amms[i].tokenStable = _token1;
                amms[i].version = _version;
                amms[i].isUSDM = _isUSDM;
                return;
            }
        }
        revert("AMM not found");
    }

    function getReservesV2(address ammAddress, address tokenNative, address tokenStable) 
        internal 
        view 
        returns (uint256 reserveNative, uint256 reserveStable) 
    {
        IUniswapV2Factory factory = IUniswapV2Factory(ammAddress);
        IUniswapV2Pair pair = IUniswapV2Pair(factory.getPair(tokenNative, tokenStable));
        
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        
        if (pair.token0() == tokenNative) {
            reserveNative = reserve0;
            reserveStable = reserve1;
        } else {
            reserveNative = reserve1;
            reserveStable = reserve0;
        }
    }

    function getAllStableRate() public view returns (
        uint256 allReserveNative, 
        uint256 allReserveStable         ) {
        for (uint256 i = 0; i < amms.length; i++) {
            if (amms[i].isActive) {
                if (amms[i].version == 2) {
                    (uint256 thisReserveNative, uint256 thisReserveStable) = getReservesV2(
                        amms[i].ammAddress, 
                        amms[i].tokenNative, 
                        amms[i].tokenStable
                    );
                    allReserveNative += thisReserveNative;
                    allReserveStable += thisReserveStable;
                }
            }
        }
        
    }

    function correctV2 (address ammAddress, 
                        address tokenNative, 
                        address tokenUSDM , 
                        uint amountToswapNative, 
                        uint amountToSwapUSDM) 
        internal

    {
        IUniswapV2Factory factory = IUniswapV2Factory(ammAddress);
        IUniswapV2Pair pair = IUniswapV2Pair(factory.getPair(tokenNative, tokenUSDM));
        
        //swap amount of token
        if (pair.token0() == tokenNative) {
            pair.swap(amountToswapNative, amountToSwapUSDM, address(this), new bytes(0));
        } else {
            pair.swap(amountToSwapUSDM, amountToswapNative, address(this), new bytes(0));
        }
    }

    function correctAll  () public  {
        (uint256 allReserveNative, uint256 allReserveStable) = getAllStableRate();
        for (uint256 i = 0; i < amms.length; i++) {
            if (amms[i].isActive && amms[i].isUSDM  ) {
                if (amms[i].version == 2) {
                    (uint256 reserveNative,
                    uint256 reserveStable) = getReservesV2(
                        amms[i].ammAddress,
                        amms[i].tokenNative,
                        amms[i].tokenStable
                    );

                    if (allReserveNative > allReserveStable) {
                        uint256 averageSwapRate = allReserveNative / allReserveStable ;                   
                        //calculating amounts to swap on this eschange to rate be equal
                        uint256 amountTobeNative = reserveStable * averageSwapRate;
                        if (amountTobeNative > reserveNative) {
                            uint256 amountToSwapNative = amountTobeNative - reserveNative;
                            uint256 amountToSwapUSDM =  reserveStable - reserveNative / averageSwapRate ;
                            correctV2(amms[i].ammAddress, amms[i].tokenNative, amms[i].tokenStable, amountToSwapNative, amountToSwapUSDM);
                        } 
                        else {
                            uint256 amountToSwapNative =  amountTobeNative - reserveNative;
                            uint256 amountToSwapUSDM =  reserveNative / averageSwapRate - reserveStable;

                            correctV2(amms[i].ammAddress, amms[i].tokenNative, amms[i].tokenStable, amountToSwapNative, amountToSwapUSDM);
                        }
                    } else {
                        uint256 averageSwapRate = allReserveStable / allReserveNative ;                   
                        //calculating amounts to swap on this eschange to rate be equal
                        uint256 amountTobeStable = reserveNative * averageSwapRate;
                        if (amountTobeStable > reserveStable) {
                            uint256 amountToSwapUSDM = amountTobeStable - reserveStable;
                            uint256 amountToSwapNative =  reserveNative - reserveStable / averageSwapRate ;
                            correctV2(amms[i].ammAddress, amms[i].tokenNative, amms[i].tokenStable, amountToSwapNative, amountToSwapUSDM);
                        } 
                        else {
                            uint256 amountToSwapUSDM =  amountTobeStable - reserveStable;
                            uint256 amountToSwapNative =  reserveStable / averageSwapRate - reserveNative;

                            correctV2(amms[i].ammAddress, amms[i].tokenNative, amms[i].tokenStable, amountToSwapNative, amountToSwapUSDM);
                        }
                    }


                }  
            }
        }


    }

}
