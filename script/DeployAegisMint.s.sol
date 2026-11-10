// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MockWETH} from "../test/MockWETH.sol";

interface IAegisToken {
    function set_minter(address minter, bool status) external;
}

interface IPriceFeedOracle {
    function set_asset_price(address asset, uint256 price, uint256 max_age) external;
}

interface ITroveManager {
    function set_stability_pool(address stability_pool) external;
    function set_redemption_engine(address redemption_engine) external;
}

contract DeployAegisMint is Script {
    function run() external {
        vm.startBroadcast();

        // 1. Deploy Collateral Token (MockWETH)
        MockWETH weth = new MockWETH();
        console.log("MockWETH deployed at:", address(weth));

        // 2. Deploy AegisToken (Vyper)
        address aegisAddr = deployCode("src/AegisToken.vy");
        console.log("AegisToken deployed at:", aegisAddr);

        // 3. Deploy PriceFeedOracle (Vyper)
        address oracleAddr = deployCode("src/PriceFeedOracle.vy");
        console.log("PriceFeedOracle deployed at:", oracleAddr);
        IPriceFeedOracle(oracleAddr).set_asset_price(address(weth), 2000 * 1e18, 86400);

        // 4. Deploy TroveManager (Vyper)
        address treasury = address(0xEEEE);
        uint256 borrowingFeeBps = 50; // 0.5%
        bytes memory troveArgs = abi.encode(address(weth), aegisAddr, oracleAddr, treasury, borrowingFeeBps);
        address troveAddr = deployCode("src/TroveManager.vy", troveArgs);
        console.log("TroveManager deployed at:", troveAddr);

        // 5. Deploy StabilityPool (Vyper)
        bytes memory spArgs = abi.encode(aegisAddr, address(weth), troveAddr);
        address spAddr = deployCode("src/StabilityPool.vy", spArgs);
        console.log("StabilityPool deployed at:", spAddr);

        // 6. Deploy RedemptionEngine (Vyper)
        bytes memory redemptionArgs = abi.encode(troveAddr);
        address redemptionAddr = deployCode("src/RedemptionEngine.vy", redemptionArgs);
        console.log("RedemptionEngine deployed at:", redemptionAddr);

        // 7. Wire authorizations
        IAegisToken(aegisAddr).set_minter(troveAddr, true);
        IAegisToken(aegisAddr).set_minter(spAddr, true);
        IAegisToken(aegisAddr).set_minter(redemptionAddr, true);
        ITroveManager(troveAddr).set_stability_pool(spAddr);
        ITroveManager(troveAddr).set_redemption_engine(redemptionAddr);

        console.log("All authorizations and cross-contract wirings established successfully.");
        vm.stopBroadcast();
    }
}
