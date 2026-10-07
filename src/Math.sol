// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice 全精度乘除法库：计算 floor/ceil(x * y / d)，中间结果不会溢出 uint256。
library Math {
    enum Rounding {
        Down,
        Up
    }

    error MulDivFailed();

    /// @dev 512 位乘法再除法的经典实现（Remco Bloemen 算法）。
    function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                return prod0 / d;
            }
            if (prod1 >= d) revert MulDivFailed();

            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = d & (0 - d);
            assembly {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;

            return prod0 * inv;
        }
    }

    function mulDiv(uint256 x, uint256 y, uint256 d, Rounding rounding) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, d);
        if (rounding == Rounding.Up && mulmod(x, y, d) > 0) {
            result += 1;
        }
        return result;
    }
}
