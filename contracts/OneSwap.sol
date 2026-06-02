// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./libraries/Ownable.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/SafeMath.sol";
import "./libraries/ReentrancyGuard.sol";
import "./libraries/RevertReasonParser.sol";
import "./libraries/OneSwapStructs.sol";
import "./interfaces/IOneSwapAllowed.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV2Pair.sol";

contract OneSwap is Ownable, ReentrancyGuard {

    using SafeMath for uint256;

    address private _oneswap_router;
    address private _oneswap_allowed;
    mapping(address => mapping(address => bool)) private _approves;

    event Receipt(address from, uint256 amount);
    event ChangeOneSwapRouter(address indexed previousRouter, address indexed newRouter);
    event ChangeOneSwapAllowed(address indexed previousAllowed, address indexed newAllowed);
    event Withdraw(address indexed token, address indexed executor, address indexed recipient, uint amount);

    constructor(address executor) Ownable(executor) {}

    receive() external payable {
        emit Receipt(msg.sender, msg.value);
    }

    function oneSwapRouter() public view returns (address) {
        return _oneswap_router;
    }

    function oneSwapAllowed() public view returns (address) {
        return _oneswap_allowed;
    }

    function approves(address token, address caller) public view returns (bool) {
        return _approves[token][caller];
    }

    function changeOneSwapRouter(address newRouter) public onlyExecutor {
        address oldRouter = _oneswap_router;
        _oneswap_router = newRouter;
        emit ChangeOneSwapRouter(oldRouter, newRouter);
    }

    function changeOneSwapAllowed(address newAllowed) public onlyExecutor {
        address oldAllowed = _oneswap_allowed;
        _oneswap_allowed = newAllowed;
        emit ChangeOneSwapAllowed(oldAllowed, newAllowed);
    }

    function _beforeSwap(address srcToken, address dstToken, address approveAddress) private returns (uint256 balance) {
        if (TransferHelper.isETH(dstToken)) {
            balance = address(this).balance;
        } else {
            balance = IERC20(dstToken).balanceOf(address(this));
        }

        if (!TransferHelper.isETH(srcToken)) {
            bool isApproved = _approves[srcToken][approveAddress];
            if (!isApproved) {
                bool allowed = IOneSwapAllowed(oneSwapAllowed()).checkAllowed(uint8(OneSwapStructs.Flag.aggregate), approveAddress, bytes4(0xeeeeeeee));
                require(allowed, "OneSwap: approveAddress not allowed");
                TransferHelper.safeApprove(srcToken, approveAddress, 2**256 - 1);
                _approves[srcToken][approveAddress] = true;
            }
        }
    }

    function callbytes(OneSwapStructs.CallbytesDescription calldata desc) external payable nonReentrant checkRouter {
        if (desc.flag == uint8(OneSwapStructs.Flag.aggregate)) {
            OneSwapStructs.AggregateDescription memory aggregateDesc = OneSwapStructs.decodeAggregateDesc(desc.calldatas);
            swap(desc.srcToken, aggregateDesc);
        } else if (desc.flag == uint8(OneSwapStructs.Flag.swap)) {
            OneSwapStructs.SwapDescription memory swapDesc = OneSwapStructs.decodeSwapDesc(desc.calldatas);
            supportingFeeOn(swapDesc);
        } else {
            revert("OneSwap: invalid flag");
        }
    }

    function swap(address srcToken, OneSwapStructs.AggregateDescription memory desc) internal {
        require(desc.callers.length == desc.calls.length, "OneSwap: invalid calls");
        require(desc.callers.length == desc.needTransfer.length, "OneSwap: invalid callers");
        require(desc.calls.length == desc.amounts.length, "OneSwap: invalid amounts");
        require(desc.calls.length == desc.approveProxy.length, "OneSwap: invalid calldatas");
        uint256 callSize = desc.callers.length;
        for (uint index; index < callSize; index++) {
            bool allowed = IOneSwapAllowed(oneSwapAllowed()).checkAllowed(uint8(OneSwapStructs.Flag.aggregate), desc.callers[index], bytes4(desc.calls[index]));
            require(allowed, "OneSwap: caller not allowed");
            require(desc.callers[index] != address(this), "OneSwap: invalid caller");
            uint beforeBalance = _beforeSwap(srcToken, desc.dstToken, desc.approveProxy[index] == address(0) ? desc.callers[index] : desc.approveProxy[index]);

            if (!TransferHelper.isETH(srcToken)) {
                require(desc.amounts[index] == 0, "OneSwap: invalid call.value");
            }
            {
                (bool success, bytes memory result) = desc.callers[index].call{value: desc.amounts[index]}(desc.calls[index]);
                if (!success) {
                    revert(RevertReasonParser.parse(result, ""));
                }
            }

            if (desc.needTransfer[index] == 1) {
                uint afterBalance = IERC20(desc.dstToken).balanceOf(address(this));
                TransferHelper.safeTransfer(desc.dstToken, desc.receiver, afterBalance.sub(beforeBalance));
            } else if (desc.needTransfer[index] == 2) {
                TransferHelper.safeTransferETH(desc.receiver, address(this).balance.sub(beforeBalance));
            }
        }
    }

    function supportingFeeOn(OneSwapStructs.SwapDescription memory desc) internal {
        require(desc.deadline >= block.timestamp, "OneSwap: expired");
        require(desc.paths.length == desc.pairs.length, "OneSwap: invalid calldatas");
        for (uint i; i < desc.paths.length; i++) {
            address[] memory path = desc.paths[i];
            address[] memory pair = desc.pairs[i];
            uint256 fee = desc.fees[i];
            for (uint256 index; index < path.length - 1; index++) {
                (address input, address output) = (path[index], path[index + 1]);
                (address token0,) = input < output ? (input, output) : (output, input);
                IUniswapV2Pair pairAddress = IUniswapV2Pair(pair[index]);
                uint amountInput;
                uint amountOutput;
                {
                    (uint reserve0, uint reserve1,) = pairAddress.getReserves();
                    (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
                    amountInput = IERC20(input).balanceOf(address(pairAddress)).sub(reserveInput);
                    amountOutput = _getAmountOut(amountInput, reserveInput, reserveOutput, fee);
                }
                (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
                address to = index < path.length - 2 ? pair[index + 1] : desc.receiver;
                pairAddress.swap(amount0Out, amount1Out, to, new bytes(0));
            }
        }
    }

    function _getAmountOut(uint amountIn, uint reserveIn, uint reserveOut, uint fee) private pure returns (uint amountOut) {
        require(amountIn > 0, "OneSwap: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "OneSwap: INSUFFICIENT_LIQUIDITY");
        uint amountInWithFee = amountIn.mul(fee);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(10000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    modifier checkRouter() {
        require(msg.sender == _oneswap_router, "OneSwap: invalid router");
        _;
    }

    function withdrawTokens(address[] memory tokens, address recipient) external onlyExecutor {
        for (uint index; index < tokens.length; index++) {
            uint amount;
            if (TransferHelper.isETH(tokens[index])) {
                amount = address(this).balance;
                TransferHelper.safeTransferETH(recipient, amount);
            } else {
                amount = IERC20(tokens[index]).balanceOf(address(this));
                TransferHelper.safeTransferWithoutRequire(tokens[index], recipient, amount);
            }
            emit Withdraw(tokens[index], msg.sender, recipient, amount);
        }
    }
}
