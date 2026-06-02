import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with:", deployer.address);

  const WRAPPED_NATIVE = process.env.WRAPPED_NATIVE_ADDRESS;
  if (!WRAPPED_NATIVE) throw new Error("WRAPPED_NATIVE_ADDRESS not set in .env");

  const executor = deployer.address;

  // Deploy OneSwapAllowed
  const OneSwapAllowed = await ethers.getContractFactory("OneSwapAllowed");
  const allowed = await OneSwapAllowed.deploy(executor);
  await allowed.waitForDeployment();
  console.log("OneSwapAllowed:", await allowed.getAddress());

  // Deploy OneSwapFees
  const OneSwapFees = await ethers.getContractFactory("OneSwapFees");
  const fees = await OneSwapFees.deploy(executor);
  await fees.waitForDeployment();
  console.log("OneSwapFees:", await fees.getAddress());

  // Deploy OneSwap (core swap executor)
  const OneSwap = await ethers.getContractFactory("OneSwap");
  const swap = await OneSwap.deploy(executor);
  await swap.waitForDeployment();
  const swapAddress = await swap.getAddress();
  console.log("OneSwap:", swapAddress);

  // Deploy OneSwapCross
  const OneSwapCross = await ethers.getContractFactory("OneSwapCross");
  const cross = await OneSwapCross.deploy(WRAPPED_NATIVE, executor);
  await cross.waitForDeployment();
  const crossAddress = await cross.getAddress();
  console.log("OneSwapCross:", crossAddress);

  // Deploy OneSwapRouter (main entry point)
  const OneSwapRouter = await ethers.getContractFactory("OneSwapRouter");
  const router = await OneSwapRouter.deploy(
    swapAddress,
    crossAddress,
    await fees.getAddress(),
    executor
  );
  await router.waitForDeployment();
  const routerAddress = await router.getAddress();
  console.log("OneSwapRouter:", routerAddress);

  // Wire up: point OneSwap and OneSwapCross at the router
  await swap.changeOneSwapRouter(routerAddress);
  await swap.changeOneSwapAllowed(await allowed.getAddress());
  await cross.changeOneSwapRouter(routerAddress);
  await cross.changeOneSwapAllowed(await allowed.getAddress());
  console.log("Wiring complete");

  // Whitelist wrapped native token in router
  await router.changeWrappedAllowed([WRAPPED_NATIVE]);
  console.log("Wrapped native whitelisted:", WRAPPED_NATIVE);

  console.log("\nDeployment summary:");
  console.log("  OneSwapAllowed:  ", await allowed.getAddress());
  console.log("  OneSwapFees:     ", await fees.getAddress());
  console.log("  OneSwap:         ", swapAddress);
  console.log("  OneSwapCross:    ", crossAddress);
  console.log("  OneSwapRouter:   ", routerAddress);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
