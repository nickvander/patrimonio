use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ProjectionRequest {
    pub start_balance: f64,
    pub monthly_contribution: f64,
    pub annual_return_rate: f64,
    pub annual_expenses: f64,
    pub withdrawal_rate: f64, // e.g., 0.04
    pub years: i32,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ProjectionPoint {
    pub year: i32,
    pub month: i32,
    pub balance: f64,
    pub total_contributions: f64,
    pub total_growth: f64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct FireMetrics {
    pub fi_number: f64,
    pub current_progress_pct: f64,
    pub estimated_years_to_fi: Option<f64>,
    pub monthly_income_at_retirement: f64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ProjectionResponse {
    pub points: Vec<ProjectionPoint>,
    pub fire_metrics: FireMetrics,
}

/// Calculate wealth projection based on compound interest
pub fn calculate_projection(req: &ProjectionRequest) -> ProjectionResponse {
    let mut points = Vec::new();
    let mut current_balance = req.start_balance;
    let mut total_contributions = 0.0;
    
    // Monthly return rate from annual
    // (1 + r_a) = (1 + r_m)^12  => r_m = (1 + r_a)^(1/12) - 1
    let monthly_return_rate = (1.0 + req.annual_return_rate).powf(1.0 / 12.0) - 1.0;
    
    // Initial point
    points.push(ProjectionPoint {
        year: 0,
        month: 0,
        balance: current_balance,
        total_contributions: 0.0,
        total_growth: 0.0,
    });

    for m in 1..=(req.years * 12) {
        let growth = current_balance * monthly_return_rate;
        current_balance += growth + req.monthly_contribution;
        total_contributions += req.monthly_contribution;
        
        // We only push quarterly or yearly points to keep the payload reasonable
        // or just every month if requested. Let's do every month for now.
        if m % 1 == 0 {
            points.push(ProjectionPoint {
                year: m / 12,
                month: m % 12,
                balance: current_balance,
                total_contributions,
                total_growth: current_balance - req.start_balance - total_contributions,
            });
        }
    }

    // FIRE Metrics
    let fi_number = if req.withdrawal_rate > 0.0 {
        req.annual_expenses / req.withdrawal_rate
    } else {
        0.0
    };

    let current_progress_pct = if fi_number > 0.0 {
        (req.start_balance / fi_number) * 100.0
    } else {
        0.0
    };

    // Simple estimation of years to FI
    // This is essentially solving for t in: FinalBalance = fi_number
    let estimated_years_to_fi = calculate_years_to_fi(
        req.start_balance,
        req.monthly_contribution,
        req.annual_return_rate,
        fi_number
    );

    ProjectionResponse {
        points,
        fire_metrics: FireMetrics {
            fi_number,
            current_progress_pct,
            estimated_years_to_fi,
            monthly_income_at_retirement: (current_balance * req.withdrawal_rate) / 12.0,
        },
    }
}

fn calculate_years_to_fi(
    start: f64,
    monthly: f64,
    annual_rate: f64,
    target: f64
) -> Option<f64> {
    if start >= target {
        return Some(0.0);
    }
    
    let m_rate = (1.0 + annual_rate).powf(1.0 / 12.0) - 1.0;
    
    if m_rate <= 0.0 {
        if monthly <= 0.0 { return None; }
        return Some((target - start) / (monthly * 12.0));
    }

    // Formula for future value of annuity:
    // FV = P(1+r)^n + PMT [ ((1+r)^n - 1) / r ]
    // We want to find n where FV = target.
    // This requires numerical approximation or solving:
    // target = start*(1+r)^n + monthly * (((1+r)^n - 1) / r)
    // target = (start + monthly/r)*(1+r)^n - monthly/r
    // (target + monthly/r) / (start + monthly/r) = (1+r)^n
    // n = log((target + monthly/r) / (start + monthly/r)) / log(1+r)
    
    let pmt_over_r = monthly / m_rate;
    let numerator = target + pmt_over_r;
    let denominator = start + pmt_over_r;
    
    if numerator <= 0.0 || denominator <= 0.0 {
        return None;
    }
    
    let n = (numerator / denominator).ln() / (1.0 + m_rate).ln();
    Some(n / 12.0) // Convert months to years
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_projection_growth() {
        let req = ProjectionRequest {
            start_balance: 1000.0,
            monthly_contribution: 100.0,
            annual_return_rate: 0.10, // 10%
            annual_expenses: 40000.0,
            withdrawal_rate: 0.04,
            years: 1,
        };
        
        let res = calculate_projection(&req);
        assert_eq!(res.points.len(), 13); // 0 to 12 months
        
        let final_balance = res.points.last().unwrap().balance;
        // Approx: 1000 * 1.1 + 100 * 12 = 1100 + 1200 = 2300 (roughly)
        assert!(final_balance > 2200.0 && final_balance < 2400.0);
    }

    #[test]
    fn test_fi_number() {
        let req = ProjectionRequest {
            start_balance: 100000.0,
            monthly_contribution: 0.0,
            annual_return_rate: 0.0,
            annual_expenses: 40000.0,
            withdrawal_rate: 0.04,
            years: 1,
        };
        let res = calculate_projection(&req);
        assert_eq!(res.fire_metrics.fi_number, 1000000.0);
        assert_eq!(res.fire_metrics.current_progress_pct, 10.0);
    }
}
