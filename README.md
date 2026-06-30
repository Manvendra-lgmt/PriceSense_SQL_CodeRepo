# PriceSense_SQL_CodeRepo
# PriceSense — SQL-Driven Pricing Intelligence Framework

SQL codebase for a pricing intelligence system built for a D2C 
nutrition brand's high-protein snack launch. Developed for 
E-Cell IIT Guwahati × Ai Palette, Summer 2026.

## Dataset
50,150 transactions · 5,000 consumer profiles · 
47,581 geo-occasion rows · 720 competitor data points · 10 states

## The Detailed Analysis Of The Project
Overview
PriceSense is a pricing intelligence system built entirely in SQL to determine the optimal launch price for a D2C nutrition brand's high-protein snack portfolio. The project was structured as a real-world consulting engagement — starting from a messy raw dataset and ending with a three-SKU pricing playbook ready for implementation.
The dataset spanned 50,150 transactions, 5,000 consumer profiles, 47,581 geo-occasion records, and 720 competitor pricing observations across 10 Indian states and 60 competing products.

What I Built
The codebase was structured across two analytical phases, preceded by a full data cleaning and staging layer.
Phase 0 — Data Cleaning & Staging
Before any analysis, I built four SQL views to standardise the raw data:

v_clean_transactions — removed returns, null records, and statistical outliers (price > ₹200, flagged as >3σ). Ensured only valid revenue-generating rows were used downstream
v_clean_geography — normalised state name inconsistencies (e.g. 'Calfornia' → 'California') using a CASE statement lookup
v_clean_products — trimmed whitespace and corrected category mislabels ('Proten Shake' → 'Protein Shake') to ensure clean segmentation in downstream joins
v_master — a central joined view linking all four tables via user_id and order_id, used as the single source of truth for every downstream query

Phase 1 — Price Sensitivity & Elasticity
The goal was to identify exactly where demand breaks as price rises.
Key queries:

Demand distribution by price band — GROUP BY price bands with window functions to compute demand share percentage; identified the ₹30–₹50 band as the primary revenue zone
Threshold detection using LAG() — compared each band's unit volume against the previous band using LAG() OVER (ORDER BY band_id) to calculate demand_change_pct; flagged any band with a >30% drop as a hard pricing threshold
WTP (Willingness-to-Pay) Index — calculated as each persona's average transaction price relative to the overall average using AVG(price) / AVG(AVG(price)) OVER() * 100; this confirmed the Fitness persona as the highest WTP group
Persona-level price elasticity proxy — tracked average order quantity by price band per persona; the Budget persona showed sharply declining order sizes above ₹119, while Fitness remained stable through ₹149
P75 and P90 price percentiles per persona — used PERCENTILE_CONT(0.75/0.90) WITHIN GROUP (ORDER BY price) to derive conservative price ceilings for each segment
Key findings from Phase 1:

Fitness segment price elasticity: Ed = 0.9 (inelastic — recommended ₹149)
Budget segment: Ed = 1.8 (highly elastic — ceiling at ₹119)
Premium segment: Ed = 0.6 (brand-driven — absorbs ₹179)
Revenue index peaks at 116 at ₹149; collapses 63% above ₹179

Phase 2 — Contextual Optimisation
Layered geography, occasion, competitor position, and product claims onto the elasticity foundation.
Key queries:

Health claim premium analysis — used CROSS JOIN LATERAL with STRING_SPLIT() to explode the comma-separated claims column into individual tags, then computed AVG(price) - (SELECT AVG(price) FROM v_master) as a price premium per claim. Result: High-Protein = +18%, Keto-Friendly = +15%, Gluten-Free = +5%
City tier analysis — computed volume share and revenue share side-by-side using SUM() OVER () window functions; Tier-1 cities delivered disproportionate revenue per order (2× vs Tier-3)
Occasion-level pricing signal — categorised occasions as Premium-tolerant / Mid-range / Price-sensitive based on average price thresholds; Gym/Marathon (₹30.86/unit) and Religious Fasting (₹30.82/unit) were the top two premium-tolerant contexts
Competitor benchmarking — grouped all 60 competitor products into Budget / Mid / Premium tiers based on average observed price, mapped against the brand's SKU positioning
Revenue vs volume trade-off — computed revenue_per_unit = SUM(revenue) / SUM(quantity) alongside DENSE_RANK() on both revenue and volume to identify which price band optimises for each objective; ₹30–₹50 ranked #1 on revenue/unit at ₹39.70
Persona × City Tier cross-table — final cross-dimensional query combining persona, city tier, average price, and revenue to derive geo-specific recommended price points per segment

SQL Techniques Used
CTEs · Window Functions (LAG, RANK, SUM OVER, AVG OVER) · PERCENTILE_CONT · LATERAL / STRING_SPLIT · Multi-table JOINs · Correlated Subqueries · CASE-WHEN logic · Aggregate Views · NULLIF / COALESCE for division safety
Tools: SQL (PostgreSQL-compatible syntax) · Ai Palette Data Framework · Excel (validation)
Skills demonstrated: Pricing strategy · Consumer segmentation · Price elasticity analysis · Competitive benchmarking · Data cleaning · Business storytelling from raw data

## Structure
- Phase 0: Data cleaning & staging views
- Phase 1: Price sensitivity & elasticity modelling
- Phase 2: Contextual optimisation (claims, geo, occasions)

## Output
3-SKU pricing playbook (₹119 / ₹149 / ₹179) → +14% projected revenue gain
