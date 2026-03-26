# Frontend Deep Dive

The frontend is a **Flutter** application that provides a unified experience across Web, Desktop, and Mobile.

## UI Architecture
Patrimonio uses a modular UI approach with custom themed components to maintain a premium "glassmorphism" aesthetic.

### Main Screens
- **Dashboard**: High-level overview of net worth and account breakdown.
- **Portfolio**: Detailed holding analysis and asset allocation.
- **Ledger**: Searchable transaction history across all accounts.
- **Projections**: FIRE calculator and future wealth simulations.

## State Management
The app uses a lightweight state management pattern (ChangeNotifier/Provider) to handle:
- **Navigation**: Side-rail vs. Bottom-nav depending on screen size.
- **Currency Context**: Global USD/MXN toggle.
- **Data Refreshing**: Triggering backend syncs and UI updates.

## Visual Design
- **Theme**: Premium dark mode with custom color scales (Emerald Green for growth, Indigo for cards).
- **Typography**: Inter (Google Fonts) for high readability.
- **Charts**: Custom implementation using `fl_chart` for fluid animations.

## Platform Support
| Platform | Status | Notes |
| :--- | :--- | :--- |
| **Web** | Primary | Optimized for desktop browsers. |
| **macOS/Windows** | Supported | Native desktop builds available. |
| **Android/iOS** | Planned | Mobile-specific layouts in development. |
