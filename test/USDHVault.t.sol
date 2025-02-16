// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "../src/USDHVault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// Dummy WETH token for testing purposes.
contract DummyWETH is ERC20 {
    constructor() ERC20("Wrapped ETH", "WETH") {
        _mint(msg.sender, 1000 * 1e18);
    }
}

// Extended mock that lets us update the price to simulate market movements.
contract MockV3Aggregator is AggregatorV3Interface {
    uint8 public override decimals;
    string public override description;
    uint256 public override version;
    int256 public answer;

    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimals = _decimals;
        answer = _initialAnswer;
        description = "MockV3Aggregator";
        version = 1;
    }

    function updateAnswer(int256 _newAnswer) external {
        answer = _newAnswer;
    }

    function getRoundData(uint80) external view override returns (
        uint80 roundId,
        int256 _answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (0, answer, 0, 0, 0);
    }

    function latestRoundData() external view override returns (
        uint80 roundId,
        int256 _answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (0, answer, 0, 0, 0);
    }
}

contract USDHVaultTest is Test {
    USDHVault public usdhVault;
    DummyWETH public weth;
    MockV3Aggregator public mockPriceFeed;
    address public user = address(1);
    address public liquidator = address(2);
    address public protocol = address(3);

    function setUp() public {
        // Deploy dummy WETH.
        weth = new DummyWETH();
        // Deploy the mock price feed with 8 decimals and an initial price of $2000/ETH.
        mockPriceFeed = new MockV3Aggregator(8, 2000 * 1e8);
        // Deploy USDHVault with parameters:
        // maxLTV = 66, liquidationThreshold = 80, liquidationPenaltyBP = 500.
        usdhVault = new USDHVault(address(weth), address(mockPriceFeed), 66, 80, 500, protocol);
        // Fund test user with 100 WETH.
        weth.transfer(user, 100 * 1e18);
    }

    function testDeposit() public {
        vm.startPrank(user);
        weth.approve(address(usdhVault), 50 * 1e18);
        usdhVault.deposit(50 * 1e18);
        // Check that collateral is recorded correctly.
        assertEq(usdhVault.collateral(user), 50 * 1e18);
        // The vault's WETH balance should equal the deposit.
        assertEq(weth.balanceOf(address(usdhVault)), 50 * 1e18);
        vm.stopPrank();
    }

    function testWithdraw() public {
        vm.startPrank(user);
        uint initialWethBalance = weth.balanceOf(user);
        uint depositAmount = 50 * 1e18;
        weth.approve(address(usdhVault), depositAmount);
        usdhVault.deposit(depositAmount);
        // Mint some USDH to create debt.
        usdhVault.mintStablecoin(10 * 1e18);
        uint initialCollateral = usdhVault.collateral(user);
        uint withdrawAmount = 10 * 1e18;
        // Withdraw should work if it keeps minted debt within maxLTV.
        usdhVault.withdraw(withdrawAmount);
        assertEq(usdhVault.collateral(user), initialCollateral - withdrawAmount);
        // User's WETH balance should reflect the withdrawn amount.
        assertEq(weth.balanceOf(user), initialWethBalance - depositAmount + withdrawAmount);
        vm.stopPrank();
    }

    function testMintStablecoin() public {
        vm.startPrank(user);
        weth.approve(address(usdhVault), 50 * 1e18);
        usdhVault.deposit(50 * 1e18);
        usdhVault.mintStablecoin(10 * 1e18);
        // Check that minted debt is recorded.
        assertEq(usdhVault.minted(user), 10 * 1e18);
        vm.stopPrank();
    }

    function testBurnStablecoin() public {
        vm.startPrank(user);
        weth.approve(address(usdhVault), 50 * 1e18);
        usdhVault.deposit(50 * 1e18);
        usdhVault.mintStablecoin(10 * 1e18);
        uint mintedBefore = usdhVault.minted(user);
        usdhVault.burnStablecoin(4 * 1e18);
        // Minted debt should reduce by the burned amount.
        assertEq(usdhVault.minted(user), mintedBefore - 4 * 1e18);
        vm.stopPrank();
    }

    function testLiquidateFull() public {
        // Setup vault: user deposits 1 WETH.
        vm.startPrank(user);
        weth.approve(address(usdhVault), 1 * 1e18);
        usdhVault.deposit(1 * 1e18);
        // At an initial price of $2000/ETH, collateral value = $2000.
        // With maxLTV = 66%, user can mint up to 1320 USDH.
        usdhVault.mintStablecoin(1320 * 1e18);
        vm.stopPrank();

        // Simulate a price drop: update price to $1500/ETH.
        mockPriceFeed.updateAnswer(1500 * 1e8);
        // Now collateral value = 1 WETH * $1500 = $1500.
        // Liquidation threshold is 80%: safe if minted <= 1500*80/100 = 1200.
        // Minted debt is 1320, so the vault is undercollateralized.
        assertTrue(usdhVault.isUndercollateralized(user));

        // Liquidator must hold the full debt (1320 USDH) to perform full liquidation.
        vm.startPrank(user);
        uint fullDebt = usdhVault.minted(user);
        usdhVault.transfer(liquidator, fullDebt);
        vm.stopPrank();

        // Capture initial WETH balances for liquidator and protocol (owner).
        uint ownerInitialWETH = weth.balanceOf(protocol);

        // Liquidator calls liquidateFull.
        vm.startPrank(liquidator);
        usdhVault.liquidateFull(user);
        vm.stopPrank();

        // After liquidation, minted debt for user should be zero.
        assertEq(usdhVault.minted(user), 0);

        // For expected value calculations:
        // New price = $1500, so getLatestPrice() returns 1500 * 1e18.
        // debtETH = (1320e18) / (1500e18) = 0.88 ETH.
        // extraIdeal = debtETH * liquidationPenaltyBP/10000 = 0.88 * 500/10000 = 0.044 ETH.
        // extraAvailable = collateral - debtETH = 1e18 - 0.88e18 = 0.12 ETH.
        // actualExtra = min(extraIdeal, extraAvailable) = min(0.044, 0.12) = 0.044 ETH.
        // Liquidator bonus = min(actualExtra, extraIdeal/2) = min(0.044, 0.022) = 0.022 ETH.
        // Protocol fee = actualExtra - liquidatorBonus = 0.044 - 0.022 = 0.022 ETH.
        // Liquidator payout = debtETH + bonus = 0.88 + 0.022 = 0.902 ETH.
        // Total seized = debtETH + actualExtra = 0.88 + 0.044 = 0.924 ETH.
        // Remaining collateral for user = 1 - 0.924 = 0.076 ETH.
        //
        // Check final balances:
        uint expectedLiquidatorPayout = 0.902e18;
        uint liquidatorFinalWETH = weth.balanceOf(liquidator);
        uint expectedOwnerFee = 0.022e18;
        uint ownerFinalWETH = weth.balanceOf(protocol);

        // Verify user's remaining collateral.
        assertEq(usdhVault.collateral(user), 0.076e18);
        // Verify liquidator's gain (using an approximation tolerance).
        assertEq(liquidatorFinalWETH, expectedLiquidatorPayout);
        // Verify owner's fee received.
        assertEq(ownerFinalWETH - ownerInitialWETH, expectedOwnerFee);
    }
}
