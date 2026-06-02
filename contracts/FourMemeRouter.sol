// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./libs/TransferHelper.sol";
import "./libs/RevertReasonParser.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IERC20.sol";

// Router for buying and selling tokens on FourMeme.
//
// buy:          native BNB → FourMeme token. Tokens go directly to caller's wallet.
//
// sell:         FourMeme token → native BNB. FourMeme validates tx.origin == from and sends
//               BNB directly to tx.origin (the caller). Caller must approve FourMeme
//               (not this router) before calling.
//
// buyWithToken: ERC-20 → WBNB (UniswapV2) → unwrap → FourMeme token. Tokens go directly
//               to caller's wallet. Caller approves this router for the input token.
//
// sellForToken: atomically sells FourMeme tokens and delivers an ERC-20 output token.
//   FourMeme.sellToken sends BNB to tx.origin (the user EOA) — not to this router.
//   To work around this, the caller provides the expected BNB as msg.value (a float).
//   The router uses that BNB to do the V2 swap immediately, then calls FourMeme sell which
//   reimburses the caller in BNB directly. Setting minBNBFromSell >= msg.value ensures the
//   caller cannot lose BNB (tx reverts if FourMeme returns less than the float).
contract FourMemeRouter {

    address public immutable fourmeme;
    address public immutable uniswapV2Router;

    // buyTokenAMAP(address token, address to, uint256 funds, uint256 minAmount)
    bytes4 private constant BUY_SELECTOR  = 0x7f79f6df;
    // sellToken(uint256 origin, address token, address from, uint256 amount, uint256 minFunds, uint256 feeRate, address feeRecipient)
    bytes4 private constant SELL_SELECTOR = 0xe63aaf36;

    constructor(address _fourmeme, address _uniswapV2Router) {
        fourmeme        = _fourmeme;
        uniswapV2Router = _uniswapV2Router;
    }

    // Accept BNB refunds from FourMeme on partial bonding-curve fills.
    receive() external payable {}

    // Buy FourMeme tokens with native BNB. Tokens go directly to caller's wallet.
    function buy(address token, uint256 minTokenOut) external payable {
        require(msg.value > 0, "FourMemeRouter: no BNB");

        uint256 bnbBalBefore = address(this).balance - msg.value;

        (bool success, bytes memory result) = fourmeme.call{value: msg.value}(
            abi.encodeWithSelector(BUY_SELECTOR, token, msg.sender, msg.value, minTokenOut)
        );
        if (!success) revert(RevertReasonParser.parse(result, "FourMeme:"));

        // Refund any unused BNB (partial bonding-curve fill)
        uint256 refund = address(this).balance - bnbBalBefore;
        if (refund > 0) TransferHelper.safeTransferETH(msg.sender, refund);
    }

    // Sell FourMeme tokens for native BNB. FourMeme sends BNB directly to tx.origin (the
    // caller EOA). Caller must approve FourMeme — not this router — before calling.
    function sell(address token, uint256 amount, uint256 minBNBOut) external {
        require(amount > 0, "FourMemeRouter: zero amount");

        (bool success, bytes memory result) = fourmeme.call(
            abi.encodeWithSelector(SELL_SELECTOR, uint256(0), token, tx.origin, amount, minBNBOut, uint256(0), address(0))
        );
        if (!success) revert(RevertReasonParser.parse(result, "FourMeme:"));
    }

    // Sell FourMeme tokens and receive an ERC-20 output token atomically.
    // Caller sends msg.value = expected BNB from the FourMeme sell (the "float").
    // The router wraps and swaps that BNB to the output token immediately, then calls
    // FourMeme sell which sends BNB back to tx.origin (caller), reimbursing the float.
    // Set minBNBFromSell >= msg.value to guarantee the caller does not lose BNB.
    // Caller must approve FourMeme (not this router) to spend the FourMeme token.
    function sellForToken(
        address fourMemeToken,
        uint256 amount,
        uint256 minBNBFromSell,     // min BNB FourMeme must return; use >= msg.value to break even
        address[] calldata path,    // must start with WBNB
        uint256 minTokenOut         // min output token from V2 swap
    ) external payable {
        require(amount > 0, "FourMemeRouter: zero amount");
        require(msg.value > 0, "FourMemeRouter: no BNB float");
        require(path.length >= 2, "FourMemeRouter: invalid path");

        // 1. Wrap caller's BNB float → WBNB and swap to output token for caller
        address wbnb = path[0];
        TransferHelper.safeDeposit(wbnb, msg.value);
        TransferHelper.safeApprove(wbnb, uniswapV2Router, msg.value);
        IUniswapV2Router(uniswapV2Router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            msg.value, minTokenOut, path, msg.sender, block.timestamp
        );
        TransferHelper.safeApprove(wbnb, uniswapV2Router, 0);

        // 2. Sell FourMeme token — FourMeme sends BNB directly to tx.origin (caller),
        //    reimbursing the float. minBNBFromSell enforced by FourMeme itself.
        (bool success, bytes memory result) = fourmeme.call(
            abi.encodeWithSelector(SELL_SELECTOR, uint256(0), fourMemeToken, tx.origin, amount, minBNBFromSell, uint256(0), address(0))
        );
        if (!success) revert(RevertReasonParser.parse(result, "FourMeme:"));
    }

    // Buy FourMeme tokens using an ERC-20 input. Swaps inputToken → WBNB via UniswapV2,
    // unwraps to native BNB, then buys on FourMeme. Tokens go directly to caller's wallet.
    // path must end with WBNB. minBNBFromSwap guards the V2 step; minTokenOut guards the
    // FourMeme bonding-curve step. Caller approves this router for inputToken.
    function buyWithToken(
        address inputToken,
        uint256 inputAmount,
        address[] calldata path,
        uint256 minBNBFromSwap,
        address fourMemeToken,
        uint256 minTokenOut
    ) external {
        require(inputAmount > 0, "FourMemeRouter: zero amount");
        require(path.length >= 2, "FourMemeRouter: invalid path");

        // Pull inputToken from caller
        TransferHelper.safeTransferFrom(inputToken, msg.sender, address(this), inputAmount);

        // Swap inputToken → WBNB (FOT-safe: checks actual balance delta, not pre-calculated amounts)
        address wbnb = path[path.length - 1];
        uint256 wbnbBefore = IERC20(wbnb).balanceOf(address(this));
        TransferHelper.safeApprove(inputToken, uniswapV2Router, inputAmount);
        IUniswapV2Router(uniswapV2Router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            inputAmount, minBNBFromSwap, path, address(this), block.timestamp
        );
        TransferHelper.safeApprove(inputToken, uniswapV2Router, 0);

        // Unwrap WBNB → native BNB
        uint256 wbnbReceived = IERC20(wbnb).balanceOf(address(this)) - wbnbBefore;
        TransferHelper.safeWithdraw(wbnb, wbnbReceived);

        // Buy FourMeme token — tokens go directly to caller's wallet via to=msg.sender
        uint256 bnbBalBefore = address(this).balance - wbnbReceived;

        (bool success, bytes memory result) = fourmeme.call{value: wbnbReceived}(
            abi.encodeWithSelector(BUY_SELECTOR, fourMemeToken, msg.sender, wbnbReceived, minTokenOut)
        );
        if (!success) revert(RevertReasonParser.parse(result, "FourMeme:"));

        // Refund any unused BNB
        uint256 refund = address(this).balance - bnbBalBefore;
        if (refund > 0) TransferHelper.safeTransferETH(msg.sender, refund);
    }
}
