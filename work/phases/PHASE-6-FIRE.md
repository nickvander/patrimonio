# Phase 6: Wealth Projection & FIRE Tracking

**Goal:** Provide users with interactive tools to project future wealth and track progress toward Financial Independence (FIRE).

## Context
After consolidating all accounts (US + MX) and historical balances, the next logical step is to help the user plan for the future. This phase adds a "Projections" tab that calculates compound growth based on current net worth and user-defined assumptions.

## Deliverables

### 6.1 Backend Projection Engine
- [ ] New service `backend/src/services/projections.rs` to handle math.
- [ ] API endpoint `GET /api/projections/calculate` that accepts parameters:
    - `monthly_contribution`: Decimal
    - `annual_return_rate`: Decimal (e.g., 0.07)
    - `variance`: Decimal (optional, for best/worst case)
    - `years`: Integer (default 30)
- [ ] Logic to fetch current `net_worth_usd` as the starting point.
- [ ] Unit tests for compound interest calculations.

### 6.2 FIRE Tracking Logic
- [ ] Calculation of "FI Number" based on:
    - `annual_expenses` (User input or inferred from last 12 months)
    - `withdrawal_rate` (Default 4%)
- [ ] Progress towards FI (%) calculation.
- [ ] "Years to FI" estimate based on current savings rate.

### 6.3 Frontend: Wealth Projection Tab
- [ ] New `WealthProjectionScreen` in Flutter.
- [ ] Interactive line chart (using `fl_chart`) showing:
    - Projected Net Worth (Linear/Log scale options)
    - FI Target Line
    - Contribution vs. Growth breakdown
- [ ] Configuration sidebar/panel with sliders for:
    - Monthly Savings
    - Expected Return (%)
    - Retirement Spending (Target)
    - Safe Withdrawal Rate (%)
- [ ] "Milestone" cards (e.g., "Coast FI", "Lean FI", "Full FI").

## Success Criteria
- [ ] User can see a chart projecting their net worth 20+ years into the future.
- [ ] Changing the "Monthly Savings" slider immediately updates the projection and "Years to FI".
- [ ] The projection uses the real-time USD/MXN consolidated net worth as a baseline.
- [ ] UI provides a "WOW" factor with smooth animations and professional financial visualizations.
