import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with:", deployer.address);

  const WRAPPED_NATIVE = process.env.WRAPPED_NATIVE_ADDRESS;
  if (!WRAPPED_NATIVE) throw new Error("WRAPPED_NATIVE_ADDRESS not set in .env");

  const FEE_SIGNER = process.env.FEE_SIGNER_ADDRESS || deployer.address;
  const VAULT = process.env.VAULT_ADDRESS || deployer.address;
  const executor = deployer.address;

  // Deploy OneSwapAggregateBridge
  const OneSwapAggregateBridge = await ethers.getContractFactory("OneSwapAggregateBridge");
  const bridge = await OneSwapAggregateBridge.deploy(executor);
  await bridge.waitForDeployment();
  const bridgeAddress = await bridge.getAddress();
  console.log("OneSwapAggregateBridge:", bridgeAddress);

  // Deploy OneSwapRouter (main entry point — inherits V2, V3, Aggregate, Cross)
  const OneSwapRouter = await ethers.getContractFactory("OneSwapRouter");
  const router = await OneSwapRouter.deploy();
  await router.waitForDeployment();
  const routerAddress = await router.getAddress();
  console.log("OneSwapRouter:", routerAddress);

  // Wire bridge → router
  await bridge.changeOneSwapRouter(routerAddress);
  console.log("Bridge wired to router");

  // Wire router → bridge, fee signer, vault
  await router.changeOneSwapProxy(bridgeAddress, FEE_SIGNER, VAULT);
  console.log("Router proxy configured");

  // Whitelist wrapped native token
  await router.changeAllowed([], [WRAPPED_NATIVE]);
  console.log("Wrapped native whitelisted:", WRAPPED_NATIVE);

  console.log("\nDeployment summary:");
  console.log("  OneSwapAggregateBridge:", bridgeAddress);
  console.log("  OneSwapRouter:         ", routerAddress);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
