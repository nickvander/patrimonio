# Phase 7: Enhanced Visualizations

## Goal
Transform the raw financial data into actionable insights through advanced interactive charts, trend analysis, and performance benchmarking.

## Deliverables
- [ ] **Interactive Net Worth Drill-down**: Ability to click on chart points to see account balances at that point in time.
- [ ] **Asset Allocation Heatmap**: A Treemap visualization of current holdings across all institutions.
- [ ] **Spending & Income Trends**: 12-month rolling chart of cash flow (for integrated Plaid accounts).
- [ ] **Investment Performance vs. Indices**: Overlay portfolio performance against NASDAQ, S&P 500, and BTC in real-time.
- [ ] **Custom Date Range Selectors**: Global filters for 1M, YTD, 1Y, 5Y, and ALL timeframes.

## Technical Requirements
- **Backend**:
  - New aggregate endpoints for historical trend data.
  - Integration with more FX historical data points if needed.
- **Frontend**:
  - Integration of `fl_chart` or `syncfusion_flutter_charts`.
  - Implementation of a global `FilterProvider` for date ranges.
