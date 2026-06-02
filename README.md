# 1SWAP Contract

Core smart contracts of 1Swap — a modular DEX aggregator with cross-chain support.

## Architecture

```
OneSwapRouter (entry point)
├── OneSwap          — aggregate & direct swap execution
├── OneSwapCross     — cross-chain token transfers
├── OneSwapFees      — fee calculation with gradient discounts
└── OneSwapAllowed   — caller/function allowlist
```

### Contracts

| Contract | Description |
|---|---|
| `OneSwapRouter` | Main entry point. Routes `swap()` and `cross()` calls, manages pre/post-trade fee modes, whitelists wrapped native tokens |
| `OneSwap` | Executes aggregate (multi-step) and direct AMM swaps. Called only by the router |
| `OneSwapCross` | Handles cross-chain transfers, native wrapping/unwrapping. Called only by the router |
| `OneSwapFees` | Returns fee amounts per swap type and channel. Supports gradient discounts based on token holdings |
| `OneSwapAllowed` | Two-tier allowlist: per-flag caller whitelist and optional per-function whitelist |

### Libraries

| Library | Description |
|---|---|
| `OneSwapStructs` | Shared structs and enums (`SwapTypes`, `Flag`, `OneSwapDescription`, etc.) |
| `Ownable` | Two-role access control: `owner` (governance) and `executor` (operations), both with two-step transfer |
| `Pausable` | Emergency stop for the router |
| `ReentrancyGuard` | Reentrancy protection on all external entry points |
| `TransferHelper` | Safe ERC-20 and ETH transfer helpers, WETH deposit/withdraw |
| `SafeMath` | Overflow-safe arithmetic |
| `RevertReasonParser` | Decodes revert reasons from low-level calls |

## Fee Modes

- **Pre-trade (default):** fee deducted from `srcToken` before the swap executes
- **Post-trade:** fee deducted from `dstToken` after the swap executes; toggled per swap type via `changeSwapTypeMode()`

Fee rate `1` is treated as zero fee. Rates are in basis points (e.g. `30` = 0.3%).

## Setup

```bash
npm install
```

Copy `.env.example` to `.env` and fill in:

```
PRIVATE_KEY=
WRAPPED_NATIVE_ADDRESS=   # e.g. WETH on the target network
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

1. `OneSwapAllowed`
2. `OneSwapFees`
3. `OneSwap`
4. `OneSwapCross` (requires wrapped native address)
5. `OneSwapRouter` (requires addresses of the above)
6. Wire router address into `OneSwap` and `OneSwapCross`
7. Whitelist the wrapped native token in the router

## License

MIT
