// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (access/Ownable.sol)
// Add executor extension

pragma solidity ^0.8.0;

abstract contract Ownable {

    address private _executor;
    address private _pendingExecutor;
    bool internal _initialized;

    event ExecutorshipTransferStarted(address indexed previousExecutor, address indexed newExecutor);
    event ExecutorshipTransferred(address indexed previousExecutor, address indexed newExecutor);

    constructor(address newExecutor) {
        require(!_initialized, "Ownable: initialized");
        _transferExecutorship(newExecutor);
        _initialized = true;
    }

    modifier onlyExecutor() {
        _checkExecutor();
        _;
    }

    function executor() public view virtual returns (address) {
        return _executor;
    }

    function pendingExecutor() public view virtual returns (address) {
        return _pendingExecutor;
    }

    function _checkExecutor() internal view virtual {
        require(executor() == msg.sender, "Ownable: caller is not the executor");
    }

    function transferExecutorship(address newExecutor) public virtual onlyExecutor {
        _pendingExecutor = newExecutor;
        emit ExecutorshipTransferStarted(executor(), newExecutor);
    }

    function _transferExecutorship(address newExecutor) internal virtual {
        delete _pendingExecutor;
        address oldExecutor = _executor;
        _executor = newExecutor;
        emit ExecutorshipTransferred(oldExecutor, newExecutor);
    }

    function acceptExecutorship() external {
        address sender = msg.sender;
        require(pendingExecutor() == sender, "Ownable: caller is not the new executor");
        _transferExecutorship(sender);
    }
}
