// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "../src/USDHVault.sol"; // adjust the path if needed
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Dummy WETH token for testing purposes.
contract DummyWETH is ERC20 {
    constructor() ERC20("Wrapped ETH", "WETH") {
        _mint(msg.sender, 1000 * 1e18);
    }
}

contract USDHVaultTest is Test {
    USDHVault public usdhVault;
    DummyWETH public weth;
    address public user = address(1);

    // Use a dummy Chainlink price feed for testing (you can extend this mock as needed)
    AggregatorV3Interface public priceFeed;

    function setUp() public {
        // Deploy a dummy WETH token
        weth = new DummyWETH();
        
        // For testing, you can either deploy a mock price feed or use an existing one
        // Here we'll assume a simple mock that returns a fixed price.
        // You might create a MockPriceFeed contract that returns a fixed price (e.g., 2000 USD per ETH)
        // For simplicity, let’s assume priceFeed is set up appropriately.
        priceFeed = AggregatorV3Interface(address(0)); // Replace with a proper mock if needed

        // Deploy the USDHVault contract with parameters.
        // For example, mintingCollateralRatio = 150, liquidationCollateralRatio = 125, liquidationPenalty = 10.
        usdhVault = new USDHVault(address(weth), address(priceFeed), 150, 125, 10);

        // Give the test user some WETH.
        weth.transfer(user, 100 * 1e18);
    }

    function testDepositAndMint() public {
        // Prank as user.
        vm.startPrank(user);

        // Approve the vault contract to spend WETH.
        weth.approve(address(usdhVault), 50 * 1e18);

        // Deposit WETH
        usdhVault.deposit(50 * 1e18);

        // Attempt to mint USDH. You can calculate expected max mintable amount based on a fixed price.
        // Example: if 1 WETH = 2000 USD, then 50 WETH = 100,000 USD.
        // With a minting ratio of 150%, max mintable = (100,000 / 150) * 100 = ~66,666 USDH (in theory).
        // For testing, mint a smaller amount.
        usdhVault.mintStablecoin(10 * 1e18);

        // Assert that minted amount is recorded.
        assertEq(usdhVault.minted(user), 10 * 1e18);

        vm.stopPrank();
    }
}
