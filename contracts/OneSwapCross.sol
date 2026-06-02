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

contract OneSwapCross is Ownable, ReentrancyGuard {

    address private _oneswap_router;
    address private _oneswap_allowed;
    address private _wrapped;

    event Receipt(address from, uint256 amount);
    event ChangeOneSwapRouter(address indexed previousRouter, address indexed newRouter);
    event ChangeOneSwapAllowed(address indexed previousAllowed, address indexed newAllowed);
    event Withdraw(address indexed token, address indexed executor, address indexed recipient, uint amount);

    constructor(address wrapped, address executor) Ownable(executor) {
        _wrapped = wrapped;
    }

    receive() external payable {
        emit Receipt(msg.sender, msg.value);
    }

    function oneSwapRouter() public view returns (address) {
        return _oneswap_router;
    }

    function oneSwapAllowed() public view returns (address) {
        return _oneswap_allowed;
    }

    function wrappedNative() public view returns (address) {
        return _wrapped;
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

    function callbytes(OneSwapStructs.CallbytesDescription calldata desc) external payable nonReentrant checkRouter {
        if (desc.flag == uint8(OneSwapStructs.Flag.cross)) {
            OneSwapStructs.CrossDescription memory crossDesc = OneSwapStructs.decodeCrossDesc(desc.calldatas);
            cross(desc.srcToken, crossDesc);
        } else {
            revert("OneSwap: invalid flag");
        }
    }

    function cross(address srcToken, OneSwapStructs.CrossDescription memory crossDesc) internal {
        bool allowed = IOneSwapAllowed(oneSwapAllowed()).checkAllowed(uint8(OneSwapStructs.Flag.cross), crossDesc.caller, bytes4(crossDesc.calls));
        require(allowed, "OneSwap: caller not allowed");
        uint swapAmount;
        if (TransferHelper.isETH(srcToken)) {
            require(msg.value >= crossDesc.amount, "OneSwap: invalid msg.value");
            swapAmount = msg.value;
            if (crossDesc.needWrapped) {
                TransferHelper.safeDeposit(_wrapped, crossDesc.amount);
                TransferHelper.safeApprove(_wrapped, crossDesc.caller, swapAmount);
                swapAmount = 0;
            }
        } else {
            require(IERC20(srcToken).balanceOf(address(this)) >= crossDesc.amount, "OneSwap: invalid amount");
            TransferHelper.safeApprove(srcToken, crossDesc.caller, crossDesc.amount);
        }

        (bool success, bytes memory result) = crossDesc.caller.call{value: swapAmount}(crossDesc.calls);
        if (!success) {
            revert(RevertReasonParser.parse(result, ""));
        }
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
