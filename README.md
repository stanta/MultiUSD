# MultiUSD (USDM)

Synthetic on-chain USD-pegged stablecoin, free of any blocks.

Author: @stanta  
License: GPL-3.0

Built with [Foundry](https://github.com/foundry-rs/foundry).

## Overview
 
USDM is a standard ERC20 token with on-chain mint and burn functionality,pegged to uniswap-like DEX pools to keep native coin (ETH, BNB, POL, etc...) to USDT+USDC+... exchange ratio

It leverages OpenZeppelin’s battle-tested implementations:

- ERC20
- ERC20Burnable

Key features:

- mint any amount to any address
- burn your own tokens


## Installation

```bash
git clone https://github.com/stanta/MultiUSD.git
cd MultiUSD
forge install
forge build
```

## Usage

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Format

```bash
forge fmt
```

### Gas Snapshots

```bash
forge snapshot
```

### Local Node

```bash
anvil
```

### Deploy

```bash
forge script script/USDM.s.sol:USDMScript \
  --rpc-url <YOUR_RPC_URL> \
  --private-key <YOUR_PRIVATE_KEY>
```

### Cast

```bash
cast <subcommand>
```

### Help

```bash
forge --help
anvil --help
cast --help
```
