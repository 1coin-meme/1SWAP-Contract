// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "./libs/Ownable.sol";
import "./libs/TransferHelper.sol";
import "./libs/RevertReasonParser.sol";
import "./libs/SafeMath.sol";
import "./interfaces/IERC20.sol";

contract OneSwapAggregateBridge is Ownable {

    using SafeMath for uint256;

    enum NeedTransferFlag {unnecessary, native, token}

    struct AggregateDescription {
        address dstToken;
        address receiver;
        uint[] amounts;
        uint8[] needTransfer;
        address[] callers;
        address[] approveProxy;
        bytes[] calls;
    }

    struct CallbytesDescription {
        address srcToken;
        bytes calldatas;
    }

    address private _one_swap_router;
    bool private _allowed_enabled;
    mapping(address => bool) private _caller_allowed;
    mapping(address => mapping(address => bool)) private _approves;

    event Receipt(address from, uint256 amount);
    event ChangeCallerAllowed(address[] callers);
    event ChangeAllowedEnabled(bool enabled);
    event ChangeOneSwapRouter(address indexed previousRouter, address indexed newRouter);
    event Withdraw(address indexed token, address indexed executor, address indexed recipient, uint amount);
    event ResetApprove(address indexed token, address indexed caller);

    constructor(address executor) Ownable(executor) {

    }

    receive() external payable {
        emit Receipt(msg.sender, msg.value);
    }

    function oneSwapRouter() public view returns (address) {
        return _one_swap_router;
    }

    function approves(address token, address caller) public view returns (bool) {
        return _approves[token][caller];
    }

    function allowed(address caller) public view returns (bool) {
        return _caller_allowed[caller];
    }

    function allowedEnabled() public view returns (bool) {
        return _allowed_enabled;
    }

    function changeAllowedEnabled() public onlyExecutor {
        _allowed_enabled = !_allowed_enabled;
        emit ChangeAllowedEnabled(_allowed_enabled);
    }

    function changeOneSwapRouter(address newRouter) public onlyExecutor {
        address oldRouter = _one_swap_router;
        _one_swap_router = newRouter;
        emit ChangeOneSwapRouter(oldRouter, newRouter);
    }

    function changeCallerAllowed(address[] calldata callers) public onlyExecutor {
        for (uint i; i < callers.length; i++) {
            _caller_allowed[callers[i]] = !_caller_allowed[callers[i]];
        }
        emit ChangeCallerAllowed(callers);
    }

    function resetApprove(address[] calldata callers, address[] calldata tokens) public onlyExecutor {
        require(callers.length == tokens.length, "OneSwapAggregateBridge: invalid data");
        for (uint i; i < tokens.length; i++) {
            _approves[tokens[i]][callers[i]] = false;
            TransferHelper.safeApprove(tokens[i], callers[i], 0);
            emit ResetApprove(tokens[i], callers[i]);
        }
    }

    function callbytes(CallbytesDescription calldata desc) external payable {
        require(msg.sender == _one_swap_router, "OneSwapAggregateBridge: invalid router");
        AggregateDescription memory aggregateDesc = decodeAggregateDesc(desc.calldatas);
        require(aggregateDesc.callers.length == aggregateDesc.calls.length, "OneSwapAggregateBridge: invalid calls");
        require(aggregateDesc.callers.length == aggregateDesc.needTransfer.length, "OneSwapAggregateBridge: invalid callers");
        require(aggregateDesc.calls.length == aggregateDesc.amounts.length, "OneSwapAggregateBridge: invalid amounts");
        require(aggregateDesc.calls.length == aggregateDesc.approveProxy.length, "OneSwapAggregateBridge: invalid calldatas");
        uint256 callSize = aggregateDesc.callers.length;

        for (uint index; index < callSize; index++) {
            uint256 beforeBalance;
            if (_allowed_enabled) {
                require(_caller_allowed[aggregateDesc.callers[index]], "OneSwapAggregateBridge: invalid caller");
            }
            address approveAddress = aggregateDesc.approveProxy[index] == address(0) ? aggregateDesc.callers[index] : aggregateDesc.approveProxy[index];
            bool isApproved = _approves[desc.srcToken][approveAddress];
            bool isToETH;
            if (TransferHelper.isETH(aggregateDesc.dstToken)) {
                isToETH = true;
            }
            if (!isApproved) {
                TransferHelper.safeApprove(desc.srcToken, approveAddress, type(uint).max);
                _approves[desc.srcToken][approveAddress] = true;
            }
            if (!TransferHelper.isETH(desc.srcToken)) {
                require(aggregateDesc.amounts[index] == 0, "OneSwapAggregateBridge: invalid call.value");
            }
            if (isToETH) {
                beforeBalance = address(this).balance;
            } else {
                beforeBalance = IERC20(aggregateDesc.dstToken).balanceOf(address(this));
            }

            {
                (bool success, bytes memory result) = aggregateDesc.callers[index].call{value: aggregateDesc.amounts[index]}(aggregateDesc.calls[index]);
                if (!success) {
                    revert(RevertReasonParser.parse(result, ""));
                }
            }

            if (aggregateDesc.needTransfer[index] == uint8(NeedTransferFlag.native)) {
                TransferHelper.safeTransferETH(aggregateDesc.receiver, address(this).balance.sub(beforeBalance));
            } else if (aggregateDesc.needTransfer[index] == uint8(NeedTransferFlag.token)) {
                uint afterBalance = IERC20(aggregateDesc.dstToken).balanceOf(address(this));
                TransferHelper.safeTransfer(aggregateDesc.dstToken, aggregateDesc.receiver, afterBalance.sub(beforeBalance));
            }
        }
    }

    function decodeAggregateDesc(bytes calldata calldatas) internal pure returns (AggregateDescription memory desc) {
        desc = abi.decode(calldatas, (AggregateDescription));
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
