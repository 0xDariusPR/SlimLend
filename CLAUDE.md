# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SlimLend is a DeFi lending protocol implemented as a Solidity smart contract. The protocol allows liquidity providers to deposit assets and earn interest, while borrowers can deposit collateral and borrow assets. The system uses dynamic interest rates based on utilization and implements share-based accounting for both lenders and borrowers.

## Development Commands

### Build
```bash
forge build
```

### Test
```bash
forge test                    # Run all tests
forge test --match-test <regex>  # Run specific test pattern
forge test -vv               # Verbose output with logs
forge test -vvv              # Execution traces for failing tests
forge test -vvvv             # Execution traces for all tests
```

### Format
```bash
forge fmt
```

### Gas Analysis
```bash
forge snapshot               # Generate gas snapshots
forge test --gas-report      # Print gas usage report
```

### Local Development
```bash
anvil                        # Start local Ethereum node
```

### Deploy
```bash
forge script script/SlimLend.s.sol --rpc-url <rpc_url> --private-key <private_key>
```

## Architecture

### Core Contract: SlimLend.sol

The main contract (`src/SlimLend.sol`) implements a lending protocol with the following key components:

#### State Variables
- `totalDepositedTokens`: Total assets deposited by liquidity providers
- `totalBorrowedTokens`: Total assets borrowed by users  
- `lpSharePrice`: Price per LP share (starts at 1e18, increases with interest)
- `borrowerSharePrice`: Price per borrower share (starts at 1e18, increases with interest)
- `collateralToken`: ERC20 token used as collateral

#### Key Constants
- `LTV = 1.5e18`: Loan-to-value ratio (150%)
- `OPTIMAL_UTILIZATION = 0.95e18`: Target utilization rate (95%)
- `KINK_INTEREST_PER_SECOND`: Interest rate at optimal utilization
- `MAX_INTEREST_PER_SECOND`: Maximum interest rate at 100% utilization

#### Interest Rate Model
The protocol uses a kinked interest rate model:
- Linear growth from 0% to optimal utilization
- Steeper linear growth from optimal to 100% utilization
- Rates calculated per second and applied to share prices

#### Share-Based Accounting
- LP shares represent proportional ownership of the lending pool
- Borrower shares track debt that grows with interest over time
- Share prices update automatically when users interact with the protocol

### Test Structure

Tests are organized by functionality:
- `SlimLend.utilization.t.sol`: Tests utilization calculations
- `SlimLend.interestRates.t.sol`: Tests interest rate calculations
- `SlimLend.updateSharePrice.t.sol`: Tests share price updates
- `SlimLend.lpDepositAsset.t.sol`: Tests LP deposit functionality

### Dependencies

- **OpenZeppelin Contracts**: Standard ERC20 implementation and utilities
- **Forge Standard Library**: Testing framework and utilities
- Uses Foundry's remapping system for clean imports

## Development Notes

- The contract inherits from OpenZeppelin's ERC20 for LP token functionality
- Uses 18-decimal precision for all calculations
- Interest rates are calculated per second for continuous compounding
- Share price updates occur on every user interaction to ensure accurate accounting
- Several functions like `borrowerRepayAsset` and `liquidate` are placeholders awaiting implementation