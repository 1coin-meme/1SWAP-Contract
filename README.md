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

## License

MIT
