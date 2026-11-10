// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {MockWETH} from "./MockWETH.sol";

interface IAegisToken {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
    function burn(address from, uint256 amount) external returns (bool);
    function set_minter(address minter, bool status) external;
    function owner() external view returns (address);
}

interface IPriceFeedOracle {
    function owner() external view returns (address);
    function set_asset_price(address asset, uint256 price, uint256 max_age) external;
    function update_price(address asset, uint256 price) external;
    function get_price(address asset) external view returns (uint256);
}

interface ITroveManager {
    struct Trove {
        uint256 collateral;
        uint256 debt;
        bool is_active;
    }

    function owner() external view returns (address);
    function collateral_token() external view returns (address);
    function aegis_token() external view returns (address);
    function price_oracle() external view returns (address);
    function stability_pool() external view returns (address);
    function redemption_engine() external view returns (address);
    function treasury() external view returns (address);

    function borrowing_fee_bps() external view returns (uint256);
    function total_collateral() external view returns (uint256);
    function total_debt() external view returns (uint256);
    function trove_count() external view returns (uint256);
    function troves(address borrower) external view returns (uint256, uint256, bool);

    function get_collateral_price() external view returns (uint256);
    function get_icr(address borrower) external view returns (uint256);
    function get_tcr() external view returns (uint256);
    function is_solvent(address borrower) external view returns (bool);

    function set_stability_pool(address stability_pool) external;
    function set_redemption_engine(address redemption_engine) external;
    function set_borrowing_fee_bps(uint256 fee_bps) external;
    function open_trove(uint256 collateral_amount, uint256 debt_amount) external;
    function add_collateral(uint256 amount) external;
    function withdraw_collateral(uint256 amount) external;
    function mint_more_debt(uint256 amount) external;
    function repay_debt(uint256 amount) external;
    function close_trove() external;
    function liquidate(address borrower) external;
}

interface IStabilityPool {
    struct Snapshots {
        uint256 S;
        uint256 P;
    }

    function owner() external view returns (address);
    function trove_manager() external view returns (address);
    function aegis_token() external view returns (address);
    function collateral_token() external view returns (address);
    function total_aegis_deposits() external view returns (uint256);
    function total_collateral_held() external view returns (uint256);
    function P() external view returns (uint256);
    function S() external view returns (uint256);
    function deposits(address depositor) external view returns (uint256);

    function get_compounded_aegis_deposit(address depositor) external view returns (uint256);
    function get_depositor_collateral_gain(address depositor) external view returns (uint256);
    function provide_to_sp(uint256 amount) external;
    function withdraw_from_sp(uint256 amount) external;
    function claim_rewards() external;
    function offset_debt(uint256 debt_to_offset, uint256 collateral_to_reward) external returns (bool);
}

interface IRedemptionEngine {
    function owner() external view returns (address);
    function trove_manager() external view returns (address);
    function base_rate() external view returns (uint256);
    function get_decayed_base_rate() external view returns (uint256);
    function redeem_collateral_single(address target_trove, uint256 aegis_amount, uint256 max_fee_bps)
        external
        returns (uint256, uint256);
}

contract AegisMintTest is Test {
    MockWETH public weth;
    IAegisToken public aegis;
    IPriceFeedOracle public oracle;
    ITroveManager public troveManager;
    IStabilityPool public stabilityPool;
    IRedemptionEngine public redemptionEngine;

    address public admin = address(this);
    address public treasury = address(0xEEEE);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public liquidator = address(0xDEAD);
    address public redeemer = address(0xCAFE);

    uint256 public constant WETH_PRICE = 2000 * 1e18; // $2,000 USD
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10000;
    uint256 public constant BORROWING_FEE_BPS = 50; // 0.5%

    function setUp() public {
        // 1. Deploy Collateral Token (MockWETH)
        weth = new MockWETH();

        // 2. Deploy AegisToken (Vyper)
        address aegisAddr = deployCode("src/AegisToken.vy");
        aegis = IAegisToken(aegisAddr);

        // 3. Deploy PriceFeedOracle (Vyper)
        address oracleAddr = deployCode("src/PriceFeedOracle.vy");
        oracle = IPriceFeedOracle(oracleAddr);
        oracle.set_asset_price(address(weth), WETH_PRICE, 86400);

        // 4. Deploy TroveManager (Vyper)
        bytes memory troveArgs = abi.encode(address(weth), aegisAddr, oracleAddr, treasury, BORROWING_FEE_BPS);
        address troveAddr = deployCode("src/TroveManager.vy", troveArgs);
        troveManager = ITroveManager(troveAddr);

        // 5. Deploy StabilityPool (Vyper)
        bytes memory spArgs = abi.encode(aegisAddr, address(weth), troveAddr);
        address spAddr = deployCode("src/StabilityPool.vy", spArgs);
        stabilityPool = IStabilityPool(spAddr);

        // 6. Deploy RedemptionEngine (Vyper)
        bytes memory redemptionArgs = abi.encode(troveAddr);
        address redemptionAddr = deployCode("src/RedemptionEngine.vy", redemptionArgs);
        redemptionEngine = IRedemptionEngine(redemptionAddr);

        // 7. Wire authorizations
        aegis.set_minter(troveAddr, true);
        aegis.set_minter(spAddr, true);
        aegis.set_minter(redemptionAddr, true);
        troveManager.set_stability_pool(spAddr);
        troveManager.set_redemption_engine(redemptionAddr);

        // 8. Fund test actors with WETH
        weth.mint(alice, 100 ether);
        weth.mint(bob, 100 ether);
        weth.mint(liquidator, 100 ether);
        weth.mint(redeemer, 100 ether);

        // Approvals
        vm.prank(alice);
        weth.approve(troveAddr, type(uint256).max);
        vm.prank(bob);
        weth.approve(troveAddr, type(uint256).max);
        vm.prank(liquidator);
        weth.approve(troveAddr, type(uint256).max);
        vm.prank(redeemer);
        weth.approve(troveAddr, type(uint256).max);

        vm.prank(alice);
        aegis.approve(troveAddr, type(uint256).max);
        vm.prank(bob);
        aegis.approve(troveAddr, type(uint256).max);
        vm.prank(liquidator);
        aegis.approve(troveAddr, type(uint256).max);
        vm.prank(redeemer);
        aegis.approve(troveAddr, type(uint256).max);
    }

    // --- Unit Tests: Initial Configuration ---

    function test_initial_configuration() public view {
        assertEq(aegis.name(), "Aegis Dollar");
        assertEq(aegis.symbol(), "AEGIS");
        assertEq(aegis.decimals(), 18);
        assertEq(aegis.totalSupply(), 0);

        assertEq(oracle.get_price(address(weth)), WETH_PRICE);
        assertEq(troveManager.collateral_token(), address(weth));
        assertEq(troveManager.aegis_token(), address(aegis));
        assertEq(troveManager.price_oracle(), address(oracle));
        assertEq(troveManager.treasury(), treasury);
        assertEq(troveManager.borrowing_fee_bps(), BORROWING_FEE_BPS);
        assertEq(troveManager.stability_pool(), address(stabilityPool));
        assertEq(troveManager.redemption_engine(), address(redemptionEngine));

        assertEq(stabilityPool.total_aegis_deposits(), 0);
        assertEq(stabilityPool.total_collateral_held(), 0);
        assertEq(stabilityPool.P(), 1e18);
        assertEq(stabilityPool.S(), 0);

        assertEq(redemptionEngine.trove_manager(), address(troveManager));
        assertEq(redemptionEngine.base_rate(), 50); // 0.5%
    }

    // --- Unit Tests: Open Trove and Borrow ---

    function test_open_trove_success() public {
        uint256 colAmount = 10 ether; // $20,000 USD
        uint256 debtAmount = 10000 ether; // 10,000 AEGIS

        vm.prank(alice);
        troveManager.open_trove(colAmount, debtAmount);

        // Fee is 0.5% = 50 AEGIS
        uint256 expectedFee = (debtAmount * BORROWING_FEE_BPS) / BPS;
        uint256 expectedTotalDebt = debtAmount + expectedFee;

        (uint256 col, uint256 debt, bool active) = troveManager.troves(alice);
        assertTrue(active);
        assertEq(col, colAmount);
        assertEq(debt, expectedTotalDebt);

        assertEq(aegis.balanceOf(alice), debtAmount);
        assertEq(aegis.balanceOf(treasury), expectedFee);
        assertEq(weth.balanceOf(address(troveManager)), colAmount);

        // ICR = (10 * 2000 * 10000) / 10050 = 19900 (199%)
        uint256 icr = troveManager.get_icr(alice);
        assertGt(icr, 11000); // Greater than MCR (110%)
        assertTrue(troveManager.is_solvent(alice));
        assertEq(troveManager.trove_count(), 1);
    }

    function test_cannot_open_trove_below_mcr() public {
        uint256 colAmount = 1 ether; // $2,000 USD
        // Max borrow at 110% MCR is ~$1,818. Borrowing 1,900 will fail MCR check
        uint256 excessiveDebt = 1900 ether;

        vm.prank(alice);
        vm.expectRevert();
        troveManager.open_trove(colAmount, excessiveDebt);
    }

    function test_cannot_open_trove_below_min_net_debt() public {
        uint256 colAmount = 10 ether;
        uint256 tinyDebt = 50 ether; // Minimum is 100 AEGIS

        vm.prank(alice);
        vm.expectRevert();
        troveManager.open_trove(colAmount, tinyDebt);
    }

    // --- Unit Tests: Collateral & Debt Adjustments ---

    function test_add_and_withdraw_collateral() public {
        vm.prank(alice);
        troveManager.open_trove(10 ether, 5000 ether);

        // Add 5 WETH
        vm.prank(alice);
        troveManager.add_collateral(5 ether);
        (uint256 col,,) = troveManager.troves(alice);
        assertEq(col, 15 ether);

        // Withdraw 3 WETH
        vm.prank(alice);
        troveManager.withdraw_collateral(3 ether);
        (col,,) = troveManager.troves(alice);
        assertEq(col, 12 ether);
        assertTrue(troveManager.is_solvent(alice));
    }

    function test_withdraw_collateral_reverts_if_breaching_mcr() public {
        // Open trove close to MCR
        // 10 WETH = $20,000, 16,000 debt -> ICR = 124%
        vm.prank(alice);
        troveManager.open_trove(10 ether, 16000 ether);

        // Attempt to withdraw 5 WETH (leaving 5 WETH = $10,000 for $16,000 debt -> ICR = 62%)
        vm.prank(alice);
        vm.expectRevert();
        troveManager.withdraw_collateral(5 ether);
    }

    function test_mint_more_debt_and_repay() public {
        vm.prank(alice);
        troveManager.open_trove(10 ether, 2000 ether);

        // Mint 1,000 more AEGIS
        vm.prank(alice);
        troveManager.mint_more_debt(1000 ether);
        assertEq(aegis.balanceOf(alice), 3000 ether);

        // Repay 1,500 AEGIS
        vm.prank(alice);
        troveManager.repay_debt(1500 ether);
        assertEq(aegis.balanceOf(alice), 1500 ether);

        (uint256 col, uint256 debt,) = troveManager.troves(alice);
        assertEq(col, 10 ether);
        assertLt(debt, 3020 ether);
    }

    function test_close_trove() public {
        vm.prank(alice);
        troveManager.open_trove(10 ether, 2000 ether);

        (, uint256 debt,) = troveManager.troves(alice);

        // Mint extra AEGIS to cover the 0.5% fee
        uint256 fee = debt - 2000 ether;
        vm.prank(bob);
        weth.approve(address(troveManager), type(uint256).max);
        vm.prank(bob);
        troveManager.open_trove(10 ether, 1000 ether);
        vm.prank(bob);
        aegis.transfer(alice, fee);

        uint256 aliceWethBefore = weth.balanceOf(alice);

        vm.prank(alice);
        troveManager.close_trove();

        (uint256 finalCol, uint256 finalDebt, bool active) = troveManager.troves(alice);
        assertFalse(active);
        assertEq(finalCol, 0);
        assertEq(finalDebt, 0);
        assertEq(weth.balanceOf(alice), aliceWethBefore + 10 ether);
    }

    // --- Unit Tests: Stability Pool & Liquidation ---

    function test_stability_pool_absorption_and_collateral_gain() public {
        // 1. Alice opens a safe trove
        vm.prank(alice);
        troveManager.open_trove(20 ether, 10000 ether);

        // 2. Bob opens a trove close to liquidation boundary
        // 5 WETH ($10,000) with 8,500 debt (ICR = 117%)
        vm.prank(bob);
        troveManager.open_trove(5 ether, 8500 ether);

        // 3. Alice deposits 10,000 AEGIS into Stability Pool
        vm.prank(alice);
        aegis.approve(address(stabilityPool), type(uint256).max);
        vm.prank(alice);
        stabilityPool.provide_to_sp(10000 ether);

        assertEq(stabilityPool.total_aegis_deposits(), 10000 ether);

        // 4. Price drops from $2,000 to $1,800
        // Bob's 5 WETH is now worth $9,000 against ~8,542 debt -> ICR = 105% (< 110% MCR)
        oracle.update_price(address(weth), 1800 * 1e18);
        assertFalse(troveManager.is_solvent(bob));

        // 5. Liquidate Bob's trove -> routed to Stability Pool
        troveManager.liquidate(bob);

        // Bob's trove is closed
        (,, bool bobActive) = troveManager.troves(bob);
        assertFalse(bobActive);

        // Stability pool absorbed Bob's debt and received his 5 WETH
        assertEq(stabilityPool.total_collateral_held(), 5 ether);
        assertLt(stabilityPool.total_aegis_deposits(), 10000 ether);

        // 6. Alice claims her collateral gain (she owns 100% of SP)
        uint256 aliceWethBefore = weth.balanceOf(alice);
        vm.prank(alice);
        stabilityPool.claim_rewards();

        assertEq(weth.balanceOf(alice), aliceWethBefore + 5 ether);
    }

    function test_direct_liquidator_liquidation_without_sp() public {
        // Bob opens a trove: 5 WETH ($10,000) with 8,000 debt
        vm.prank(bob);
        troveManager.open_trove(5 ether, 8000 ether);

        // Liquidator gets 9,000 AEGIS by opening their own safe trove
        vm.prank(liquidator);
        troveManager.open_trove(20 ether, 9000 ether);

        // Price drops to $1,700 -> Bob's ICR = (5 * 1700) / 8040 = 105% (< 110%)
        oracle.update_price(address(weth), 1700 * 1e18);
        assertFalse(troveManager.is_solvent(bob));

        // No AEGIS in Stability Pool
        assertEq(stabilityPool.total_aegis_deposits(), 0);

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);

        // Liquidator liquidates Bob directly
        vm.prank(liquidator);
        troveManager.liquidate(bob);

        (,, bool bobActive) = troveManager.troves(bob);
        assertFalse(bobActive);

        // Liquidator received seized collateral (including 5% liquidation bonus)
        uint256 seizedCollateral = weth.balanceOf(liquidator) - liquidatorWethBefore;
        assertGt(seizedCollateral, 4.5 ether);
    }

    // --- Unit Tests: Direct 1:1 Redemption Engine ---

    function test_direct_redemption_defends_peg() public {
        // 1. Bob opens a trove with 10 WETH ($20,000) and borrows 5,000 AEGIS
        vm.prank(bob);
        troveManager.open_trove(10 ether, 5000 ether);

        // 2. Redeemer acquires 2,000 AEGIS by opening a safe trove
        vm.prank(redeemer);
        troveManager.open_trove(20 ether, 2000 ether);

        uint256 redeemerWethBefore = weth.balanceOf(redeemer);
        uint256 treasuryWethBefore = weth.balanceOf(treasury);

        // 3. Redeemer redeems 2,000 AEGIS against Bob's trove
        // Value: 2,000 AEGIS at $2,000/WETH = 1.0 WETH gross
        // Fee: 0.5% (50 BPS) = 0.005 WETH
        // Net: 0.995 WETH
        vm.prank(redeemer);
        (uint256 netCol, uint256 feeCol) =
            redemptionEngine.redeem_collateral_single(
                bob,
                2000 ether,
                100 // max fee 1%
            );

        assertEq(netCol, 0.995 ether);
        assertEq(feeCol, 0.005 ether);
        assertEq(weth.balanceOf(redeemer), redeemerWethBefore + 0.995 ether);
        assertEq(weth.balanceOf(treasury), treasuryWethBefore + 0.005 ether);

        // 4. Bob's trove debt decreased by 2,000 AEGIS
        (uint256 bobCol, uint256 bobDebt,) = troveManager.troves(bob);
        assertEq(bobDebt, (5000 ether + (5000 ether * BORROWING_FEE_BPS) / BPS) - 2000 ether);
        assertEq(bobCol, 9 ether); // 10 ether - 1.0 ether gross

        // 5. Base rate surged after redemption to 500 bps (max fee ceiling)
        assertEq(redemptionEngine.base_rate(), 500);

        // 6. Time warp decays base rate: 24h = 2 half-lives -> 500 / 4 = 125 bps
        uint256 currentT = block.timestamp;
        vm.warp(currentT + 86400);
        assertEq(redemptionEngine.get_decayed_base_rate(), 125);

        // 7. Time warp 48h later -> 4 half-lives -> 500 / 16 = 31 bps clamped to MIN_REDEMPTION_FEE_BPS (50)
        vm.warp(currentT + 172800);
        assertEq(redemptionEngine.get_decayed_base_rate(), 50);
    }

    // --- Unit Tests: Access Control & Edge Cases ---

    function test_unauthorized_minter_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        aegis.mint(alice, 1000 ether);
    }

    function test_unauthorized_fee_update_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        troveManager.set_borrowing_fee_bps(100);
    }

    function test_price_staleness_reverts() public {
        // Warp block timestamp past oracle max_age (86,400s)
        vm.warp(block.timestamp + 100000);
        vm.expectRevert();
        oracle.get_price(address(weth));
    }

    // --- Fuzz Tests: Invariants & Solvency ---

    function testFuzz_open_trove_solvency_invariant(uint256 colEth, uint256 debt) public {
        // Bound collateral between 1 WETH and 1,000 WETH
        colEth = bound(colEth, 1 ether, 1000 ether);

        // Calculate max allowed debt at MCR (110%)
        // maxDebt = (colEth * 2000 * 10000) / (11000 * 1.005)
        uint256 maxDebt = (colEth * 2000 * 10000) / 11055;
        if (maxDebt < 100 ether) return;

        debt = bound(debt, 100 ether, maxDebt);

        weth.mint(alice, colEth);
        vm.prank(alice);
        troveManager.open_trove(colEth, debt);

        assertTrue(troveManager.is_solvent(alice));
        assertGe(troveManager.get_icr(alice), 11000);
    }

    function testFuzz_stability_pool_deposit_compounding(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 100 ether, 100000 ether);

        // Alice mints AEGIS
        weth.mint(alice, 200 ether);
        vm.prank(alice);
        troveManager.open_trove(200 ether, depositAmount);

        vm.prank(alice);
        aegis.approve(address(stabilityPool), depositAmount);
        vm.prank(alice);
        stabilityPool.provide_to_sp(depositAmount);

        assertEq(stabilityPool.total_aegis_deposits(), depositAmount);
        assertEq(stabilityPool.get_compounded_aegis_deposit(alice), depositAmount);
        assertEq(stabilityPool.get_depositor_collateral_gain(alice), 0);
    }
}
