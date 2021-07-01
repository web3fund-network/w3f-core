// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import "@openzeppelin/contracts/access/Ownable.sol";


import "./interfaces/IWBNB.sol";



contract Treasury is Ownable {
    using SafeERC20 for IERC20;

    address public wbnb;

    mapping (address => bool) public operators;
    
    modifier onlyOperator() { 
        require(operators[msg.sender], "Not Operator");
        _; 
    }
    
    function addOperator(address user) public onlyOwner {
        operators[user] = true;
    }

    function removeOperator(address user) public onlyOwner {
        operators[user] = false;
    }


    constructor(address _wbnb) public {
        wbnb = _wbnb;
    }

    receive() external payable {
        IWBNB(wbnb).deposit{value: msg.value}();
    }

    function deposit(
        address token,
        uint256 amount,
        string memory reason
    ) public {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, now, reason);
    }

    function withdraw(
        address token,
        uint256 amount,
        address to,
        string memory reason
    ) public onlyOperator {
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawal(msg.sender, to, now, reason);
    }

    event Deposit(address indexed from, uint256 indexed at, string reason);
    event Withdrawal(
        address indexed from,
        address indexed to,
        uint256 indexed at,
        string reason
    );
}
