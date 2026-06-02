// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/IERC20.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

// Simulates FourMeme's buy/sell interface for testing.
// Uses fallback() to dispatch by raw selector.
contract MockFourMeme {

    // Fixed token output per buy — slippage tests pass TOKEN_OUT + 1 as minTokenOut
    uint256 public constant FIXED_TOKEN_OUT = 100_000 * 10**18;

    // buyTokenAMAP(address token, address to, uint256 funds, uint256 minAmount)
    bytes4 private constant BUY_SEL  = 0x7f79f6df;
    // sellToken(uint256,address,address from,uint256,uint256,uint256,address)
    bytes4 private constant SELL_SEL = 0xe63aaf36;

    receive() external payable {}

    fallback() external payable {
        bytes4 sel = bytes4(msg.data);

        if (sel == BUY_SEL) {
            (address token, address to,, uint256 minAmount) =
                abi.decode(msg.data[4:], (address, address, uint256, uint256));
            require(msg.value > 0, "MockFourMeme: no BNB");
            require(FIXED_TOKEN_OUT >= minAmount, "MockFourMeme: slippage");
            IMintable(token).mint(to, FIXED_TOKEN_OUT);

        } else if (sel == SELL_SEL) {
            (, address token, address from, uint256 amount, uint256 minFunds,,) =
                abi.decode(msg.data[4:], (uint256, address, address, uint256, uint256, uint256, address));
            require(from == tx.origin, "MockFourMeme: from != tx.origin");
            IERC20(token).transferFrom(from, address(this), amount);
            require(address(this).balance >= minFunds, "MockFourMeme: insufficient BNB reserve");
            // Real FourMeme sends BNB to tx.origin (the seller), not msg.sender (the router)
            (bool ok,) = tx.origin.call{value: minFunds}("");
            require(ok, "MockFourMeme: BNB send failed");

        } else {
            revert("MockFourMeme: unknown selector");
        }
    }
}
