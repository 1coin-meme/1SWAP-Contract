import { expect } from "chai";
import { ethers, network } from "hardhat";
import { Signer } from "ethers";
import {
  FourMemeRouter__factory,
  MockFourMeme__factory,
  MockERC20__factory,
  MockWBNB__factory,
  MockUniswapV2Router__factory,
  FourMemeRouter,
  MockFourMeme,
  MockERC20,
  MockWBNB,
} from "../typechain-types";

const FOURMEME_BSC   = "0x5c952063c7fc8610FFDB798152D69F0B9550762b";
const PANCAKE_V2     = "0x10ED43C718714eb63d5aA57B78B54704E256024E";
const WBNB_BSC       = "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c";
const USDT_BSC       = "0x55d398326f99059fF775485246999027B3197955";
const FOURMEME_TOKEN = "0xbf119d03e1123f0538354f23a21e31d469454444";

// ─────────────────────────────────────────────
// Unit tests (local network, mock contracts)
// ─────────────────────────────────────────────
describe("FourMemeRouter — unit (mock)", function () {
  let deployer: Signer;
  let user: Signer;
  let other: Signer;

  let mock:   MockFourMeme;
  let fmToken: MockERC20;
  let wbnb:   MockWBNB;
  let router: FourMemeRouter;

  // MockFourMeme always mints exactly TOKEN_OUT tokens
  const TOKEN_OUT  = ethers.parseUnits("100000", 18);
  // BUY_AMOUNT is used as the ETH/WBNB amount in swap flows (must fit MockWBNB's ETH reserve)
  const BUY_AMOUNT = ethers.parseEther("0.001");
  const BNB_RETURN = ethers.parseEther("0.0005");

  before(async function () {
    await network.provider.request({ method: "hardhat_reset", params: [] });
  });

  beforeEach(async function () {
    [deployer, user, other] = await ethers.getSigners();

    const mockV2 = await new MockUniswapV2Router__factory(deployer).deploy();

    mock    = await new MockFourMeme__factory(deployer).deploy();
    fmToken = await new MockERC20__factory(deployer).deploy();
    wbnb    = await new MockWBNB__factory(deployer).deploy();
    router  = await new FourMemeRouter__factory(deployer).deploy(
      await mock.getAddress(),
      await mockV2.getAddress(),
    );

    // Fund mock FourMeme with BNB so it can pay out on sells
    await deployer.sendTransaction({ to: await mock.getAddress(), value: ethers.parseEther("10") });
    // Fund MockWBNB with BNB so withdraw() can pay out after mint()
    await deployer.sendTransaction({ to: await wbnb.getAddress(), value: ethers.parseEther("10") });
  });

  // ── buy ────────────────────────────────────────────────────────────────────

  describe("buy", function () {
    it("reverts with zero BNB", async function () {
      await expect(
        router.connect(user).buy(await fmToken.getAddress(), TOKEN_OUT)
      ).to.be.revertedWith("FourMemeRouter: no BNB");
    });

    it("tokens go directly to caller wallet", async function () {
      await router.connect(user).buy(await fmToken.getAddress(), TOKEN_OUT, { value: BUY_AMOUNT });
      expect(await fmToken.balanceOf(await user.getAddress())).to.equal(TOKEN_OUT);
    });

    it("router holds zero tokens after buy", async function () {
      await router.connect(user).buy(await fmToken.getAddress(), TOKEN_OUT, { value: BUY_AMOUNT });
      expect(await fmToken.balanceOf(await router.getAddress())).to.equal(0n);
    });

    it("reverts when minTokenOut is not met", async function () {
      await expect(
        router.connect(user).buy(await fmToken.getAddress(), TOKEN_OUT + 1n, { value: BUY_AMOUNT })
      ).to.be.reverted;
    });
  });

  // ── sellForToken ───────────────────────────────────────────────────────────

  describe("sellForToken", function () {
    let userAddr:    string;
    let outputToken: MockERC20;
    let path:        string[];

    beforeEach(async function () {
      userAddr    = await user.getAddress();
      outputToken = await new MockERC20__factory(deployer).deploy();
      path        = [await wbnb.getAddress(), await outputToken.getAddress()];

      // Give user FourMeme tokens; user approves FourMeme (not router) directly
      await fmToken.mint(userAddr, TOKEN_OUT);
      await fmToken.connect(user).approve(await mock.getAddress(), TOKEN_OUT);
    });

    it("reverts with zero amount", async function () {
      await expect(
        router.connect(user).sellForToken(await fmToken.getAddress(), 0n, 0n, path, 0n, { value: BNB_RETURN })
      ).to.be.revertedWith("FourMemeRouter: zero amount");
    });

    it("reverts with no BNB float", async function () {
      await expect(
        router.connect(user).sellForToken(await fmToken.getAddress(), TOKEN_OUT, 0n, path, 0n)
      ).to.be.revertedWith("FourMemeRouter: no BNB float");
    });

    it("output token lands in caller wallet", async function () {
      // msg.value = BNB_RETURN → MockV2 mints BNB_RETURN outputToken (1:1) to user
      // MockFourMeme sends BNB_RETURN to tx.origin (user), reimbursing the float
      await router.connect(user).sellForToken(
        await fmToken.getAddress(), TOKEN_OUT, BNB_RETURN, path, 0n, { value: BNB_RETURN }
      );
      expect(await outputToken.balanceOf(userAddr)).to.equal(BNB_RETURN);
    });

    it("user FourMeme tokens are consumed", async function () {
      await router.connect(user).sellForToken(
        await fmToken.getAddress(), TOKEN_OUT, BNB_RETURN, path, 0n, { value: BNB_RETURN }
      );
      expect(await fmToken.balanceOf(userAddr)).to.equal(0n);
    });

    it("caller BNB is net neutral (float reimbursed by FourMeme)", async function () {
      const bnbBefore = await ethers.provider.getBalance(userAddr);
      const tx      = await router.connect(user).sellForToken(
        await fmToken.getAddress(), TOKEN_OUT, BNB_RETURN, path, 0n, { value: BNB_RETURN }
      );
      const receipt = await tx.wait();
      const gasCost = receipt!.gasUsed * receipt!.gasPrice;
      const bnbAfter = await ethers.provider.getBalance(userAddr);
      // Paid msg.value (BNB_RETURN), got BNB_RETURN back from FourMeme → net = -gas only
      expect(bnbAfter).to.equal(bnbBefore - gasCost);
    });

    it("router holds zero WBNB and BNB after sellForToken", async function () {
      const routerAddr = await router.getAddress();
      await router.connect(user).sellForToken(
        await fmToken.getAddress(), TOKEN_OUT, BNB_RETURN, path, 0n, { value: BNB_RETURN }
      );
      expect(await wbnb.balanceOf(routerAddr)).to.equal(0n);
      expect(await ethers.provider.getBalance(routerAddr)).to.equal(0n);
    });

    it("reverts when minBNBFromSell not met by FourMeme", async function () {
      const impossibleMin = ethers.parseEther("999");
      await expect(
        router.connect(user).sellForToken(
          await fmToken.getAddress(), TOKEN_OUT, impossibleMin, path, 0n, { value: BNB_RETURN }
        )
      ).to.be.reverted;
    });

    it("reverts when V2 slippage not met", async function () {
      await expect(
        router.connect(user).sellForToken(
          await fmToken.getAddress(), TOKEN_OUT, BNB_RETURN, path, BNB_RETURN + 1n, { value: BNB_RETURN }
        )
      ).to.be.reverted;
    });
  });

  // ── sell ───────────────────────────────────────────────────────────────────

  describe("sell", function () {
    let userAddr: string;
    let mockAddr: string;

    beforeEach(async function () {
      userAddr = await user.getAddress();
      mockAddr = await mock.getAddress();
      await fmToken.mint(userAddr, TOKEN_OUT);
      await fmToken.connect(user).approve(mockAddr, TOKEN_OUT);
    });

    it("reverts with zero amount", async function () {
      await expect(
        router.connect(user).sell(await fmToken.getAddress(), 0, BNB_RETURN)
      ).to.be.revertedWith("FourMemeRouter: zero amount");
    });

    it("reverts when FourMeme not approved", async function () {
      const otherAddr = await other.getAddress();
      await fmToken.mint(otherAddr, TOKEN_OUT);
      await expect(
        router.connect(other).sell(await fmToken.getAddress(), TOKEN_OUT, BNB_RETURN)
      ).to.be.reverted;
    });

    it("user tokens are consumed", async function () {
      await router.connect(user).sell(await fmToken.getAddress(), TOKEN_OUT, BNB_RETURN);
      expect(await fmToken.balanceOf(userAddr)).to.equal(0n);
    });
  });

  // ── buyWithToken ───────────────────────────────────────────────────────────

  describe("buyWithToken", function () {
    let userAddr:   string;
    let inputToken: MockERC20;
    let path:       string[];

    beforeEach(async function () {
      userAddr   = await user.getAddress();
      inputToken = await new MockERC20__factory(deployer).deploy();
      path       = [await inputToken.getAddress(), await wbnb.getAddress()];

      // Give user some input tokens and approve router.
      // We use TOKEN_OUT as the balance so approve covers any amount we pass.
      await inputToken.mint(userAddr, TOKEN_OUT);
      await inputToken.connect(user).approve(await router.getAddress(), TOKEN_OUT);
    });

    it("reverts with zero amount", async function () {
      await expect(
        router.connect(user).buyWithToken(
          await inputToken.getAddress(), 0n, path, 0n, await fmToken.getAddress(), TOKEN_OUT
        )
      ).to.be.revertedWith("FourMemeRouter: zero amount");
    });

    it("FourMeme tokens go directly to caller wallet", async function () {
      // inputAmount = BUY_AMOUNT so MockV2 mints BUY_AMOUNT WBNB → MockWBNB.withdraw(BUY_AMOUNT)
      // succeeds (reserve is 10 ETH) → FourMeme mints TOKEN_OUT to user.
      await router.connect(user).buyWithToken(
        await inputToken.getAddress(), BUY_AMOUNT, path, 0n, await fmToken.getAddress(), TOKEN_OUT
      );
      expect(await fmToken.balanceOf(userAddr)).to.equal(TOKEN_OUT);
    });

    it("router holds zero tokens, WBNB, and BNB after buyWithToken", async function () {
      const routerAddr = await router.getAddress();
      await router.connect(user).buyWithToken(
        await inputToken.getAddress(), BUY_AMOUNT, path, 0n, await fmToken.getAddress(), TOKEN_OUT
      );
      expect(await fmToken.balanceOf(routerAddr)).to.equal(0n);
      expect(await wbnb.balanceOf(routerAddr)).to.equal(0n);
      expect(await ethers.provider.getBalance(routerAddr)).to.equal(0n);
    });

    it("reverts when V2 slippage not met", async function () {
      // MockV2 outputs BUY_AMOUNT at 1:1; asking for BUY_AMOUNT + 1 should revert.
      await expect(
        router.connect(user).buyWithToken(
          await inputToken.getAddress(), BUY_AMOUNT, path, BUY_AMOUNT + 1n, await fmToken.getAddress(), 0n
        )
      ).to.be.reverted;
    });

    it("reverts when FourMeme slippage not met", async function () {
      // MockFourMeme mints exactly TOKEN_OUT; asking for TOKEN_OUT + 1 should revert.
      await expect(
        router.connect(user).buyWithToken(
          await inputToken.getAddress(), BUY_AMOUNT, path, 0n, await fmToken.getAddress(), TOKEN_OUT + 1n
        )
      ).to.be.reverted;
    });
  });
});

// ─────────────────────────────────────────────
// Fork integration tests (real contracts on BSC)
// ─────────────────────────────────────────────
describe("FourMemeRouter — fork (BSC)", function () {
  this.timeout(120_000);

  const BSC_RPC = process.env.BSC_RPC_URL;

  before(async function () {
    if (!BSC_RPC) {
      console.log("      Skipping: set BSC_RPC_URL in .env to run fork tests");
      this.skip();
    }

    const res = await fetch(BSC_RPC, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", method: "eth_blockNumber", params: [], id: 1 }),
    });
    const { result } = await res.json() as { result: string };
    const forkBlock = parseInt(result, 16) - 2;
    console.log(`      Forking BSC at block ${forkBlock}`);

    await network.provider.request({
      method: "hardhat_reset",
      params: [{ forking: { jsonRpcUrl: BSC_RPC, blockNumber: forkBlock } }],
    });
  });

  after(async function () {
    if (!BSC_RPC) return;
    await network.provider.request({ method: "hardhat_reset", params: [] });
  });

  async function deployRouter(signer: Signer): Promise<FourMemeRouter> {
    return new FourMemeRouter__factory(signer).deploy(FOURMEME_BSC, PANCAKE_V2);
  }

  async function fundDeployer(signer: Signer) {
    await network.provider.send("hardhat_setBalance", [
      await signer.getAddress(), "0x8AC7230489E80000", // 10 BNB
    ]);
  }

  // Swap BNB → USDT via PancakeSwap so the deployer has USDT to spend.
  // Returns the USDT balance of addr after the swap.
  async function acquireUsdt(signer: Signer, bnbIn: bigint): Promise<bigint> {
    const addr    = await signer.getAddress();
    const pancake = new ethers.Contract(PANCAKE_V2, [
      "function swapExactETHForTokens(uint,address[],address,uint) payable returns (uint[])",
    ], signer);
    await (await pancake.swapExactETHForTokens(
      1n, [WBNB_BSC, USDT_BSC], addr, Math.floor(Date.now() / 1000) + 600,
      { value: bnbIn }
    )).wait();
    const usdt = new ethers.Contract(USDT_BSC, ["function balanceOf(address) view returns (uint256)"], signer);
    return usdt.balanceOf(addr);
  }

  // ── buy ────────────────────────────────────────────────────────────────────

  it("buy: tokens land directly in caller wallet", async function () {
    const [deployer] = await ethers.getSigners();
    await fundDeployer(deployer);

    const router    = await deployRouter(deployer);
    const userAddr  = await deployer.getAddress();
    const fmToken   = new ethers.Contract(FOURMEME_TOKEN, ["function balanceOf(address) view returns (uint256)"], deployer);

    const before   = await fmToken.balanceOf(userAddr);
    await (await router.buy(FOURMEME_TOKEN, 1n, { value: ethers.parseEther("0.001") })).wait();
    const received = (await fmToken.balanceOf(userAddr)) - before;

    expect(received).to.be.gt(0n);
    console.log(`      buy → ${ethers.formatUnits(received, 18)} tokens in wallet`);
  });

  // ── sell ───────────────────────────────────────────────────────────────────

  it("sell: user approves FourMeme, FourMeme sends BNB directly to tx.origin", async function () {
    const [deployer] = await ethers.getSigners();
    await fundDeployer(deployer);

    const router   = await deployRouter(deployer);
    const userAddr = await deployer.getAddress();
    const fmToken  = new ethers.Contract(FOURMEME_TOKEN, [
      "function balanceOf(address) view returns (uint256)",
      "function approve(address,uint256) returns (bool)",
    ], deployer);

    await (await router.buy(FOURMEME_TOKEN, 1n, { value: ethers.parseEther("0.001") })).wait();
    const tokenBal = await fmToken.balanceOf(userAddr);
    await fmToken.approve(FOURMEME_BSC, tokenBal);

    const bnbBefore   = await ethers.provider.getBalance(userAddr);
    const tx          = await router.sell(FOURMEME_TOKEN, tokenBal, 1n);
    const receipt     = await tx.wait();
    const gasCost     = receipt!.gasUsed * receipt!.gasPrice;
    const bnbReceived = (await ethers.provider.getBalance(userAddr)) - bnbBefore + gasCost;

    expect(bnbReceived).to.be.gt(0n);
    console.log(`      sell ${ethers.formatUnits(tokenBal, 18)} tokens → ${ethers.formatEther(bnbReceived)} BNB`);
  });

  // ── sellForToken ───────────────────────────────────────────────────────────

  it("sellForToken: FourMeme token → USDT (float BNB reimbursed by FourMeme)", async function () {
    const [deployer] = await ethers.getSigners();
    await fundDeployer(deployer);

    const router   = await deployRouter(deployer);
    const userAddr = await deployer.getAddress();

    const fmToken = new ethers.Contract(FOURMEME_TOKEN, [
      "function balanceOf(address) view returns (uint256)",
      "function approve(address,uint256) returns (bool)",
    ], deployer);
    const usdt = new ethers.Contract(USDT_BSC, ["function balanceOf(address) view returns (uint256)"], deployer);

    // Buy FourMeme tokens first
    await (await router.buy(FOURMEME_TOKEN, 1n, { value: ethers.parseEther("0.001") })).wait();
    const tokenBal = await fmToken.balanceOf(userAddr);
    expect(tokenBal).to.be.gt(0n);

    // Approve FourMeme to spend tokens (same as direct sell)
    await fmToken.approve(FOURMEME_BSC, tokenBal);

    const usdtBefore = await usdt.balanceOf(userAddr);
    const bnbBefore  = await ethers.provider.getBalance(userAddr);

    // Float 0.001 BNB for the WBNB→USDT swap leg. minBNBFromSell = 1n (accept any BNB
    // back from FourMeme) so the test is not sensitive to bonding-curve state drift across
    // earlier fork tests. In production, set minBNBFromSell >= floatBNB to break even.
    const floatBNB = ethers.parseEther("0.001");
    const tx = await router.sellForToken(
      FOURMEME_TOKEN, tokenBal, 1n, [WBNB_BSC, USDT_BSC], 1n, { value: floatBNB }
    );
    const receipt = await tx.wait();
    const gasCost = receipt!.gasUsed * receipt!.gasPrice;

    const usdtAfter = await usdt.balanceOf(userAddr);
    const bnbAfter  = await ethers.provider.getBalance(userAddr);

    const usdtReceived = usdtAfter - usdtBefore;
    // BNB paid: floatBNB + gas; BNB received: floatBNB from FourMeme → net = -gas
    const bnbNet = bnbAfter - bnbBefore + gasCost; // should be ~0 or positive if FourMeme > float

    expect(usdtReceived).to.be.gt(0n);
    console.log(`      sellForToken ${ethers.formatUnits(tokenBal, 18)} tokens → ${ethers.formatUnits(usdtReceived, 18)} USDT`);
    console.log(`      BNB net (excl gas): ${ethers.formatEther(bnbNet)} BNB`);
  });

  // ── buyWithToken ───────────────────────────────────────────────────────────

  it("buyWithToken: USDT → BNB (PancakeV2) → FourMeme token in wallet", async function () {
    const [deployer] = await ethers.getSigners();
    await fundDeployer(deployer);

    const router   = await deployRouter(deployer);
    const userAddr = await deployer.getAddress();

    // Get USDT by swapping 1 BNB → USDT via PancakeSwap
    const usdtAmount = await acquireUsdt(deployer, ethers.parseEther("1"));
    expect(usdtAmount).to.be.gt(0n);

    const usdt   = new ethers.Contract(USDT_BSC, [
      "function balanceOf(address) view returns (uint256)",
      "function approve(address,uint256) returns (bool)",
    ], deployer);
    const fmToken = new ethers.Contract(FOURMEME_TOKEN, ["function balanceOf(address) view returns (uint256)"], deployer);

    await usdt.approve(await router.getAddress(), usdtAmount);

    const before   = await fmToken.balanceOf(userAddr);
    await (await router.buyWithToken(
      USDT_BSC, usdtAmount, [USDT_BSC, WBNB_BSC], 1n, FOURMEME_TOKEN, 1n
    )).wait();
    const received = (await fmToken.balanceOf(userAddr)) - before;

    expect(received).to.be.gt(0n);
    console.log(`      buyWithToken 5 USDT → ${ethers.formatUnits(received, 18)} tokens in wallet`);
  });
});
