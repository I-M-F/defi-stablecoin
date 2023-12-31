// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.20;

// // Have our invariant/ properties
// // What are our invariants

// // 1. The total supply of DSC should be less than the total value of collateral
// // 2. Getter view functions should never revert <- evergreen invarinat

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
// import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";


// contract OpenInvariantsTest is StdInvariant, Test {
//     // constructor() { }

//     DeployDSC deployer;
//     DSCEngine engine;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, engine, config) = deployer.run();
//         (,, weth, wbtc,) = config.activeNetworkConfig();
//         targetContract(address(engine));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         // get the value of all the collateral in the protocol
//         // compare it to all the dept (dsc)
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

//         uint256 wethValue = engine.getUSDValue(weth, totalWethDeposited);
//         uint256 wbtcValue = engine.getUSDValue(wbtc, totalWbtcDeposited);

//         console.log("wethValue: " , wethValue);
//         console.log("wbtcValue: " , wbtcValue);
//         console.log("totalSupply: " , totalSupply);

//         assert(wethValue + wbtcValue >= totalSupply);

//     }
// }
