// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import '@openzeppelin/contracts/math/SafeMath.sol';
import "@openzeppelin/contracts/access/Ownable.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import "@chainlink/contracts/src/v0.6/ChainlinkClient.sol";

interface Foundation {
    function epoch() external view returns(uint256);
}

contract MarketCapOracle is Ownable, ChainlinkClient {
    using SafeMath for uint256;

    address private oracle;
    bytes32 private jobId;
    uint256 private fee;

    address public foundation;


    address[] public tokens;

    mapping (address => uint256) public currentCap;

    mapping (bytes32 => address) pendingRequest;

    uint256 public requestTimeout;
    uint256 public lastRequestAt;

    // epoch => token => cap
    mapping (uint256 => mapping (address => uint256)) public caps;
    
    
    // https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=binancecoin
    // https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=polkadot
    // https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=filecoin

    mapping (address => string) public requestUrls;
    
    

    constructor(address _link, address _oracle, bytes32 _jobId) public {
        oracle = _oracle;
        jobId = _jobId;
        setChainlinkToken(_link);

        address wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
        address dot = address(0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402);
        address fil = address(0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153);

        tokens.push(wbnb);
        tokens.push(dot);
        tokens.push(fil);

        requestUrls[wbnb] = "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=binancecoin";
        requestUrls[dot] = "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=polkadot";
        requestUrls[fil] = "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=filecoin";

        fee = 2e17; // 0.2 LINK
    }

    function epoch() public view returns(uint256) {
        return Foundation(foundation).epoch();
    }


    function setFoundation(address _foundation) public onlyOwner {
        foundation = _foundation;
    }

    function setJobId(bytes32 _jobId) public onlyOwner {
        jobId = _jobId;
    }

    function setChainlinkFee(uint256 _fee) external onlyOwner {
        fee = _fee;
    }

    function setRequestUrl(address token, string memory url) public onlyOwner {
        requestUrls[token] = url;
    }

    function updateMarketCaps() external {
        require(msg.sender == foundation, "Forbidden");

        for(uint256 i = 0; i < tokens.length; i++) {
            if(caps[epoch()][tokens[i]] == 0) {
                if(lastRequestAt + requestTimeout < now) {
                    bytes32 requestId = requestMarketCap(tokens[i]);
                    pendingRequest[requestId] = tokens[i];
                }
            }
        }

        lastRequestAt = now;
    }

    function requestMarketCapsSuccess() public view returns(bool) {
        for(uint256 i = 0; i < tokens.length; i++) {
            if(caps[epoch()][tokens[i]] == 0) {
                return false;
            }
        }
        return true;
    }

    function requestMarketCap(address _token) internal returns (bytes32 requestId) {
        Chainlink.Request memory request = buildChainlinkRequest(
           jobId,
           address(this),
           this.setCap.selector
        );

        // Set the request object to perform a GET request with the constructed URL
        request.add("get", requestUrls[_token]);

        // Build path to parse JSON response from CoinGecko
        request.add("path", "0.market_cap");

        // Multiply by 1e18 to format the number as an ether value in wei.
        request.addInt("times", 1e18);

        // Sends the request
        requestId = sendChainlinkRequestTo(oracle, request, fee);
    }

    function setCap(bytes32 _requestId, uint256 _cap) external recordChainlinkFulfillment(_requestId) {
        address token = pendingRequest[_requestId];
        if(caps[epoch()][token] == 0) {
            caps[epoch()][token] = _cap;    
        }
        delete pendingRequest[_requestId];
    }

    function getCap(uint256 _epoch, address token) public view returns(uint256 cap) {
        cap = caps[_epoch][token];
        require(cap > 0, "Cap is 0");
    }

    function allCap(uint256 _epoch) public view returns(uint256) {
        uint256 sumCap = 0;

        for(uint256 i = 0; i < tokens.length; i++) {
            sumCap = sumCap.add(caps[_epoch][tokens[i]]);
        }

        return sumCap;
    }

    function setCaps(uint256 _epoch, address[] memory _tokens, uint256[] memory _caps) external onlyOwner {
        require(_tokens.length == tokens.length);
        require(_caps.length == tokens.length);

        for(uint256 i = 0; i < _tokens.length; i++) {
            caps[_epoch][_tokens[i]] = _caps[i];
        }
    }

    function withdrawLink() external onlyOwner {
        IERC20 linkToken = IERC20(chainlinkTokenAddress());
        linkToken.transfer(owner(), linkToken.balanceOf(address(this)));
    }
}
