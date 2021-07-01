// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import '@openzeppelin/contracts/math/SafeMath.sol';
import "@openzeppelin/contracts/access/Ownable.sol";

import './lib/FixedPoint.sol';
import './lib/PancakeOracleLibrary.sol';
import './interfaces/IPancakePair.sol';

import "./ERC20Detailed.sol";


contract PriceOracle is Ownable {
    using FixedPoint for *;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // uniswap
    address public token0;
    address public token1;
    IPancakePair public pair;

    address public foundation;

    // oracle
    uint32 public blockTimestampLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;

    /* ========== CONSTRUCTOR ========== */

    constructor(address lpt, address foundation_) public {
        IPancakePair _pair = IPancakePair(lpt);
        pair = _pair;
        token0 = _pair.token0();
        token1 = _pair.token1();
        price0CumulativeLast = _pair.price0CumulativeLast(); // fetch the current accumulated price value (1 / 0)
        price1CumulativeLast = _pair.price1CumulativeLast(); // fetch the current accumulated price value (0 / 1)
        uint112 reserve0;
        uint112 reserve1;
        (reserve0, reserve1, blockTimestampLast) = _pair.getReserves();
        require(reserve0 != 0 && reserve1 != 0, 'Oracle: NO_RESERVES'); // ensure that there's liquidity in the pair

        foundation = foundation_;
    }

    function setFoundation(address foundation_) public onlyOwner {
        foundation = foundation_;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    /** @dev Updates 1-day EMA price from Pancake.  */
    function update() external {
        require(msg.sender == foundation, "Not foundation");
        (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32 blockTimestamp
        ) = PancakeOracleLibrary.currentCumulativePrices(address(pair));
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        if (timeElapsed == 0) {
            // prevent divided by zero
            return;
        }

        // overflow is desired, casting never truncates
        // cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
        price0Average = FixedPoint.uq112x112(
            uint224((price0Cumulative - price0CumulativeLast) / timeElapsed)
        );
        price1Average = FixedPoint.uq112x112(
            uint224((price1Cumulative - price1CumulativeLast) / timeElapsed)
        );

        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        blockTimestampLast = blockTimestamp;

        emit Updated(price0Cumulative, price1Cumulative);
    }

    function getTWAPrice(address token)
        external
        view
        returns (uint256)
    {
        uint256 decimals = uint256(ERC20Detailed(token).decimals());
        uint144 _price = 0;
        if (token == token0) {
            _price = price0Average.mul(10 ** decimals).decode144();
        } else {
            require(token == token1, 'PriceOracle: INVALID_TOKEN');
            _price = price1Average.mul(10 ** decimals).decode144();
        }

        return uint256(_price);
    }


    event Updated(uint256 price0CumulativeLast, uint256 price1CumulativeLast);
}
