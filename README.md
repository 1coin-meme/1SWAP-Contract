# 1SWAP Contract

Core smart contracts of 1Swap — a modular DEX aggregator with cross-chain support, based on the transit-core-v5 architecture.

## Architecture

```
OneSwapRouter (main entry point)
├── UniswapV2Router    — V2 AMM swaps (with fee-on-transfer support)
├── UniswapV3Router    — V3 concentrated liquidity swaps (multi-hop)
├── AggregateRouter    — external aggregator routing via bridge
└── CrossRouter        — cross-chain token transfers

OneSwapAggregateBridge (standalone)
└── callbytes()        — executes aggregated swap calldata on behalf of the router
```

`OneSwapRouter` inherits all four routers. All shared state and admin logic lives in `BaseCore`.

## Contracts

| Contract | Description |
|---|---|
| `OneSwapRouter` | Main entry point. Inherits V2, V3, aggregate, and cross routing. Manages fee rates, allowlists, and per-function pausing |
| `BaseCore` | Shared base: all structs, EIP-712 fee verification, admin functions (`changeFee`, `changeAllowed`, `changePause`, etc.) |
| `UniswapV2Router` | Executes exact-input V2 swaps. Supports standard and fee-on-transfer tokens |
| `UniswapV3Router` | Executes exact-input V3 swaps (single and multi-hop). Handles `uniswapV3SwapCallback` and `pancakeV3SwapCallback` |
| `AggregateRouter` | Routes aggregate swaps through the bridge contract via a low-level `callbytes()` call |
| `CrossRouter` | Handles cross-chain transfers by forwarding encoded calldata to a whitelisted cross caller |
| `OneSwapAggregateBridge` | Standalone bridge that receives funds from the router and executes aggregated swap steps against external DEXes |

## Libraries (`contracts/libs/`)

| Library | Description |
|---|---|
| `Ownable` | Single-role executor access control with two-step transfer (`transferExecutorship` / `acceptExecutorship`) |
| `Pausable` | Per-function emergency stop using `FunctionFlag` enum (`executeAggregate`, `executeV2Swap`, `executeV3Swap`, `cross`) |
| `ReentrancyGuard` | Reentrancy protection on all external entry points |
| `TransferHelper` | Safe ERC-20 and ETH helpers, WETH deposit/withdraw |
| `SafeMath` | Overflow-safe arithmetic with `int256`/`uint256` casting |
| `RevertReasonParser` | Decodes revert reasons from low-level calls |

## Fee Model

Fees are verified via **EIP-712 signatures** (domain: `"1SwapV5"`, version: `"5"`):

- **Aggregate fee** — applied to V2, V3, and aggregate swaps
- **Cross fee** — applied to cross-chain transfers
- Rates are in basis points (e.g. `30` = 0.3%, max `1000` = 10%)
- A `vaultFlag` in the fee value controls optional vault splitting: `fee % 10 == 1` routes `fee / 10` to the vault address

## Setup

```bash
npm install
```

Copy `.env.example` to `.env` and fill in:

```
PRIVATE_KEY=
WRAPPED_NATIVE_ADDRESS=   # e.g. WETH on the target network
FEE_SIGNER_ADDRESS=       # address whose private key signs fee proofs
VAULT_ADDRESS=            # address that receives vault fee splits
TESTNET_RPC_URL=
MAINNET_RPC_URL=
ETHERSCAN_API_KEY=
```

## Usage

```bash
# Compile
npm run compile

# Test
npm run test

# Deploy (local node)
npm run node          # in one terminal
npm run deploy:local  # in another

# Deploy to testnet
npm run deploy:testnet
```

## Deployment Order

The deploy script handles this automatically:

1. `OneSwapAggregateBridge` — deploy with executor address
2. `OneSwapRouter` — deploy (deployer becomes executor automatically)
3. Wire bridge → router via `bridge.changeOneSwapRouter(routerAddress)`
4. Wire router → bridge, fee signer, vault via `router.changeOneSwapProxy(...)`
5. Whitelist the wrapped native token via `router.changeAllowed([], [WRAPPED_NATIVE])`

## FourMeme Integration

`FourMemeRouter` is a standalone router for buying and selling tokens on the [FourMeme](https://four.meme) bonding-curve launchpad on BSC (`0x5c952063c7fc8610FFDB798152D69F0B9550762b`).

### Why a dedicated router?

FourMeme bonding-curve tokens block peer-to-peer `transfer` calls — only the FourMeme contract itself can move them. A naive proxy-based approach (proxy buys, then forwards tokens to the user) fails at the forwarding step. The router works around this by using FourMeme's own function signatures that handle delivery directly.

### Buy

```
User ──[BNB]──► FourMemeRouter.buy(token, minTokenOut)
                      │
                      └─ FourMeme.buyTokenAMAP(token, to=msg.sender, funds, minAmount)
                                    │
                                    ├─ tokens ──► user wallet  (FourMeme transfers, no restriction)
                                    └─ BNB refund ──► router ──► user wallet
```

- Selector: `buyTokenAMAP` (`0x7f79f6df`)
- FourMeme delivers tokens to the `to` address it receives — bypassing the peer-to-peer restriction entirely
- Any unused BNB (partial fill on the bonding curve) is refunded to the caller

### Sell

```
Step 1 — User approves FourMeme to spend their tokens:
  token.approve(FOURMEME_ADDRESS, amount)   ← NOT the router

Step 2 — User calls router:
  FourMemeRouter.sell(token, amount, minBNBOut)
        │
        └─ FourMeme.sellToken(origin=0, token, from=tx.origin, amount, minFunds, feeRate=0, feeRecipient=0x0)
                        │
                        ├─ pulls tokens from tx.origin (user)
                        └─ BNB ──► router ──► user wallet
```

- Selector: `sellToken` (`0xe63aaf36`)
- FourMeme validates `from == tx.origin`. Because the user is the transaction originator regardless of `msg.sender`, the router can call FourMeme on the user's behalf
- The user approves **FourMeme** (`0x5c952063c7fc8610FFDB798152D69F0B9550762b`), not the router — FourMeme is the one that does `transferFrom`. This approval only needs to be done once per token (or set to `type(uint256).max` for a blanket approval)
- FourMeme sends BNB **directly to `tx.origin`** (the caller EOA) — the router is never the BNB intermediary

### buyWithToken

Swap any ERC-20 → FourMeme token in one transaction. The router handles the intermediate BNB conversion via PancakeSwap.

```
User approves: Router to spend inputToken

FourMemeRouter.buyWithToken(inputToken, inputAmount, path, minBNBFromSwap, fourMemeToken, minTokenOut)
      │
      ├─ PancakeSwap: inputToken ──► WBNB  (minBNBFromSwap guards this step)
      ├─ WBNB.withdraw() → native BNB
      └─ FourMeme.buyTokenAMAP(fourMemeToken, to=msg.sender, ...)
                        │
                        └─ tokens ──► user wallet
```

- `path` must end with WBNB
- Two slippage params: `minBNBFromSwap` (V2 step) and `minTokenOut` (FourMeme step)
- Caller approves **this router** for `inputToken`

### sellForToken

Sell FourMeme tokens and receive any ERC-20 output — atomic, one transaction — using a BNB float pattern.

FourMeme always sends BNB proceeds to `tx.origin` (the caller), not to `msg.sender` (the router). To make an atomic sell-and-swap possible, the caller provides the expected BNB as `msg.value`. The router uses that BNB for the swap immediately, then calls FourMeme sell which reimburses the float directly to the caller.

```
User approves: FourMeme to spend their FourMeme token

FourMemeRouter.sellForToken(fourMemeToken, amount, minBNBFromSell, path, minTokenOut)
  called with msg.value = expected BNB from the sell
      │
      ├─ wrap msg.value → WBNB
      ├─ PancakeSwap: WBNB ──► outputToken ──► user wallet  (upfront, using the float)
      └─ FourMeme.sellToken(from=tx.origin, ...)
                        │
                        ├─ pulls tokens from tx.origin (user)
                        └─ BNB ──► tx.origin (user)  ← reimburses the float
```

- `path` must start with WBNB
- `msg.value` = BNB the caller expects to receive from the FourMeme sell
- Setting `minBNBFromSell >= msg.value` guarantees the caller does not lose BNB (tx reverts if FourMeme returns less than the float)
- The bonding-curve buy/sell spread means the reimbursed BNB may be slightly less than `msg.value`; callers can accept this or tighten `minBNBFromSell` to enforce break-even
- Caller approves **FourMeme** for the FourMeme token (same as `sell`)

### Simulation results (BSC mainnet fork)

| Function | Input | Output |
|---|---|---|
| `buy` | 0.001 BNB | 169,632 tokens in caller wallet |
| `sell` | 169,632 tokens | 0.00196 BNB to caller |
| `buyWithToken` | 5 USDT | 145,842,986 tokens in caller wallet |
| `sellForToken` | 169,632 tokens + 0.001 BNB float | 0.683 USDT in caller wallet |

## License

MIT
