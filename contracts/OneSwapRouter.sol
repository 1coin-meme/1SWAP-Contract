// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./libraries/ReentrancyGuard.sol";
import "./libraries/RevertReasonParser.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/OneSwapStructs.sol";
import "./libraries/Ownable.sol";
import "./libraries/Pausable.sol";
import "./libraries/SafeMath.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IOneSwapFees.sol";

contract OneSwapRouter is Ownable, ReentrancyGuard, Pausable {

    using SafeMath for uint256;

    address private _oneswap_swap;
    address private _oneswap_cross;
    address private _oneswap_fees;
    // default: Pre-trade fee model
    mapping(uint8 => bool) private _swap_type_mode;
    // whitelist wrapped native tokens
    mapping(address => bool) private _wrapped_allowed;

    event Receipt(address from, uint256 amount);
    event Withdraw(address indexed token, address indexed executor, address indexed recipient, uint amount);
    event ChangeOneSwap(address indexed previousSwap, address indexed newSwap);
    event ChangeOneSwapCross(address indexed previousCross, address indexed newCross);
    event ChangeOneSwapFees(address indexed previousFees, address indexed newFees);
    event ChangeSwapTypeMode(uint8[] types, bool[] newModes);
    event ChangeWrappedAllowed(address[] wrappeds, bool[] newAllowed);
    event OneSwapped(address indexed srcToken, address indexed dstToken, address indexed dstReceiver, address trader, bool feeMode, uint256 amount, uint256 returnAmount, uint256 minReturnAmount, uint256 fee, uint256 toChainID, string channel, uint256 time);

    constructor(address oneSwap_, address oneSwapCross_, address oneSwapFees_, address executor) Ownable(executor) {
        _oneswap_swap = oneSwap_;
        _oneswap_cross = oneSwapCross_;
        _oneswap_fees = oneSwapFees_;
    }

    receive() external payable {
        emit Receipt(msg.sender, msg.value);
    }

    function oneSwap() external view returns (address) {
        return _oneswap_swap;
    }

    function oneSwapCross() external view returns (address) {
        return _oneswap_cross;
    }

    function oneSwapFees() external view returns (address) {
        return _oneswap_fees;
    }

    function swapTypeMode(uint8 swapType) external view returns (bool) {
        return _swap_type_mode[swapType];
    }

    function wrappedAllowed(address wrapped) external view returns (bool) {
        return _wrapped_allowed[wrapped];
    }

    function changeOneSwap(address newSwap) external onlyExecutor {
        address oldSwap = _oneswap_swap;
        _oneswap_swap = newSwap;
        emit ChangeOneSwap(oldSwap, newSwap);
    }

    function changeOneSwapCross(address newCross) external onlyExecutor {
        address oldCross = _oneswap_cross;
        _oneswap_cross = newCross;
        emit ChangeOneSwapCross(oldCross, newCross);
    }

    function changeOneSwapFees(address newFees) external onlyExecutor {
        address oldFees = _oneswap_fees;
        _oneswap_fees = newFees;
        emit ChangeOneSwapFees(oldFees, newFees);
    }

    function changeSwapTypeMode(uint8[] memory swapTypes) external onlyExecutor {
        bool[] memory newModes = new bool[](swapTypes.length);
        for (uint index; index < swapTypes.length; index++) {
            _swap_type_mode[swapTypes[index]] = !_swap_type_mode[swapTypes[index]];
            newModes[index] = _swap_type_mode[swapTypes[index]];
        }
        emit ChangeSwapTypeMode(swapTypes, newModes);
    }

    function changeWrappedAllowed(address[] calldata wrappeds) external onlyExecutor {
        bool[] memory newAllowed = new bool[](wrappeds.length);
        for (uint index; index < wrappeds.length; index++) {
            _wrapped_allowed[wrappeds[index]] = !_wrapped_allowed[wrappeds[index]];
            newAllowed[index] = _wrapped_allowed[wrappeds[index]];
        }
        emit ChangeWrappedAllowed(wrappeds, newAllowed);
    }

    function changePause(bool isPaused) external onlyExecutor {
        if (isPaused) {
            _pause();
        } else {
            _unpause();
        }
    }

    function _beforeSwap(bool preTradeModel, OneSwapStructs.OneSwapDescription calldata desc) private returns (uint256 swapAmount, uint256 fee, uint256 beforeBalance) {
        if (preTradeModel) {
            fee = IOneSwapFees(_oneswap_fees).getFeeRate(msg.sender, desc.amount, desc.swapType, desc.channel);
        }
        if (TransferHelper.isETH(desc.srcToken)) {
            require(msg.value == desc.amount, "OneSwap: invalid msg.value");
            swapAmount = desc.amount.sub(fee);
        } else {
            if (preTradeModel) {
                TransferHelper.safeTransferFrom(desc.srcToken, msg.sender, address(this), desc.amount);
                TransferHelper.safeTransfer(desc.srcToken, desc.srcReceiver, desc.amount.sub(fee));
            } else {
                TransferHelper.safeTransferFrom(desc.srcToken, msg.sender, desc.srcReceiver, desc.amount);
            }
        }
        if (TransferHelper.isETH(desc.dstToken)) {
            if (preTradeModel) {
                beforeBalance = desc.dstReceiver.balance;
            } else {
                if (desc.swapType == uint8(OneSwapStructs.SwapTypes.swap)) {
                    require(_wrapped_allowed[desc.wrappedNative], "OneSwap: invalid wrapped address");
                    beforeBalance = IERC20(desc.wrappedNative).balanceOf(address(this));
                } else {
                    beforeBalance = address(this).balance;
                }
            }
        } else {
            if (preTradeModel) {
                beforeBalance = IERC20(desc.dstToken).balanceOf(desc.dstReceiver);
            } else {
                beforeBalance = IERC20(desc.dstToken).balanceOf(address(this));
            }
        }
    }

    function _afterSwap(bool preTradeModel, OneSwapStructs.OneSwapDescription calldata desc, uint256 beforeBalance) private returns (uint256 returnAmount, uint256 fee) {
        if (TransferHelper.isETH(desc.dstToken)) {
            if (preTradeModel) {
                returnAmount = desc.dstReceiver.balance.sub(beforeBalance);
                require(returnAmount >= desc.minReturnAmount, "OneSwap: insufficient return amount");
            } else {
                if (desc.swapType == uint8(OneSwapStructs.SwapTypes.swap)) {
                    returnAmount = IERC20(desc.wrappedNative).balanceOf(address(this)).sub(beforeBalance);
                    require(_wrapped_allowed[desc.wrappedNative], "OneSwap: invalid wrapped address");
                    TransferHelper.safeWithdraw(desc.wrappedNative, returnAmount);
                } else {
                    returnAmount = address(this).balance.sub(beforeBalance);
                }
                fee = IOneSwapFees(_oneswap_fees).getFeeRate(msg.sender, returnAmount, desc.swapType, desc.channel);
                returnAmount = returnAmount.sub(fee);
                require(returnAmount >= desc.minReturnAmount, "OneSwap: insufficient return amount");
                TransferHelper.safeTransferETH(desc.dstReceiver, returnAmount);
            }
        } else {
            if (preTradeModel) {
                returnAmount = IERC20(desc.dstToken).balanceOf(desc.dstReceiver).sub(beforeBalance);
                require(returnAmount >= desc.minReturnAmount, "OneSwap: insufficient return amount");
            } else {
                returnAmount = IERC20(desc.dstToken).balanceOf(address(this)).sub(beforeBalance);
                fee = IOneSwapFees(_oneswap_fees).getFeeRate(msg.sender, returnAmount, desc.swapType, desc.channel);
                returnAmount = returnAmount.sub(fee);
                uint256 receiverBeforeBalance = IERC20(desc.dstToken).balanceOf(desc.dstReceiver);
                TransferHelper.safeTransfer(desc.dstToken, desc.dstReceiver, returnAmount);
                returnAmount = IERC20(desc.dstToken).balanceOf(desc.dstReceiver).sub(receiverBeforeBalance);
                require(returnAmount >= desc.minReturnAmount, "OneSwap: insufficient return amount");
            }
        }
    }

    function swap(OneSwapStructs.OneSwapDescription calldata desc, OneSwapStructs.CallbytesDescription calldata callbytesDesc) external payable nonReentrant whenNotPaused {
        require(callbytesDesc.calldatas.length > 0, "OneSwap: data should be not zero");
        require(desc.amount > 0, "OneSwap: amount should be greater than 0");
        require(desc.dstReceiver != address(0), "OneSwap: receiver should be not address(0)");
        require(desc.minReturnAmount > 0, "OneSwap: minReturnAmount should be greater than 0");
        if (callbytesDesc.flag == uint8(OneSwapStructs.Flag.aggregate)) {
            require(desc.srcToken == callbytesDesc.srcToken, "OneSwap: invalid callbytesDesc");
        }
        bool preTradeModel = !_swap_type_mode[desc.swapType];
        (uint256 swapAmount, uint256 fee, uint256 beforeBalance) = _beforeSwap(preTradeModel, desc);

        {
            // bytes4(keccak256(bytes('callbytes(OneSwapStructs.CallbytesDescription)')));
            (bool success, bytes memory result) = _oneswap_swap.call{value: swapAmount}(abi.encodeWithSelector(0xccbe4007, callbytesDesc));
            if (!success) {
                revert(RevertReasonParser.parse(result, "OneSwap:"));
            }
        }

        (uint256 returnAmount, uint256 postFee) = _afterSwap(preTradeModel, desc, beforeBalance);
        if (postFee > fee) {
            fee = postFee;
        }
        _emitOneSwapped(desc, preTradeModel, fee, returnAmount);
    }

    function _beforeCross(OneSwapStructs.OneSwapDescription calldata desc) private returns (uint256 swapAmount, uint256 fee, uint256 beforeBalance) {
        fee = IOneSwapFees(_oneswap_fees).getFeeRate(msg.sender, desc.amount, desc.swapType, desc.channel);
        if (TransferHelper.isETH(desc.srcToken)) {
            require(msg.value == desc.amount, "OneSwap: invalid msg.value");
            swapAmount = desc.amount.sub(fee);
        } else {
            beforeBalance = IERC20(desc.srcToken).balanceOf(_oneswap_cross);
            if (fee == 0) {
                TransferHelper.safeTransferFrom(desc.srcToken, msg.sender, _oneswap_cross, desc.amount);
            } else {
                TransferHelper.safeTransferFrom(desc.srcToken, msg.sender, address(this), desc.amount);
                TransferHelper.safeTransfer(desc.srcToken, _oneswap_cross, desc.amount.sub(fee));
            }
        }
    }

    function cross(OneSwapStructs.OneSwapDescription calldata desc, OneSwapStructs.CallbytesDescription calldata callbytesDesc) external payable nonReentrant whenNotPaused {
        require(callbytesDesc.calldatas.length > 0, "OneSwap: data should be not zero");
        require(desc.amount > 0, "OneSwap: amount should be greater than 0");
        require(desc.srcToken == callbytesDesc.srcToken, "OneSwap: invalid callbytesDesc");
        (uint256 swapAmount, uint256 fee, uint256 beforeBalance) = _beforeCross(desc);

        {
            (bool success, bytes memory result) = _oneswap_cross.call{value: swapAmount}(abi.encodeWithSelector(0xccbe4007, callbytesDesc));
            if (!success) {
                revert(RevertReasonParser.parse(result, "OneSwap:"));
            }
        }

        if (!TransferHelper.isETH(desc.srcToken)) {
            require(IERC20(desc.srcToken).balanceOf(_oneswap_cross) >= beforeBalance, "OneSwap: invalid cross");
        }

        _emitOneSwapped(desc, true, fee, 0);
    }

    function _emitOneSwapped(OneSwapStructs.OneSwapDescription calldata desc, bool preTradeModel, uint256 fee, uint256 returnAmount) private {
        emit OneSwapped(
            desc.srcToken,
            desc.dstToken,
            desc.dstReceiver,
            msg.sender,
            preTradeModel,
            desc.amount,
            returnAmount,
            desc.minReturnAmount,
            fee,
            desc.toChainID,
            desc.channel,
            block.timestamp
        );
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
