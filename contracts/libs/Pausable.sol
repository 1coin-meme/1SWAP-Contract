// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (security/Pausable.sol)

pragma solidity ^0.8.0;

abstract contract Pausable {

    event Paused(address account, FunctionFlag flag);
    event Unpaused(address account, FunctionFlag flag);

    mapping(FunctionFlag => bool) private _paused;

    enum FunctionFlag {executeAggregate, executeV2Swap, executeV3Swap, cross}

    constructor() {
    }

    modifier whenNotPaused(FunctionFlag flag) {
        _requireNotPaused(flag);
        _;
    }

    modifier whenPaused(FunctionFlag flag) {
        _requirePaused(flag);
        _;
    }

    function paused(FunctionFlag flag) public view virtual returns (bool) {
        return _paused[flag];
    }

    function _requireNotPaused(FunctionFlag flag) internal view virtual {
        require(!paused(flag), "Pausable: paused");
    }

    function _requirePaused(FunctionFlag flag) internal view virtual {
        require(paused(flag), "Pausable: not paused");
    }

    function _pause(FunctionFlag flag) internal virtual whenNotPaused(flag) {
        _paused[flag] = true;
        emit Paused(msg.sender, flag);
    }

    function _unpause(FunctionFlag flag) internal virtual whenPaused(flag) {
        _paused[flag] = false;
        emit Unpaused(msg.sender, flag);
    }

    function pausedOverAll() public view virtual returns (bool executeAggregate, bool executeV2Swap, bool executeV3Swap, bool cross) {
        executeAggregate = _paused[FunctionFlag.executeAggregate];
        executeV2Swap = _paused[FunctionFlag.executeV2Swap];
        executeV3Swap = _paused[FunctionFlag.executeV3Swap];
        cross = _paused[FunctionFlag.cross];
    }
}
