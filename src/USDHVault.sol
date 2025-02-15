// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title USDHVault
 * @dev An ETH (WETH)-backed stablecoin system called USDH.
 * Users deposit WETH as collateral and can mint USDH (an ERC20 token) up to a specified collateral ratio.
 * They burn USDH to reduce their debt and eventually withdraw collateral.
 * Liquidation is triggered if the vault's collateral falls below the liquidation ratio.
 *
 * Two ratios are used:
 *  - mintingCollateralRatio: The ratio required to mint new stablecoins (e.g., 150 means 150%).
 *  - liquidationCollateralRatio: The ratio below which a vault is liquidated (e.g., 125 means 125%).
 */
contract USDHVault is ERC20, Ownable {
    using SafeERC20 for IERC20;

    // Only accepted collateral is WETH.
    IERC20 public immutable weth;

    // Chainlink price feed for WETH/USD.
    AggregatorV3Interface public immutable priceFeed;

    // Ratio required to mint USDH. For example, 150 means collateral must be 150% of the minted USDH value.
    uint public mintingCollateralRatio;
    
    // Ratio below which vaults become liquidatable. For example, 125 means liquidation if collateral falls below 125% of debt.
    uint public liquidationCollateralRatio;
    
    // Liquidation penalty percentage (e.g., 10 means a 10% penalty).
    uint public liquidationPenalty;

    // Tracks each user's deposited WETH (collateral) and minted USDH amount.
    mapping(address => uint) public collateral;
    mapping(address => uint) public minted;

    /**
     * @notice Constructor sets up the contract.
     * @param _weth Address of the WETH token contract.
     * @param _priceFeed Address of the Chainlink WETH/USD price feed.
     * @param _mintingCollateralRatio Collateral ratio for minting (e.g., 150 for 150%).
     * @param _liquidationCollateralRatio Collateral ratio for liquidation (e.g., 125 for 125%).
     * @param _liquidationPenalty Liquidation penalty percentage (e.g., 10 for 10%).
     */
    constructor(
        address _weth,
        address _priceFeed,
        uint _mintingCollateralRatio,
        uint _liquidationCollateralRatio,
        uint _liquidationPenalty
    ) ERC20("USDH", "USDH") {
        require(_weth != address(0), "Invalid WETH address");
        require(_priceFeed != address(0), "Invalid price feed address");
        // Ensure the minting ratio is higher than the liquidation ratio.
        require(_mintingCollateralRatio > _liquidationCollateralRatio, "Minting ratio must exceed liquidation ratio");

        weth = IERC20(_weth);
        priceFeed = AggregatorV3Interface(_priceFeed);
        mintingCollateralRatio = _mintingCollateralRatio;
        liquidationCollateralRatio = _liquidationCollateralRatio;
        liquidationPenalty = _liquidationPenalty;
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
     * Requirements: After withdrawal, the vault must remain safely collateralized at the minting ratio.
     */
    function withdraw(uint amount) external {
        require(collateral[msg.sender] >= amount, "Not enough collateral");
        uint newCollateral = collateral[msg.sender] - amount;
        // Ensure remaining collateral (in USD) is sufficient per the minting ratio.
        require(
            (newCollateral * getLatestPrice()) * 100 >= minted[msg.sender] * mintingCollateralRatio * 1e18,
            "Withdrawal would breach collateral ratio"
        );
        collateral[msg.sender] = newCollateral;
        weth.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Mint new USDH stablecoins against your deposited WETH.
     * @param amount Amount of USDH to mint (with 18 decimals).
     * Requirements: Your vault's collateral (in USD) must be at least mintingCollateralRatio times your minted debt.
     */
    function mintStablecoin(uint amount) external {
        require(amount > 0, "Amount must be > 0");
        uint newMinted = minted[msg.sender] + amount;
        uint collateralValueUSD = (collateral[msg.sender] * getLatestPrice()) / 1e18;
        // Ensure new minted USDH does not exceed allowed debt based on the minting ratio.
        require(
            collateralValueUSD * 100 >= newMinted * mintingCollateralRatio,
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
     * @param debtToCover The amount of USDH debt the liquidator will cover.
     * Requirements:
     * - The vault must be undercollateralized per the liquidation ratio.
     * - Liquidator can cover at most 50% of the user's debt in one call.
     * - Liquidator must burn the corresponding USDH.
     * In exchange, the liquidator receives WETH collateral plus a penalty.
     */
    function liquidate(address user, uint debtToCover) external {
        require(isUndercollateralized(user), "Vault is not undercollateralized");
        require(debtToCover <= minted[user] / 2, "Can only liquidate up to 50% of debt at a time");

        uint price = getLatestPrice();
        // Calculate collateral to seize in WETH, applying the liquidation penalty.
        // collateralToSeize = (debtToCover * (100 + penalty) * 1e18) / (100 * price)
        uint collateralToSeize = (debtToCover * (100 + liquidationPenalty) * 1e18) / (100 * price);
        require(collateral[user] >= collateralToSeize, "Not enough collateral to seize");

        minted[user] -= debtToCover;
        collateral[user] -= collateralToSeize;

        // Liquidator burns the USDH equal to debtToCover.
        _burn(msg.sender, debtToCover);
        // Transfer the seized WETH to the liquidator.
        weth.safeTransfer(msg.sender, collateralToSeize);
    }

    /**
     * @notice Check if a user's vault is undercollateralized based on the liquidation ratio.
     * @param user The vault owner's address.
     * @return True if the vault's collateral (in USD) is less than minted debt multiplied by liquidationCollateralRatio.
     */
    function isUndercollateralized(address user) public view returns (bool) {
        uint collateralValueUSD = (collateral[user] * getLatestPrice()) / 1e18;
        return collateralValueUSD * 100 < minted[user] * liquidationCollateralRatio;
    }

    /**
     * @notice Fetch the latest WETH/USD price from Chainlink.
     * @return Price in 18 decimals.
     * Assumes the price feed returns 8 decimals and converts it accordingly.
     */
    function getLatestPrice() public view returns (uint) {
        (, int price, , ,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price from oracle");
        return uint(price) * 1e10;
    }
}
