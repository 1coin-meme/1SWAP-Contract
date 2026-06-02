// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/IERC20.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

// Minimal UniswapV2 router mock.
// swapExactTokensForTokens: pulls path[0] from caller, mints path[last] to `to`
// at a fixed 1:1 rate. Reverts if amountIn < amountOutMin.
contract MockUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        require(amountIn >= amountOutMin, "MockV2Router: slippage");
        IMintable(path[path.length - 1]).mint(to, amountIn);

        amounts = new uint256[](path.length);
        for (uint256 i = 0; i < path.length; i++) {
            amounts[i] = amountIn;
        }
    }
}
