// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "./lib/FullMath.sol";
import "./lib/SafeMath.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
}

interface IUniswapV2ERC20 {
    function totalSupply() external view returns (uint256);
}

interface IUniswapV2Pair is IUniswapV2ERC20 {
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );

    function token0() external view returns (address);

    function token1() external view returns (address);
}

interface IBondingCalculator {
    function valuation(address pair_, uint256 amount_)
        external
        view
        returns (uint256 _value);
}

contract MagBondingCalculator is IBondingCalculator {
    using FixedPoint for uint256;
    using FixedPoint for FixedPoint.uq112x112;
    using SafeMath for uint256;
    using SafeMath for uint112;

    address public immutable Time;

    constructor(address _Time) {
        require(_Time != address(0));
        Time = _Time;
    }

    function getKValue(address _pair) public view returns (uint256 k_) {
        uint256 token0 = IERC20(IUniswapV2Pair(_pair).token0()).decimals();
        uint256 token1 = IERC20(IUniswapV2Pair(_pair).token1()).decimals();
        uint256 decimals = token0.add(token1).sub(IERC20(_pair).decimals());

        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(_pair)
            .getReserves();
        k_ = reserve0.mul(reserve1).div(10**decimals);
    }

    function getTotalValue(address _pair) public view returns (uint256 _value) {
        _value = getKValue(_pair).sqrrt().mul(2);
    }

    function valuation(address _pair, uint256 amount_)
        external
        view
        override
        returns (uint256 _value)
    {
        uint256 totalValue = getTotalValue(_pair);
        uint256 totalSupply = IUniswapV2Pair(_pair).totalSupply();

        _value = totalValue
            .mul(FixedPoint.fraction(amount_, totalSupply).decode112with18())
            .div(1e18);
    }

    function markdown(address _pair) external view returns (uint256) {
        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(_pair)
            .getReserves();

        uint256 reserve;
        if (IUniswapV2Pair(_pair).token0() == Time) {
            reserve = reserve1;
        } else {
            reserve = reserve0;
        }
        return
            reserve.mul(2 * (10**IERC20(Time).decimals())).div(
                getTotalValue(_pair)
            );
    }
}
