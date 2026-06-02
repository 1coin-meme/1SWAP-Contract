import { expect } from "chai";
import { ethers } from "hardhat";
import { Signer } from "ethers";
import { OneSwapRouter__factory, OneSwapAggregateBridge__factory, OneSwapRouter, OneSwapAggregateBridge } from "../typechain-types";

describe("OneSwap", function () {
  // deployer is automatically the router executor (BaseCore sets msg.sender)
  let deployer: Signer;
  let bridgeExecutor: Signer;
  let user: Signer;

  let router: OneSwapRouter;
  let bridge: OneSwapAggregateBridge;

  const ZERO_ADDRESS = ethers.ZeroAddress;
  const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";

  beforeEach(async function () {
    [deployer, bridgeExecutor, user] = await ethers.getSigners();
    const bridgeExecutorAddr = await bridgeExecutor.getAddress();

    bridge = await new OneSwapAggregateBridge__factory(deployer).deploy(bridgeExecutorAddr);
    router = await new OneSwapRouter__factory(deployer).deploy();

    const routerAddr = await router.getAddress();
    const bridgeAddr = await bridge.getAddress();
    const deployerAddr = await deployer.getAddress();

    await bridge.connect(bridgeExecutor).changeOneSwapRouter(routerAddr);
    // deployer is router executor; set bridge, fee signer = deployer, vault = deployer for test
    await router.connect(deployer).changeOneSwapProxy(bridgeAddr, deployerAddr, deployerAddr);
  });

  describe("Deployment", function () {
    it("sets deployer as router executor", async function () {
      expect(await router.executor()).to.equal(await deployer.getAddress());
    });

    it("sets bridgeExecutor as bridge executor", async function () {
      expect(await bridge.executor()).to.equal(await bridgeExecutor.getAddress());
    });

    it("bridge points to router", async function () {
      expect(await bridge.oneSwapRouter()).to.equal(await router.getAddress());
    });

    it("router proxy returns bridge address", async function () {
      const [bridgeProxy] = await router.oneSwapProxyAddress();
      expect(bridgeProxy).to.equal(await bridge.getAddress());
    });

    it("router has EIP-712 DOMAIN_SEPARATOR set", async function () {
      const sep = await router.DOMAIN_SEPARATOR();
      expect(sep).to.not.equal(ethers.ZeroHash);
    });
  });

  describe("Access control", function () {
    it("only executor can call changeAllowed", async function () {
      await expect(
        router.connect(user).changeAllowed([], [WETH])
      ).to.be.revertedWith("Ownable: caller is not the executor");
    });

    it("only executor can call changePause", async function () {
      await expect(
        router.connect(user).changePause(true, [0])
      ).to.be.revertedWith("Ownable: caller is not the executor");
    });

    it("only executor can call changeOneSwapProxy", async function () {
      await expect(
        router.connect(user).changeOneSwapProxy(ZERO_ADDRESS, ZERO_ADDRESS, ZERO_ADDRESS)
      ).to.be.revertedWith("Ownable: caller is not the executor");
    });

    it("only executor can call changeFee", async function () {
      await expect(
        router.connect(user).changeFee([true], [50])
      ).to.be.revertedWith("Ownable: caller is not the executor");
    });
  });

  describe("Per-function pausing", function () {
    it("executor can pause and unpause aggregate", async function () {
      // FunctionFlag.executeAggregate = 0
      await router.connect(deployer).changePause(true, [0]);
      const [agg] = await router.pausedOverAll();
      expect(agg).to.equal(true);

      await router.connect(deployer).changePause(false, [0]);
      const [aggAfter] = await router.pausedOverAll();
      expect(aggAfter).to.equal(false);
    });

    it("pausing one function does not pause others", async function () {
      await router.connect(deployer).changePause(true, [0]); // pause aggregate only
      const [agg, v2, v3, cross] = await router.pausedOverAll();
      expect(agg).to.equal(true);
      expect(v2).to.equal(false);
      expect(v3).to.equal(false);
      expect(cross).to.equal(false);
    });
  });

  describe("Wrapped token allowlist", function () {
    it("wrappedToken is not allowed before whitelisting", async function () {
      const { isWrappedAllowed } = await router.oneSwapAllowedQuery(ZERO_ADDRESS, WETH, 0);
      expect(isWrappedAllowed).to.equal(false);
    });

    it("executor can whitelist a wrapped token", async function () {
      await router.connect(deployer).changeAllowed([], [WETH]);
      const { isWrappedAllowed } = await router.oneSwapAllowedQuery(ZERO_ADDRESS, WETH, 0);
      expect(isWrappedAllowed).to.equal(true);
    });

    it("calling changeAllowed again toggles it off", async function () {
      await router.connect(deployer).changeAllowed([], [WETH]);
      await router.connect(deployer).changeAllowed([], [WETH]);
      const { isWrappedAllowed } = await router.oneSwapAllowedQuery(ZERO_ADDRESS, WETH, 0);
      expect(isWrappedAllowed).to.equal(false);
    });
  });

  describe("Cross caller allowlist", function () {
    it("cross caller is not allowed by default", async function () {
      const { isCrossCallerAllowed } = await router.oneSwapAllowedQuery(await user.getAddress(), ZERO_ADDRESS, 0);
      expect(isCrossCallerAllowed).to.equal(false);
    });

    it("executor can toggle cross caller", async function () {
      const userAddr = await user.getAddress();
      await router.connect(deployer).changeAllowed([userAddr], []);
      const { isCrossCallerAllowed } = await router.oneSwapAllowedQuery(userAddr, ZERO_ADDRESS, 0);
      expect(isCrossCallerAllowed).to.equal(true);
    });
  });

  describe("Fee configuration", function () {
    it("fee rates start at zero", async function () {
      const [aggregateFee, crossFee] = await router.oneSwapFee();
      expect(aggregateFee).to.equal(0);
      expect(crossFee).to.equal(0);
    });

    it("executor can set aggregate fee rate", async function () {
      await router.connect(deployer).changeFee([true], [30]);
      const [aggregateFee] = await router.oneSwapFee();
      expect(aggregateFee).to.equal(30);
    });

    it("executor can set cross fee rate", async function () {
      await router.connect(deployer).changeFee([false], [20]);
      const [, crossFee] = await router.oneSwapFee();
      expect(crossFee).to.equal(20);
    });

    it("rejects fee rate above 1000", async function () {
      await expect(
        router.connect(deployer).changeFee([true], [1001])
      ).to.be.revertedWith("fee rate is:0-1000");
    });
  });

  describe("Executorship transfer", function () {
    it("two-step executorship transfer works", async function () {
      const newExec = await user.getAddress();
      await router.connect(deployer).transferExecutorship(newExec);
      expect(await router.pendingExecutor()).to.equal(newExec);
      await router.connect(user).acceptExecutorship();
      expect(await router.executor()).to.equal(newExec);
    });
  });

  describe("OneSwapAggregateBridge", function () {
    it("allowedEnabled starts false", async function () {
      expect(await bridge.allowedEnabled()).to.equal(false);
    });

    it("executor can toggle allowedEnabled", async function () {
      await bridge.connect(bridgeExecutor).changeAllowedEnabled();
      expect(await bridge.allowedEnabled()).to.equal(true);
    });

    it("only router can call callbytes", async function () {
      await expect(
        bridge.connect(user).callbytes({ srcToken: ZERO_ADDRESS, calldatas: "0x" })
      ).to.be.revertedWith("OneSwapAggregateBridge: invalid router");
    });
  });
});
