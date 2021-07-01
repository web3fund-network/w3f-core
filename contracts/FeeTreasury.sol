// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract FeeTreasury is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address[] public recipients;
    mapping (address => uint) public percentages; // base is 10000

    address[] public tokens;
    


    modifier onlyRecipient() { 
        bool isRecipient = false;
        for(uint256 i = 0; i < recipients.length; i++) {
            if(recipients[i] == msg.sender) {
                isRecipient = true;
                break;
            }
        }
        require(isRecipient, "Invalid recipient");
        _; 
    }

    constructor(address[] memory _tokens) public {
        tokens = _tokens;
    }
    

    function addRecipient(address user, uint256 percentage) public onlyOwner {
        recipients.push(user);
        percentages[user] = percentage;
    }

    function removeRecipient(address user) public onlyOwner {
        for(uint256 i = 0; i < recipients.length; i++) {
            if(recipients[i] == user) {
                recipients[i] == recipients[recipients.length - 1];
                recipients.pop();
                delete percentages[user];
                break;
            }
        }
    }

    function withdraw() public onlyRecipient {
        for(uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            for(uint256 j = 0; j < recipients.length; j++) {
                uint256 val = balance.mul(percentages[recipients[j]]).div(10000);
                IERC20(tokens[i]).transfer(recipients[j], val);
            }
        }
    }
}
