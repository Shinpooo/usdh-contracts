// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title USDHVault
 * @dev An ETH (WETH)-backed stablecoin system called USDH.
 * Users deposit WETH as collateral and can mint USDH (an ERC20 token) up to a maximum LTV.
 * They burn USDH to reduce their debt and eventually withdraw collateral.
 * Liquidation is triggered if the vault's minted debt exceeds a certain percentage (the liquidationThreshold)
 * of the collateral's USD value.
 *
 * Parameters:
 *  - maxLTV: Maximum loan-to-value ratio (in percent) allowed for minting.
 *  - liquidationThreshold: If minted debt exceeds this percentage of collateral value, the vault is liquidatable.
 *  - liquidationPenalty: Bonus percentage given to liquidators during liquidation.
 */
contract USDHVault is ERC20 {
    using SafeERC20 for IERC20;

    // Only accepted collateral is WETH.
    IERC20 public immutable weth;

    // Chainlink price feed for WETH/USD.
    AggregatorV3Interface public immutable priceFeed;

    // Maximum loan-to-value ratio allowed (in percent). For example, 66 means a user may mint up to 66% of collateral value.
    uint public maxLTV;
    // Liquidation threshold (in percent). For example, 80 means the vault becomes liquidatable if debt > 80% of collateral value.
    uint public liquidationThreshold;
    // Liquidation penalty percentage (e.g., 10 means the liquidator seizes collateral worth 110% of the repaid debt).
    uint public liquidationPenaltyBP;   // e.g. 500 (basis points, i.e. 5%)
    address protocol;

    // Tracks each user's deposited WETH (collateral) and minted USDH amount.
    mapping(address => uint) public collateral;
    mapping(address => uint) public minted;

    /**
     * @notice Constructor sets up the contract.
     * @param _weth Address of the WETH token contract.
     * @param _priceFeed Address of the Chainlink WETH/USD price feed.
     * @param _maxLTV Maximum LTV allowed (in percent) for minting.
     * @param _liquidationThreshold Threshold (in percent) at which a vault becomes liquidatable.
     * @param _liquidationPenaltyBP Liquidation penalty percentage (in percent).
     */
    constructor(
        address _weth,
        address _priceFeed,
        uint _maxLTV,
        uint _liquidationThreshold,
        uint _liquidationPenaltyBP,
        address _protocol
    ) ERC20("USDH", "USDH") {
        require(_weth != address(0), "Invalid WETH address");
        require(_priceFeed != address(0), "Invalid price feed address");
        // It is typical to require liquidationThreshold > maxLTV.
        require(_liquidationThreshold > _maxLTV, "Liquidation threshold must exceed max LTV");

        weth = IERC20(_weth);
        priceFeed = AggregatorV3Interface(_priceFeed);
        maxLTV = _maxLTV;
        liquidationThreshold = _liquidationThreshold;
        liquidationPenaltyBP = _liquidationPenaltyBP;
        protocol = _protocol;
    }

    /**
     * @notice Deposit WETH into your vault.
     * @param amount Amount of WETH (in wei) to deposit.
     */
    function deposit(uint amount) external {
        require(amount > 0, "Amount must be > 0");
        collateral[msg.sender] += amount;
        weth.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw WETH from your vault.
     * @param amount Amount of WETH (in wei) to withdraw.
     * Requirements: After withdrawal, the vault's minted debt must not exceed maxLTV of the remaining collateral value.
     */
    function withdraw(uint amount) external {
        require(collateral[msg.sender] >= amount, "Not enough collateral");
        uint newCollateral = collateral[msg.sender] - amount;
        uint collateralValueUSD = (newCollateral * getLatestPrice()) / 1e18;
        // Ensure minted debt remains ≤ maxLTV % of collateral's USD value.
        require(
            minted[msg.sender] <= (collateralValueUSD * maxLTV) / 100,
            "Withdrawal would breach max LTV"
        );
        collateral[msg.sender] = newCollateral;
        weth.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Mint new USDH stablecoins against your deposited WETH.
     * @param amount Amount of USDH to mint (with 18 decimals).
     * Requirements: The total minted USDH must not exceed maxLTV % of the collateral's USD value.
     */
    function mintStablecoin(uint amount) external {
        require(amount > 0, "Amount must be > 0");
        uint newMinted = minted[msg.sender] + amount;
        uint collateralValueUSD = (collateral[msg.sender] * getLatestPrice()) / 1e18;
        require(
            newMinted <= (collateralValueUSD * maxLTV) / 100,
            "Insufficient collateral to mint this amount"
        );
        minted[msg.sender] = newMinted;
        _mint(msg.sender, amount);
    }

    /**
     * @notice Burn USDH to reduce your debt and free up collateral.
     * @param amount Amount of USDH to burn.
     */
    function burnStablecoin(uint amount) external {
        require(minted[msg.sender] >= amount, "Burn amount exceeds minted amount");
        minted[msg.sender] -= amount;
        _burn(msg.sender, amount);
    }

    /**
     * @notice Liquidate an undercollateralized vault.
     * @param user The vault owner to liquidate.
     * Requirements:
     * - The vault must be undercollateralized: minted debt > (liquidationThreshold % of collateral value).
     * - Liquidator can cover at most 50% of the user's debt in one call.
     * - Liquidator must burn the corresponding USDH.
     * In exchange, the liquidator receives WETH collateral plus a liquidation bonus.
     */
    function liquidateFull(address user) external {
        uint fullDebt = minted[user];
        require(fullDebt > 0, "No debt");
        require(isUndercollateralized(user), "Vault is healthy");

        uint price = getLatestPrice();
        // Convert fullDebt (USDH, 18 decimals) to its ETH equivalent (in wei)
        uint debtETH = (fullDebt * 1e18) / price;
        require(debtETH <= collateral[user], "Insufficient collateral for liquidation");

        // Calculate the ideal extra penalty in ETH terms.
        uint extraIdeal = (debtETH * liquidationPenaltyBP) / 10000;

        // Extra collateral available above debtETH.
        uint extraAvailable = collateral[user] - debtETH;

        // Actual extra is the minimum of extraIdeal and extraAvailable.
        uint actualExtra = extraIdeal > extraAvailable ? extraAvailable : extraIdeal;

        // Liquidator bonus: min(actualExtra, extraIdeal/2)
        uint idealHalf = extraIdeal / 2;
        uint liquidatorBonus = actualExtra > idealHalf ? idealHalf : actualExtra;
        // Protocol fee is whatever remains from actualExtra after paying the liquidator bonus.
        uint protocolFee = actualExtra > liquidatorBonus ? actualExtra - liquidatorBonus : 0;

        // Total collateral to seize is the sum of debtETH and the actual extra.
        uint seized = debtETH + actualExtra;

        // Update the user's vault: clear the debt and reduce collateral.
        minted[user] = 0;
        collateral[user] -= seized;

        // Liquidator burns fullDebt USDH from their balance.
        _burn(msg.sender, fullDebt);
        // Liquidator receives the ETH equivalent of the debt plus their bonus.
        uint liquidatorPayout = debtETH + liquidatorBonus;
        weth.safeTransfer(msg.sender, liquidatorPayout);
        // Protocol fee is sent to the designated fee recipient (e.g., the contract owner).
        if (protocolFee > 0) {
            weth.safeTransfer(protocol, protocolFee);
        }
    }


    /**
     * @notice Check if a user's vault is undercollateralized.
     * @param user The vault owner's address.
     * @return True if the vault's minted debt exceeds liquidationThreshold % of the collateral's USD value.
     */
    function isUndercollateralized(address user) public view returns (bool) {
        uint collateralValueUSD = (collateral[user] * getLatestPrice()) / 1e18;
        return minted[user] > (collateralValueUSD * liquidationThreshold) / 100;
    }

    /**
     * @notice Fetch the latest WETH/USD price from Chainlink.
     * @return Price in 18 decimals.
     * Assumes the price feed returns 8 decimals and converts it accordingly.
     */
    function getLatestPrice() public view returns (uint) {
        (, int price, , ,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price from oracle");
        // Convert price from 8 decimals to 18 decimals.
        return uint(price) * 1e10;
    }
}
