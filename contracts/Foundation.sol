// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";


import "./lib/SafeMathInt.sol";
import "./lib/UInt256Lib.sol";


import "./interfaces/IPancakeRouter.sol";
import "./lib/PancakeLibrary.sol";

import "./interfaces/IWBNB.sol";


interface IW3F {
    function totalSupply() external view returns (uint256);
    function circulatingSupply() external view returns (uint256);
    function rebase(uint256 epoch, int256 supplyDelta) external returns (uint256);
    function mint(address to, uint256 value) external;
    function burn(address from, uint256 value) external;
    function balanceOf(address who) external view returns (uint256);
    function getEpochAddress(uint256 epoch) external view returns (address);
    function specialTransferFrom(uint256 epoch, address to, uint256 value) external;
}


interface IPriceOracle {
    function update() external;
    function getTWAPrice(address token) external view returns (uint144);
}

interface IMarketCapOracle {
    function updateMarketCaps() external;
    function requestMarketCapsSuccess() external view returns (bool);
    function getCap(uint256 epoch, address token) external view returns (uint256);
    function allCap(uint256 epoch) external view returns(uint256);
}

interface Treasury {
    function withdraw(address token, uint256 amount, address to, string memory reason) external;
}

/**
 * @title W3F Foundation
 */
contract Foundation {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using UInt256Lib for uint256;


    // address public swapFactory;
    IPancakeRouter public swapRouter = IPancakeRouter(address(0x10ED43C718714eb63d5aA57B78B54704E256024E));

    address public WBNB;

    // epoch => user => token => amount
    mapping (uint256 => mapping (address => mapping (address => uint256))) public userDeposits;

    // epoch => token => amount
    mapping (uint256 => mapping (address => uint)) public totalDeposits;


    // user => epochs
    mapping (address => uint256[]) public userEpochs;
    
    // estimate busd paths per token
    // WBNB => [ WBNB, BUSD ]
    // DOT => [ DOT, WBNB, BUSD ]
    // FIL => [ FIL, WBNB, BUSD ]
    mapping (address => address[]) public estimatePaths;

    // split paths per token
    // 
    // WBNB => DOT => [ WBNB, DOT ]
    // WBNB => FIL => [ WBNB, FIL ]
    
    // DOT => WBNB => [ DOT, WBNB ]
    // DOT => FIL => [ DOT, WBNB, FIL ]
    
    // FIL => WBNB => [ FIL, WBNB ]
    // FIL => DOT => [ FIL, WBNB, DOT ]

    // BUSD => WBNB => [ BUSD, WBNB ]
    // BUSD => DOT => [ BUSD, WBNB, DOT ]
    // BUSD => FIL => [ BUSD, WBNB, FIL ]
    mapping (address => mapping (address => address[])) public splitPaths;
    

    // epoch => token => rate
    mapping (uint256 => mapping (address => uint256)) public claimRates;

    uint256 public mintFee = 500; // 5%, base is 10000
    uint256 public rebaseFee = 1; // 0.01% 
    uint256 public feeMax = 10000; // 5%, base is 10000

    
    address[] public tokens;

    mapping (address => uint256) public balances;

    uint256 burnId = 1;
    // id => user => token => amount
    mapping (uint256 => mapping (address => mapping (address => uint256))) public burns;
    mapping (address => uint256[]) public userBurns;

    mapping (uint256 => bool) public redeemed;
    mapping (uint256 => uint256) public redeemTimestamp;
    uint256 public redeemDuration = 30 days;

    struct Transaction {
        bool enabled;
        address destination;
        bytes data;
    }

    event TransactionFailed(address indexed destination, uint index, bytes data);

    // Stable ordering is not guaranteed.
    Transaction[] public transactions;

    event LogRebase(
        uint256 indexed epoch,
        uint256 exchangeRate,
        uint256 rebaseRate,
        int256 requestedSupplyAdjustment,
        uint256 timestampSec
    );

    event Mint(uint256 indexed epoch, uint256 amount, uint256 timestampSec);
    event Burn(uint256 indexed id, address indexed user, uint256 amount, uint256[] tokenAmounts, uint256 timestampSec);
    event Redeem(uint256 indexed id, address indexed user, uint256 timestampSec);

    IW3F public w3f;

    address public treasury;
    address public feeTreasury;

    bool public withdrawable = false;

    // WBNB + BUSD 
    // DOT + BUSD
    // FIL + BUSD
    mapping (address => IPriceOracle) public priceOracles;

    IPriceOracle public BNB_BUSD_Oracle;
    IPriceOracle public w3fOracle;
    IMarketCapOracle public capOracle;


    // Block timestamp of last rebase operation
    uint256 public lastRebaseTimestampSec;

    uint256 public rebaseDuration = 24 hours;

    // The number of rebase cycles since inception
    uint256 public epoch;

    uint256 private constant DECIMALS = 18;

    // Due to the expression in computeSupplyDelta(), MAX_RATE * MAX_SUPPLY must fit into an int256.
    // Both are 18 decimals fixed point numbers.
    uint256 private constant MAX_RATE = 10**6 * 10**DECIMALS;
    // MAX_SUPPLY = MAX_INT256 / MAX_RATE
    uint256 private constant MAX_SUPPLY = ~(uint256(1) << 255) / MAX_RATE;


    address public owner;

    // tokens: 0 => WBNB, 1 => DOT, 2 => FIL, 3 => BUSD
    constructor(address _w3f, address[] memory _tokens) public {
        owner = msg.sender;
        lastRebaseTimestampSec = now;
        WBNB = swapRouter.WETH();
        w3f = IW3F(_w3f);
        tokens = _tokens;

        address wbnb = _tokens[0];
        address dot = _tokens[1];
        address fil = _tokens[2];
        address busd = _tokens[3];

        estimatePaths[wbnb] = [ wbnb, busd ];
        estimatePaths[dot] = [dot, wbnb, busd];
        estimatePaths[fil] = [fil, wbnb, busd];

        splitPaths[wbnb][dot] = [wbnb, dot];
        splitPaths[wbnb][fil] = [wbnb, fil];

        splitPaths[dot][wbnb] = [dot, wbnb];
        splitPaths[dot][fil] = [dot, wbnb, fil];

        splitPaths[fil][wbnb] = [fil, wbnb];
        splitPaths[fil][dot] = [fil, wbnb, dot];

        splitPaths[busd][wbnb] = [busd, wbnb];
        splitPaths[busd][dot] = [busd, wbnb, dot];
        splitPaths[busd][fil] = [busd, wbnb, fil];
    }

    function setTreasury(address _treasury) public onlyOwner {
        treasury = _treasury;
    }

    function setFeeTreasury(address _feeTreasury) public onlyOwner {
        feeTreasury = _feeTreasury;
    }

    function setSwapRouter(address _router) public onlyOwner {
        swapRouter = IPancakeRouter(_router);
    }

    function setPriceOracles(address[] memory _tokens, address[] memory _oracles) public onlyOwner {
        for(uint256 i = 0; i < _tokens.length; i++) {
            priceOracles[_tokens[i]] = IPriceOracle(_oracles[i]);
        }
    }
  
    function setEstimatePath(address token, address[] memory path) public onlyOwner {
        estimatePaths[token] = path;
    }

    function setSplitPath(address[] memory path) public onlyOwner {
        require(path.length >= 2, "Invalid Path");
        splitPaths[path[0]][path[path.length - 1]] = path;
    }

    function setRebaseDuration(uint256 duration) public onlyOwner {
        rebaseDuration = duration;
    }

    function setRedeemDuration(uint256 duration) public onlyOwner {
        redeemDuration = duration;
    }

    function setMarketCapOracle(address oracle) public onlyOwner {
        capOracle = IMarketCapOracle(oracle);
    }

    function setW3FOracle(address oracle) public onlyOwner {
        w3fOracle = IPriceOracle(oracle);
    }

    function setBNB_BUSD_Oracle(address oracle) public onlyOwner {
        BNB_BUSD_Oracle = IPriceOracle(oracle);
    }

    function setWithdrawable(bool b_) public onlyOwner {
        withdrawable = b_;
    }

    function setOwner(address newOwner) public onlyOwner {
        owner = newOwner;
    }

    modifier validToken(address token) {
        bool valid = false;
        for(uint256 i = 0; i < tokens.length; i++) {
            if(tokens[i] == token) {
                valid = true;
                break;
            }
        }
        require(valid, "Unsupported Token");
        _; 
    }

    modifier validBurnId(uint256 _id) { 
        bool valid = false;
        for(uint256 i = 0; i < userBurns[msg.sender].length; i++) {
            if(userBurns[msg.sender][i] == _id) {
                valid = true;
                break;
            }
        }
        require(valid, "Invalid burn");
        _; 
    }

    modifier onlyOwner() { 
        require (msg.sender == owner, "Not Owner"); 
        _; 
    }

    function depositBNB() public payable {
        require(msg.value > 0, "Deposit amount is 0");
        uint256 amount = msg.value;
        IWBNB(WBNB).deposit{value: amount}();
        userDeposits[epoch][msg.sender][WBNB] = userDeposits[epoch][msg.sender][WBNB].add(amount);
        totalDeposits[epoch][WBNB] = totalDeposits[epoch][WBNB].add(amount);
        pushUserEpoch();
    }
    
    function deposit(address token, uint256 amount) public validToken(token) {
        require(amount > 0, "Deposit amount is 0");
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        userDeposits[epoch][msg.sender][token] = userDeposits[epoch][msg.sender][token].add(amount);
        totalDeposits[epoch][token] = totalDeposits[epoch][token].add(amount);
        pushUserEpoch();
    }

    function pushUserEpoch() internal {
        if(userEpochs[msg.sender].length == 0 || userEpochs[msg.sender][userEpochs[msg.sender].length - 1] != epoch) {
            userEpochs[msg.sender].push(epoch);
        }
    }

    function getUserEpochs(address user) public view returns(uint256[] memory) {
        return userEpochs[user];
    } 

    function getDepositAmounts(address user, uint256 _epoch) public view returns(uint256[] memory) {
        uint256[] memory amounts = new uint256[](tokens.length);
        for(uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = userDeposits[_epoch][user][tokens[i]];
        }
        return amounts;
    }


    function mint(uint256 _epoch, uint256 _rebasePrice) internal returns(uint256 minted) {
        require(_epoch == epoch, "Invalid Epoch");

        uint256[] memory usdAmounts = new uint256[](tokens.length);
        uint256 usdTotal = 0;

        // WBNB, DOT, FIL
        for(uint256 i = 0; i < tokens.length - 1; i++) {
            if(totalDeposits[epoch][tokens[i]] > 0) {
                uint256[] memory outs = PancakeLibrary.getAmountsOut(swapRouter.factory(), totalDeposits[epoch][tokens[i]], estimatePaths[tokens[i]]);
                usdAmounts[i] = outs[outs.length - 1];
                usdTotal = usdTotal.add(usdAmounts[i]);
            }
        }
        // BUSD 
        usdAmounts[tokens.length - 1] = totalDeposits[epoch][tokens[tokens.length - 1]];
        usdTotal = usdTotal.add(usdAmounts[tokens.length - 1]);

        if(totalDeposits[epoch][tokens[0]] > 0) {
            // WBNB -> [ DOT, FIL ]
            address[] memory DOT_FIL = new address[](2);
            DOT_FIL[0] =  tokens[1];
            DOT_FIL[1] = tokens[2];
            splitTokens(epoch, tokens[0], DOT_FIL);
        }

        if(totalDeposits[epoch][tokens[1]] > 0) {
            // DOT -> [ WBNB, FIL ]
            address[] memory WBNB_FIL = new address[](2);
            WBNB_FIL[0] =  tokens[0];
            WBNB_FIL[1] = tokens[2];

            splitTokens(epoch, tokens[1], WBNB_FIL);
        }
        

        if(totalDeposits[epoch][tokens[2]] > 0) {
            // FIL -> [ WBNB, DOT ]
            address[] memory WBNB_DOT = new address[](2);
            WBNB_DOT[0] = tokens[0];
            WBNB_DOT[1] = tokens[1];
            splitTokens(epoch, tokens[2], WBNB_DOT);
        }

        if(totalDeposits[epoch][tokens[3]] > 0) {
            // BUSD -> [ WBNB, DOT, FIL ]
            address[] memory WBNB_DOT_FIL = new address[](3);
            WBNB_DOT_FIL[0] = tokens[0];
            WBNB_DOT_FIL[1] = tokens[1];
            WBNB_DOT_FIL[2] = tokens[2];
            splitTokens(epoch, tokens[3], WBNB_DOT_FIL);
        }

        if(usdTotal > 0) {
            minted = usdTotal.div(_rebasePrice);
            address to = w3f.getEpochAddress(epoch);
            w3f.mint(to, minted);

            for(uint256 i = 0; i < tokens.length; i++) {
                claimRates[epoch][tokens[i]] = usdAmounts[i].mul(1e18).div(usdTotal);
            }

            emit Mint(epoch, minted, now);
        }
        
    }

    // withdraw tokens in case of error
    function withdrawTokens() public {
        require(withdrawable, "Can not withdraw");
        for(uint256 i = 0; i < tokens.length; i++) {
            if(userDeposits[epoch][msg.sender][tokens[i]] > 0) {
                uint256 amount = userDeposits[epoch][msg.sender][tokens[i]];
                IERC20(tokens[i]).transfer(msg.sender, amount);
                userDeposits[epoch][msg.sender][tokens[i]] = 0;
                totalDeposits[epoch][tokens[i]] = totalDeposits[epoch][tokens[i]].sub(amount);
            }
        }
    }

    function splitTokens(uint256 _epoch, address _from, address[] memory _toTokens) internal {
        uint256 totalDeposit = totalDeposits[_epoch][_from];
        // 5% mint fee charged
        uint256 fee = totalDeposit.mul(mintFee).div(feeMax);
        uint256 depositAmount = totalDeposit.sub(fee);
        IERC20(_from).transfer(feeTreasury, fee);

        IERC20(_from).approve(address(swapRouter), uint256(-1));
        for(uint256 i = 0; i < _toTokens.length; i++) {
            uint256 amountIn = depositAmount.mul(capOracle.getCap(_epoch, _toTokens[i])).div(capOracle.allCap(_epoch));
            uint256[] memory amounts = swapRouter.swapExactTokensForTokens(amountIn, 0, splitPaths[_from][_toTokens[i]], treasury, now + 1000);
            balances[_toTokens[i]] = balances[_toTokens[i]].add(amounts[amounts.length - 1]);
        }

        // BUSD ignore
        if(_from != tokens[3]) {
            uint256 reserves = depositAmount.mul(capOracle.getCap(_epoch, _from)).div(capOracle.allCap(_epoch));
            IERC20(_from).transfer(treasury, reserves);
            balances[_from] = balances[_from].add(reserves);
        }

        IERC20(_from).approve(address(swapRouter), 0);
    }


    function claim(uint256 _epoch) public {
        address epochAddr = w3f.getEpochAddress(_epoch);
        uint256 balance = w3f.balanceOf(epochAddr);
        
        if(balance == 0) {
            return;
        }

        uint256 unclaimTotal = 0;
        uint256 allClaims = 0;
        uint256[] memory unclaims = new uint256[](tokens.length);

        for(uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];

            if(claimRates[_epoch][token] == 0 || totalDeposits[_epoch][token] == 0) {
                continue;
            }

            uint256 amountForTokens = claimRates[_epoch][token].mul(balance).div(1e18);
            uint256 rate = userDeposits[_epoch][msg.sender][token].mul(1e18).div(totalDeposits[_epoch][token]);
            uint256 amountForUser = amountForTokens.mul(rate).div(1e18);
            allClaims = allClaims.add(amountForUser);

            unclaims[i] = amountForTokens.sub(amountForUser);
            unclaimTotal = unclaimTotal.add(unclaims[i]);

            totalDeposits[_epoch][token] = totalDeposits[_epoch][token].sub(userDeposits[_epoch][msg.sender][token]);
            userDeposits[_epoch][msg.sender][token] = 0;
        }

        if(allClaims == 0) {
            return;
        }

        w3f.specialTransferFrom(_epoch, msg.sender, allClaims);

        for(uint256 i = 0; i < tokens.length; i++) {
            claimRates[_epoch][tokens[i]] = unclaimTotal == 0 ? 0 : unclaims[i].mul(1e18).div(unclaimTotal);
        }
    }

    function getClaimAmount(address user, uint256 _epoch) public view returns(uint256) {
        address epochAddr = w3f.getEpochAddress(_epoch);
        uint256 balance = w3f.balanceOf(epochAddr);
        if(balance == 0) {
            return 0;
        }

        uint256 allClaims = 0;

        for(uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];

            if(claimRates[_epoch][token] == 0 || totalDeposits[_epoch][token] == 0) {
                continue;
            }
            uint256 amountForTokens = claimRates[_epoch][token].mul(balance).div(1e18);
            uint256 rate = userDeposits[_epoch][user][token].mul(1e18).div(totalDeposits[_epoch][token]);
            uint256 amountForUser = amountForTokens.mul(rate).div(1e18);
            allClaims = allClaims.add(amountForUser);
        }

        return allClaims;
    }


    function burn(uint256 amount) public {
        require(amount > 0, "Amount is 0");
        w3f.burn(msg.sender, amount);

        uint256[] memory tokenAmounts = new uint256[](tokens.length);

        burns[burnId][msg.sender][address(w3f)] = amount;
        for(uint256 i = 0; i < tokens.length - 1; i++) {
            uint256 share = balances[tokens[i]].mul(amount).div(w3f.circulatingSupply());
            burns[burnId][msg.sender][tokens[i]] = share;
            tokenAmounts[i] = share;
        }

        userBurns[msg.sender].push(burnId);
        redeemTimestamp[burnId] = now.add(redeemDuration);

        emit Burn(burnId, msg.sender, amount, tokenAmounts, now);

        burnId++;
    }

    function getBurnAmounts(address user, uint256 _burnId) public view returns(uint256[] memory amounts){
        amounts = new uint256[](tokens.length);
        amounts[0] = burns[_burnId][user][address(w3f)];
        for(uint256 i = 0; i < tokens.length - 1; i++) {
            amounts[i + 1] = burns[_burnId][user][tokens[i]];
        }
    }

    function getBurnIds(address user) public view returns(uint256[] memory) {
        return userBurns[user];
    }

    function redeem(uint256 _burnId) public validBurnId(_burnId) {
        require(redeemTimestamp[_burnId] < now, "Redeem time is not up");
        require(!redeemed[_burnId], "Redeemed");

        for(uint256 i = 0; i < tokens.length - 1; i++) {
            uint256 amount = burns[_burnId][msg.sender][tokens[i]];
            balances[tokens[i]] = balances[tokens[i]].sub(amount);
            Treasury(treasury).withdraw(tokens[i], amount, msg.sender, "Redeem");
        }

        uint256[] storage myBurns = userBurns[msg.sender];

        for(uint256 i = 0; i < myBurns.length; i++) {
            if(myBurns[i] == _burnId) {
                myBurns[i] = myBurns[myBurns.length - 1];
                myBurns.pop();
                break;
            }
        }

        redeemed[_burnId] = true;
        emit Redeem(_burnId, msg.sender, now);
    }

    function getBalances() public view returns(uint256[] memory) {
        uint256[] memory vals = new uint256[](tokens.length - 1);
        for(uint256 i = 0; i < tokens.length - 1; i++) {
            vals[i] = balances[tokens[i]];
        }
        return vals;
    }

    function requestMarketCapOracle() external onlyOwner {
        capOracle.updateMarketCaps();
    }

    function rebase() external {
        require(tx.origin == msg.sender);
        require(now >= lastRebaseTimestampSec + rebaseDuration); 
        require(capOracle.requestMarketCapsSuccess(), "Request MarketCap failed");

        lastRebaseTimestampSec = now;

        uint256 allCap = capOracle.allCap(epoch);
        uint256 priceWithCap = 0;

        BNB_BUSD_Oracle.update();

        for(uint256 i = 0; i < tokens.length - 1; i++) {
            priceOracles[tokens[i]].update();
            uint256 cap = capOracle.getCap(epoch, tokens[i]);
            uint256 price = priceOracles[tokens[i]].getTWAPrice(tokens[i]);

            if(WBNB == tokens[i]) {
                priceWithCap = priceWithCap.add(price.mul(cap));
            } else {
                uint256 bnbPrice = BNB_BUSD_Oracle.getTWAPrice(WBNB);
                uint256 tokenPrice = price.mul(bnbPrice).div(1e18);
                priceWithCap = priceWithCap.add(tokenPrice.mul(cap));
            }
        }
        uint256 rebaseRate = priceWithCap.div(allCap).div(1e9);

        if(epoch == 0) {
            uint minted = mint(epoch, rebaseRate);

            emit LogRebase(epoch, 0, rebaseRate, int256(minted), now);

            epoch = epoch.add(1);
        } else {
            w3fOracle.update();

            (uint256 exchangeRate, int256 supplyDelta) = getRebaseValues(rebaseRate);

            uint256 supplyAfterRebase = w3f.rebase(epoch, supplyDelta);
            
            assert(supplyAfterRebase <= MAX_SUPPLY);

            // 0.01% of circulating supply charged
            w3f.mint(feeTreasury, w3f.circulatingSupply().mul(rebaseFee).div(feeMax));

            mint(epoch, rebaseRate);

            execTransactions();

            emit LogRebase(epoch, exchangeRate, rebaseRate, supplyDelta, now);

            epoch = epoch.add(1);
        }
    }
    
    /**
     * @notice Calculates the supplyDelta and returns the current set of values for the rebase
     *
     * @dev The supply adjustment equals (_totalSupply * DeviationFromTargetRate) / rebaseLag
     *      Where DeviationFromTargetRate is (MarketOracleRate - targetRate) / targetRate
     * 
     */    
    
    function getRebaseValues(uint256 targetRate) public view returns (uint256, int256) {

        uint256 exchangeRate = w3fOracle.getTWAPrice(address(w3f));
        exchangeRate = exchangeRate.div(1e9);

        if (exchangeRate > MAX_RATE) {
            exchangeRate = MAX_RATE;
        }

        int256 supplyDelta = computeSupplyDelta(exchangeRate, targetRate);

        if (supplyDelta > 0 && w3f.totalSupply().add(uint256(supplyDelta)) > MAX_SUPPLY) {
            supplyDelta = (MAX_SUPPLY.sub(w3f.totalSupply())).toInt256Safe();
        }

        return (exchangeRate, supplyDelta);
    }


    /**
     * @return Computes the total supply adjustment in response to the exchange rate
     *         and the targetRate.
     */
    function computeSupplyDelta(uint256 rate, uint256 targetRate)
        internal
        view
        returns (int256)
    {
        // if (withinDeviationThreshold(rate, targetRate)) {
        //     return 0;
        // }
        // supplyDelta = totalSupply * (rate - targetRate) / targetRate
        int256 targetRateSigned = targetRate.toInt256Safe();
        return w3f.totalSupply().toInt256Safe()
            .mul(rate.toInt256Safe().sub(targetRateSigned))
            .div(targetRateSigned);
    }


    /**
     * @notice Adds a transaction that gets called for a downstream receiver of rebases
     * @param destination Address of contract destination
     * @param data Transaction data payload
     */
    function addTransaction(address destination, bytes calldata data)
        external
        onlyOwner
    {
        transactions.push(Transaction({
            enabled: true,
            destination: destination,
            data: data
        }));
    }

    function execTransactions() internal {
        for (uint i = 0; i < transactions.length; i++) {
            Transaction storage t = transactions[i];
            if (t.enabled) {
                bool result =
                    externalCall(t.destination, t.data);
                if (!result) {
                    emit TransactionFailed(t.destination, i, t.data);
                    revert("Transaction Failed");
                }
            }
        }
    }

    /**
     * @param index Index of transaction to remove.
     *              Transaction ordering may have changed since adding.
     */
    function removeTransaction(uint index)
        external
        onlyOwner
    {
        require(index < transactions.length, "index out of bounds");

        if (index < transactions.length - 1) {
            transactions[index] = transactions[transactions.length - 1];
        }

        transactions.pop();
    }

    /**
     * @return Number of transactions, both enabled and disabled, in transactions list.
     */
    function transactionsSize()
        external
        view
        returns (uint256)
    {
        return transactions.length;
    }

    /**
     * @dev wrapper to call the encoded transactions on downstream consumers.
     * @param destination Address of destination contract.
     * @param data The encoded data payload.
     * @return True on success
     */
    function externalCall(address destination, bytes memory data)
        internal
        returns (bool)
    {
        bool result;
        assembly {  // solhint-disable-line no-inline-assembly
            // "Allocate" memory for output
            // (0x40 is where "free memory" pointer is stored by convention)
            let outputAddress := mload(0x40)

            // First 32 bytes are the padded length of data, so exclude that
            let dataAddress := add(data, 32)

            result := call(
                sub(gas(), 34710),
                destination,
                0, // transfer value in wei
                dataAddress,
                mload(data),  // Size of the input, in bytes. Stored in position 0 of the array.
                outputAddress,
                0  // Output is ignored, therefore the output size is zero
            )
        }
        return result;
    }    
    
}