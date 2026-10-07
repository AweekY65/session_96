// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

enum Rounding {
    Floor,
    Ceil
}

/// @notice Full-precision multiply-divide helpers (512-bit intermediate),
///         adapted from the well-known OpenZeppelin Math.mulDiv algorithm.
library Math {
    error MulDivOverflow();

    /// @notice Returns floor(x * y / denominator) with full 512-bit precision.
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit product [prod1 prod0] = x * y
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                require(denominator > 0, "mulDiv: div by zero");
                return prod0 / denominator;
            }

            if (denominator <= prod1) revert MulDivOverflow();

            // Divide [prod1 prod0] by denominator, using the standard
            // remainder + factorization trick.
            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator.
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                // Flip twos such that it is 2^256 / twos.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from prod1 into prod0.
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256 (denominator is odd now).
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            result = prod0 * inverse;
        }
    }

    /// @notice Returns x * y / denominator rounded in the given direction.
    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        uint256 result = mulDiv(x, y, denominator);
        if (rounding == Rounding.Ceil && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }
}
