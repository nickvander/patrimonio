# Patrimonio — Project Overview

Welcome to the documentation for **Patrimonio**, a cross-platform personal finance tracker designed for users with accounts in both the US and Mexico.

## Vision
Patrimonio aims to provide a single, unified dashboard to visualize your entire net worth across multiple institutions, countries, and currencies (USD/MXN), with real-time exchange rates and automated synchronization.

## Key Features
- **Multi-Currency Support**: Real-time USD/MXN conversion with global toggles.
- **US Institutional Sync**: Powered by [Plaid](https://plaid.com/) for automated banking, credit card, and brokerage data.
- **MX Manual Imports**: Robust parsers for Nu Mexico, Banamex, and CetesDirecto statements (PDF/CSV).
- **Wealth Projection**: Advanced FIRE tracking and portfolio growth simulations.
- **Premium UI**: Modern dark-themed dashboard built with Flutter.

## Technology Stack
- **Backend**: Rust + Axum + PostgreSQL + Redis
- **Frontend**: Flutter (Web, Desktop, Mobile)
- **Infrastructure**: Docker Compose, GCP Cloud Run

## Getting Started
To get the project running locally, refer to the [Deployment Guide](deployment.md).
