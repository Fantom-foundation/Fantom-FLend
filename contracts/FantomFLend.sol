pragma solidity ^0.5.0;

import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Mintable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./FantomCollateral.sol";
import "./interfaces/IPriceOracle.sol";

// FantomFLend implements the contract of core DeFi function
// for lending and borrowing tokens against a deposited collateral.
// The collateral management is linked from the Fantom Collateral
// implementation.
contract FantomFLend is Ownable, ReentrancyGuard, FantomCollateral {
    // define libs
    using SafeMath for uint256;
    using Address for address;
    using SafeERC20 for ERC20;

    // feePool keeps information about the fee collected from
    // lending internal operations in fee tokens identified below (fUSD).
    uint256 public feePool;

    // Borrow is emitted on confirmed token loan against user's collateral value.
    event Borrow(address indexed token, address indexed user, uint256 amount, uint256 timestamp);

    // Repay is emitted on confirmed token repay of user's debt of the token.
    event Repay(address indexed token, address indexed user, uint256 amount, uint256 timestamp);

    // -------------------------------------------------------------
    // Price and value calculation related utility functions
    // -------------------------------------------------------------

    // fLendPriceOracle returns the address of the price
    // oracle aggregate used by the collateral to get
    // the price of a specific token.
    function fLendPriceOracle() public pure returns (address) {
        return address(0x03AFBD57cfbe0E964a1c4DBA03B7154A6391529b);
    }

    // fLendNativeToken returns the identification of native
    // tokens as recognized by the DeFi module.
    function fLendNativeToken() public pure returns (address) {
        return address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    }

    // fLendFeeToken returns the identification of the token
    // we use for fee by the fLend DeFi module (fUSD).
    function fLendFeeToken() public pure returns (address) {
        return address(0xf15Ff135dc437a2FD260476f31B3547b84F5dD0b);
    }

    // fLendPriceDigitsCorrection returns the correction required
    // for FTM/ERC20 (18 digits) to another 18 digits number exchange
    // through an 8 digits USD (ChainLink compatible) price oracle
    // on any lending price value calculation.
    function fLendPriceDigitsCorrection() public pure returns (uint256) {
        // 10 ^ (srcDigits - (dstDigits - priceDigits))
        // return 10 ** (18 - (18 - 8));
        return 100000000;
    }

    // fLendFee returns the current value of the borrowing fee used
    // for lending operations.
    // The value is returned in 4 decimals; 25 = 0.0025 = 0.25%
    function fLendFee() public pure returns (uint256) {
        return 25;
    }

    // fLendFeeDigitsCorrection represents the value to be used
    // to adjust result decimals after applying fee to a value calculation.
    function fLendFeeDigitsCorrection() public pure returns (uint256) {
        return 10000;
    }

    // -------------------------------------------------------------
    // Lending functions below
    // -------------------------------------------------------------

    // borrow allows user to borrow a specified token against already established
    // collateral. The value of the collateral must be in at least <colLowestRatio4dec>
    // ratio to the total user's debt value on borrowing.
    function borrow(address _token, uint256 _amount) external nonReentrant
    {
        // make sure the debt amount makes sense
        require(_amount > 0, "non-zero amount expected");

        // native tokens can not be borrowed through this contract
        require(_token != fLendNativeToken(), "native token not borrowable");

        // make sure there is some collateral established by this user
        // we still need to re-calculate the current value though, since the value
        // could have changed due to exchange rate fluctuation
        require(_collateralValue[msg.sender] > 0, "missing collateral");

        // what is the value of the borrowed token?
        uint256 tokenValue = IPriceOracle(fLendPriceOracle()).getPrice(_token);
        require(tokenValue > 0, "token has no value");

        // calculate the entry fee and remember the value we gained
        uint256 fee = _amount
                                .mul(tokenValue)
                                .mul(fLendFee())
                                .div(fLendFeeDigitsCorrection())
                                .div(fLendPriceDigitsCorrection());
        feePool = feePool.add(fee);

        // register the debt of the fee in the fee token
        _debtByTokens[fLendFeeToken()][msg.sender] = _debtByTokens[fLendFeeToken()][msg.sender].add(fee);
        _debtByUsers[msg.sender][fLendFeeToken()] = _debtByUsers[msg.sender][fLendFeeToken()].add(fee);
        enrolDebt(fLendFeeToken(), msg.sender);

        // register the debt of borrowed token
        _debtByTokens[_token][msg.sender] = _debtByTokens[_token][msg.sender].add(_amount);
        _debtByUsers[msg.sender][_token] = _debtByUsers[msg.sender][_token].add(_amount);
        enrolDebt(_token, msg.sender);

        // recalculate current collateral and debt values in fUSD
        uint256 cCollateralValue = collateralValue(msg.sender);
        uint256 cDebtValue = debtValue(msg.sender);

        // minCollateralValue is the minimal collateral value required for the current debt
        // to be within the minimal allowed collateral to debt ratio
        uint256 minCollateralValue = cDebtValue
                                        .mul(collateralLowestDebtRatio4dec())
                                        .div(collateralRatioDecimalsCorrection());

        // does the new state obey the enforced minimal collateral to debt ratio?
        require(cCollateralValue >= minCollateralValue, "insufficient collateral");

        // update the current collateral and debt value
        _collateralValue[msg.sender] = cCollateralValue;
        _debtValue[msg.sender] = cDebtValue;

        // transfer borrowed tokens to the user's address from the local
        // liquidity pool
        ERC20(_token).safeTransfer(msg.sender, _amount);

        // emit the borrow notification
        emit Borrow(_token, msg.sender, _amount, block.timestamp);
    }

    // repay allows user to return some of the debt of the specified token
    // the repay does not collect any fees and is not validating the user's total
    // collateral to debt position.
    function repay(address _token, uint256 _amount) external nonReentrant
    {
        // make sure the amount repaid makes sense
        require(_amount > 0, "non-zero amount expected");

        // native tokens can not be borrowed through this contract
        // so there is no debt to be repaid on it
        require(_token != fLendNativeToken(), "native token not borrowable");

        // subtract the returned amount from the user debt
        _debtByTokens[_token][msg.sender] = _debtByTokens[_token][msg.sender].sub(_amount, "insufficient debt outstanding");
        _debtByUsers[msg.sender][_token] = _debtByUsers[msg.sender][_token].sub(_amount, "insufficient debt outstanding");

        // update current collateral and debt amount state
        _collateralValue[msg.sender] = collateralValue(msg.sender);
        _debtValue[msg.sender] = debtValue(msg.sender);

        // collect the tokens to be returned back to the liquidity pool
        ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        // emit the repay notification
        emit Repay(_token, msg.sender, _amount, block.timestamp);
    }
}
