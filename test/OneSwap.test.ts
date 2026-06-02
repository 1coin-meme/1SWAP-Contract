import { expect } from "chai";
import { ethers } from "hardhat";
import { Signer } from "ethers";
import { OneSwapAllowed, OneSwapFees, OneSwap, OneSwapCross, OneSwapRouter } from "../typechain-types";

describe("OneSwap", function () {
  let owner: Signer;
  let executor: Signer;
  let user: Signer;

  let allowed: OneSwapAllowed;
  let fees: OneSwapFees;
  let swap: OneSwap;
  let cross: OneSwapCross;
  let router: OneSwapRouter;

  const ZERO_ADDRESS = ethers.ZeroAddress;
  // Placeholder WETH address for local tests
  const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";

  beforeEach(async function () {
    [owner, executor, user] = await ethers.getSigners();
    const executorAddr = await executor.getAddress();

    allowed = await (await ethers.getContractFactory("OneSwapAllowed")).deploy(executorAddr) as OneSwapAllowed;
    fees = await (await ethers.getContractFactory("OneSwapFees")).deploy(executorAddr) as OneSwapFees;
    swap = await (await ethers.getContractFactory("OneSwap")).deploy(executorAddr) as OneSwap;
    cross = await (await ethers.getContractFactory("OneSwapCross")).deploy(WETH, executorAddr) as OneSwapCross;
    router = await (await ethers.getContractFactory("OneSwapRouter")).deploy(
      await swap.getAddress(),
      await cross.getAddress(),
      await fees.getAddress(),
      executorAddr
    ) as OneSwapRouter;

    const routerAddr = await router.getAddress();
    const allowedAddr = await allowed.getAddress();

    await swap.connect(executor).changeOneSwapRouter(routerAddr);
    await swap.connect(executor).changeOneSwapAllowed(allowedAddr);
    await cross.connect(executor).changeOneSwapRouter(routerAddr);
    await cross.connect(executor).changeOneSwapAllowed(allowedAddr);
  });

  describe("Deployment", function () {
    it("sets executor correctly", async function () {
      expect(await swap.executor()).to.equal(await executor.getAddress());
      expect(await router.executor()).to.equal(await executor.getAddress());
    });

    it("wires router into OneSwap", async function () {
      expect(await swap.oneSwapRouter()).to.equal(await router.getAddress());
    });

    it("wires allowed into OneSwap", async function () {
      expect(await swap.oneSwapAllowed()).to.equal(await allowed.getAddress());
    });

    it("wires router into OneSwapCross", async function () {
      expect(await cross.oneSwapRouter()).to.equal(await router.getAddress());
    });

    it("router points to correct sub-contracts", async function () {
      expect(await router.oneSwap()).to.equal(await swap.getAddress());
      expect(await router.oneSwapCross()).to.equal(await cross.getAddress());
      expect(await router.oneSwapFees()).to.equal(await fees.getAddress());
    });

    it("wrappedNative set correctly in OneSwapCross", async function () {
      expect(await cross.wrappedNative()).to.equal(WETH);
    });
  });

  describe("Access control", function () {
    it("only executor can change router address", async function () {
      await expect(
        swap.connect(user).changeOneSwapRouter(ZERO_ADDRESS)
      ).to.be.revertedWith("Ownable: caller is not the executor");
    });

    it("only executor can pause router", async function () {
      await expect(
        router.connect(user).changePause(true)
      ).to.be.revertedWith("Ownable: caller is not the executor");
    });

    it("executor can pause and unpause router", async function () {
      await router.connect(executor).changePause(true);
      expect(await router.paused()).to.equal(true);
      await router.connect(executor).changePause(false);
      expect(await router.paused()).to.equal(false);
    });

    it("only executor can setup fees", async function () {
      await expect(
        fees.connect(user).setupFees([0], [30], ["default"])
      ).to.be.revertedWith("Ownable: caller is not the executor");
    });
  });

  describe("OneSwapAllowed", function () {
    it("allows all callers when requireAllowed is false", async function () {
      expect(await allowed.requireAllowed()).to.equal(false);
      expect(await allowed.checkAllowed(0, await user.getAddress(), "0x00000000")).to.equal(true);
    });

    it("blocks unlisted callers when requireAllowed is true", async function () {
      await allowed.connect(executor).changeRequireAllowed();
      expect(await allowed.checkAllowed(0, await user.getAddress(), "0x00000000")).to.equal(false);
    });
  });

  describe("OneSwapFees", function () {
    it("supports discount by default", async function () {
      expect(await fees.supportDiscount()).to.equal(true);
    });

    it("fee rate is zero before setup", async function () {
      expect(await fees.fees(0, "default")).to.equal(0);
    });

    it("executor can setup fees", async function () {
      await fees.connect(executor).setupFees([0], [30], ["default"]);
      expect(await fees.fees(0, "default")).to.equal(30);
    });
  });

  describe("Ownership transfer", function () {
    it("two-step ownership transfer works", async function () {
      const newOwner = await user.getAddress();
      await router.connect(owner).transferOwnership(newOwner);
      expect(await router.pendingOwner()).to.equal(newOwner);
      await router.connect(user).acceptOwnership();
      expect(await router.owner()).to.equal(newOwner);
    });
  });
});
