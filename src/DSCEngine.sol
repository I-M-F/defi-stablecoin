// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/*
 * @title DSCEngine
 * @author Matimu Ignatius
 *
 * The system is designed to be minimal as possible, and have the tokens maintain a 1 token == $1 peg. 
 * This stablecoin has the properties: 
 * - Exogenous Collateral 
 * - Dollar Pegged
 * - Alogrithmically Stable
 * 
 * It is simmilar to DAI if DAI ha no gvernance, no fees and was only backed by wETH and wBTC.
 * 
 * Our DSC system should be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC. 
 * 
 * @notice This contract is the core of the DSC System. 
 It handles all the miniting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 *
 */

contract DSCEngine is ReentrancyGuard {
    ////////////////////////////
    // Errors               ////
    ////////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__NeedsMoreThanZeroCollateral();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactoNotImproved();

    ////////////////////////////
    // State Variables      ////
    ////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // represents 10% bonus for liquidation

    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralToken;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////////
    // Events               ////
    ////////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralReedemed(
        address indexed redeemedFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    ////////////////////////////
    // Modifiers            ////
    ////////////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////////////////
    // Functions            ////
    ////////////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For example ETH / USD, BTC / USD, MKR / USD, etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralToken.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
    // External Functions   ////
    ////////////////////////////

    /**
     * @param tokenCollateralAddress The Address of the token to deposit as collateral
     * @param amountCollateral The Amount of collateral to deposit
     * @param amountDscToMint The Amount of decentralized stablecoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }

    /*
     * @notice follows CEI partern  
     * @param tokenCollateralAddress The Address of the token to deposit as collateral
     * @param amountCollateral The Amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // In order to redeem collateral
    // 1. Must have more collateral than the minimum threshold (Health factor must be over 1 after collateral is pulled)
    // Apply DRY(Don't Repeat Yourself) concept in future(refactor soon) make it modular
    // CEI partern: Check, Effect, Interaction
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param tokenCollateralAddress The collateral token address to redeem
     * @param amountCollateral The Amount of collateral to redeem
     * @param amountDscToBurn The Amount of decentralized stablecoin to burn
     * This function will burn DSC and redeem collateral in one transaction
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // RedeemCollateral func already checks health factor
    }

    /*
     * @notice follows CEI partern  
     * @param amountDscToMint The Amount of decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold 
     */

    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        // Check if the collateral value > DSC amount. TODO price feeds, value
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    //Do we need to check if it breaks health factor?
    function burnDSC(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) {
        _burnDSC(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't need to check if it breaks health factor
    }

    // If we do strat hearing undercollaterization, we need someone to liquidate positions
    // if someone goes below 1, they can get liquidated and pay some to liquidate them
    /**
     * @param user The address of the user wh has broken the health factor
     * @param collateral The erc20 address of the collateral to liqidate from the user
     * @param deptToCover The amount of DSC you want to burn and improve the user health factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking user funds
     * @notice This function working assumes the protocol will be roughly 200%
     * overcollateralized in order for this to work
     * @notice A known bug would be if the protocal were 100% or less collateralized,
     * then we wouldn't be able to incentvise the liuidator
     *
     * Follow CEI partern: check, effect, interaction
     */
    function liquidate(address collateral, address user, uint256 deptToCover)
        external
        moreThanZero(deptToCover)
        nonReentrant
    {
        // TODO: check health factor
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // We want to burn a certain amount of DSC"dept" and take collateral from the user
        uint256 tokenAmountFromDeptCovered = getTokenAmountFromUSD(collateral, deptToCover);
        // incentivise them wiyh a bonus
        //.........2:42 min'redo
        uint256 bonusCollateralAmount = (tokenAmountFromDeptCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDeptCovered + bonusCollateralAmount;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // We nedd to burn DSC
        _burnDSC(deptToCover, user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactoNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    //////////////////////////////////////
    // Private & Internal Functions   ////
    //////////////////////////////////////

    /**
     * @dev Low=level internal function, dont call unless the function calling it is checking for health factor being broken
     *
     */
    function _burnDSC(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool burned = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This conditional is hypothetically unreachable
        if (!burned) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralReedemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _getAccountInfromation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUSD)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    /*
     * Returns how close to liquidation a user is 
     * If a user goes below 1, hen they can get liqidated 
     * @param 
     * @notice  
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collater Value
        (uint256 totalDscMinted, uint256 collateralValueInUSD) = _getAccountInfromation(user);
        //Bug
        // uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_THRESHOLD;
        // return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        return _calculateHealthFactor(totalDscMinted, collateralValueInUSD);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. Check health factor (do they have enough collateral )
        // 2. Revert if they don't
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    //////////////////////////////////////////
    // Public & External View Functions   ////
    //////////////////////////////////////////

    function getTokenAmountFromUSD(address token, uint256 usdAmountInWei) public view returns (uint256) {
        //price of ETH(token)
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalcollateralValueInUSD) {
        // loop through each collateral token, get the amount they have deposited, and map it to the price, to get the USD value
        for (uint256 i = 0; i < s_collateralToken.length; i++) {
            address token = s_collateralToken[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalcollateralValueInUSD += getUSDValue(token, amount);
        }
        return totalcollateralValueInUSD;
    }

    function getUSDValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUSD)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        {
            uint256 collateralAdjustedThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
            return (collateralAdjustedThreshold * PRECISION) / totalDscMinted;
        }
    }

    function getAccountInfromation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUSD)
    {
        (totalDscMinted, collateralValueInUSD) = _getAccountInfromation(user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUSD)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUSD);
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure   returns (uint256) {
        return LIQUIDATION_BONUS;
    }

        function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralToken;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }



    
}
