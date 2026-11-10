# AegisMint

[![CI](https://github.com/ZengLLQ/aegis-mint/actions/workflows/ci.yml/badge.svg)](https://github.com/ZengLLQ/aegis-mint/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Vyper: 0.4.3](https://img.shields.io/badge/Vyper-0.4.3-363636.svg)](https://github.com/vyperlang/vyper)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FF4B4B.svg)](https://getfoundry.sh/)

**AegisMint** is a production-grade, decentralized Collateralized Debt Position (CDP) engine and synthetic dollar protocol implemented in **Vyper 0.4.3** with formal verification harnesses via **Foundry**. It enables users to deposit digital assets (such as WETH) to mint an algorithmic synthetic stablecoin (**AEGIS**) at low minimum collateralization ratios (110% MCR), safeguarded by an $O(1)$ scalable Stability Pool liquidation backstop, dynamic borrowing fees, and a direct 1:1 collateral redemption arbitrage mechanism to defend the $1.00 USD peg floor.

---

## Architecture Overview

```mermaid
flowchart TD
    User([Borrower / Depositor]) -->|Deposit Collateral / Mint AEGIS| TM[TroveManager]
    TM -->|Mint / Burn AEGIS| Token[AegisToken]
    TM -->|Fetch Asset Price| Oracle[PriceFeedOracle]
    
    SP_User([Stability Depositor]) -->|Provide AEGIS Liquidity| SP[StabilityPool]
    SP -->|Absorb Bad Debt & Seize Collateral| TM
    SP -->|Claim Pro-Rata Collateral Gains| SP_User
    
    Arbitrageur([Arbitrageur / Redeemer]) -->|Redeem AEGIS for 1:1 Collateral| RE[RedemptionEngine]
    RE -->|Execute Redemption| TM
    TM -->|Seize Collateral from Lowest ICR Trove| Arbitrageur
    
    TM -->|Borrowing & Redemption Fees| Treasury([Protocol Treasury])
```

---

## Core Mathematical Formulations

### 1. Individual & Total Collateral Ratios (ICR & TCR)

For each borrower position (Trove) holding collateral $C_i$ with spot oracle price $P$ and debt $D_i$:

$$\text{ICR}_i = \frac{C_i \cdot P}{D_i} \times 10^4 \quad (\text{basis points})$$

The system enforces strict solvency constraints:
- **Minimum Collateral Ratio ($\text{MCR}$)**: $11000\text{ bps} \ (110\%)$. If $\text{ICR}_i < \text{MCR}$, the Trove is immediately liquidatable.
- **Critical Collateral Ratio ($\text{CCR}$)**: $15000\text{ bps} \ (150\%)$.
- **Total Collateral Ratio ($\text{TCR}$)**:

$$\text{TCR} = \frac{\sum_i C_i \cdot P}{\sum_i D_i}$$

### 2. $O(1)$ Scalable Stability Pool Compounding ($P$ and $S$)

Rather than iterating over depositors during liquidations, the Stability Pool maintains running product $P$ and sum $S$ accumulators:

When an insolvent debt $D_{\text{offset}}$ is absorbed in exchange for seized collateral $C_{\text{reward}}$ against total pool deposit $D_{\text{total}}$:

$$\Delta S = \frac{C_{\text{reward}} \cdot 10^{18}}{D_{\text{total}}}$$

$$S_{t+1} = S_t + \frac{\Delta S \cdot P_t}{10^{18}}$$

$$P_{t+1} = \frac{P_t \cdot (D_{\text{total}} - D_{\text{offset}})}{D_{\text{total}}}$$

For any depositor $j$ with initial deposit $d_0$ and entry snapshots $(P_0, S_0)$:
- **Compounded Deposit**:

$$d_j(t) = \frac{d_0 \cdot P_t}{P_0}$$

- **Accrued Collateral Reward**:

$$C_j(t) = \frac{d_0 \cdot (S_t - S_0)}{P_0}$$

### 3. Dynamic Base Rate & Exponential Fee Decay

To protect against sandwich attacks and run-on-the-bank cascades during heavy redemption periods, the Redemption Engine dynamically increases base fees $\beta(t)$ with a 12-hour half-life ($\tau = 43200\text{s}$):

$$\beta(t) = \max\left(\beta_0, \beta(t_0) \cdot 2^{-\frac{t - t_0}{\tau}}\right)$$

Upon redemption of fraction $\alpha = \frac{D_{\text{redeemed}}}{D_{\text{total}}}$:

$$\beta_{\text{new}} = \min\left(\beta(t) + \frac{\alpha}{2}, \beta_{\max}\right)$$

---

## Contract Footprint & Bytecode Analysis

All contracts are written in native **Vyper 0.4.3**, benefiting from strict Pythonic syntax, complete absence of inheritance ambiguity, bounded loops, and zero reentrancy hazards:

| Contract | Runtime Size (B) | Initcode Size (B) | Size Limit (B) | Margin (B) |
| :--- | :--- | :--- | :--- | :--- |
| `AegisToken.vy` | 3,468 B | 3,710 B | 24,576 B | 21,108 B |
| `PriceFeedOracle.vy` | 2,253 B | 2,375 B | 24,576 B | 22,323 B |
| `RedemptionEngine.vy` | 3,110 B | 3,387 B | 24,576 B | 21,466 B |
| `StabilityPool.vy` | 4,340 B | 4,967 B | 24,576 B | 20,236 B |
| `TroveManager.vy` | 11,225 B | 12,145 B | 24,576 B | 13,351 B |

---

## Gas Benchmark Profile

Evaluated via Foundry on EVM Cancun target:

| Function | Min Gas | Avg Gas | Max Gas | Description |
| :--- | :--- | :--- | :--- | :--- |
| `open_trove` | 24,278 | 289,347 | 291,134 | Deposit collateral, calculate fee & mint AEGIS |
| `add_collateral` | 45,800 | 58,200 | 62,100 | Transfer additional collateral into Trove |
| `withdraw_collateral` | 44,606 | 57,773 | 70,940 | Health factor checked collateral withdrawal |
| `mint_more_debt` | 65,100 | 86,526 | 92,300 | Mint supplementary debt against collateral |
| `repay_debt` | 42,100 | 58,640 | 61,200 | Burn AEGIS debt to boost ICR |
| `liquidate` | 121,838 | 154,811 | 187,785 | Liquidate underwater position into Stability Pool |
| `provide_to_sp` | 48,200 | 64,800 | 72,100 | Provide AEGIS to Stability Pool with accumulator update |
| `redeem_collateral` | 98,200 | 124,500 | 146,189 | 1:1 arbitrage redemption against lowest ICR trove |

---

## Installation & Testing

### Prerequisites
- Python 3.10+ with `vyper==0.4.3` (`pip install vyper==0.4.3`)
- Foundry suite (`curl -L https://foundry.paradigm.xyz | bash && foundryup`)

### Compile
```bash
# Compile Vyper smart contracts via Foundry
forge build --sizes
```

### Run Tests
```bash
# Execute unit, integration, and fuzz invariant tests
forge test -vvv --fuzz-runs 256
```

### Simulated Deployment
```bash
# Execute local deployment script simulation
forge script script/DeployAegisMint.s.sol
```

---

## Security Invariants

1. **Global Solvency Invariant**: For every active Trove $i$, $\text{ICR}_i \ge \text{MCR}$ unless marked underwater and awaiting liquidation.
2. **Conservation of Debt**: System total debt strictly matches the sum of individual Trove debts ($\sum D_i = D_{\text{total}}$).
3. **Non-Inflationary Redemption**: Redemption burns $100\%$ of redeemed AEGIS tokens before transferring collateral out.
4. **$O(1)$ Stability Pool Conservation**: Compounded depositor balances plus total debt offsets equal cumulative historical deposits.

---

## License

MIT License. Copyright (c) 2026 AegisMint Contributors.
