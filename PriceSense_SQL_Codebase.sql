-- ============================================================
--  PROJECT PRICESENSE — SQL Technical Codebase
--  D2C Nutrition Brand: High-Protein Snack Pricing Intelligence
--  Prepared for: IIT Guwahati E-Cell
-- ============================================================

-- ============================================================
--  PHASE 0: DATA CLEANING & STAGING
-- ============================================================

-- 0.1 Clean transactions: remove returns, nulls, extreme outliers
CREATE OR REPLACE VIEW v_clean_transactions AS
SELECT
    t.order_id,
    t.user_id,
    t.product_id,
    CAST(t.price AS DECIMAL(10,2))    AS price,
    CAST(t.quantity AS INT)           AS quantity,
    CAST(t.price * t.quantity AS DECIMAL(12,2)) AS revenue,
    t.timestamp,
    t.channel
FROM transactions t
WHERE
    t.price IS NOT NULL
    AND t.quantity IS NOT NULL
    AND CAST(t.price AS DECIMAL) > 0       -- remove refunds / credits
    AND CAST(t.quantity AS INT) > 0        -- remove return rows
    AND CAST(t.price AS DECIMAL) < 200     -- remove data-entry outliers (>3σ)
    AND t.user_id IS NOT NULL;

-- 0.2 Normalize geography (fix typos: 'Calfornia' → 'California', 'NY' → 'New York')
CREATE OR REPLACE VIEW v_clean_geography AS
SELECT
    order_id,
    CASE
        WHEN state IN ('Calfornia', 'California') THEN 'California'
        WHEN state IN ('NY', 'New York')          THEN 'New York'
        ELSE state
    END AS state,
    city_tier,
    occasion
FROM geography_occasion;

-- 0.3 Normalize product categories (trim whitespace, fix 'Proten Shake')
CREATE OR REPLACE VIEW v_clean_products AS
SELECT
    product_id,
    TRIM(CASE
        WHEN category = 'Proten Shake' THEN 'Protein Shake'
        WHEN category = 'Protein bar ' THEN 'Protein Bar'
        ELSE category
    END) AS category,
    claims,
    ingredient_tags,
    pack_size
FROM product_metadata;

-- 0.4 Master joined table (used by all downstream queries)
CREATE OR REPLACE VIEW v_master AS
SELECT
    t.order_id,
    t.user_id,
    t.product_id,
    t.price,
    t.quantity,
    t.revenue,
    t.timestamp,
    t.channel,
    c.persona,
    c.trend_affinity,
    c.age_group,
    c.income_bracket,
    c.dietary_restriction,
    g.state,
    g.city_tier,
    g.occasion,
    p.category,
    p.claims,
    p.pack_size
FROM v_clean_transactions      t
LEFT JOIN consumer_insights     c ON t.user_id  = c.user_id
LEFT JOIN v_clean_geography     g ON t.order_id = g.order_id
LEFT JOIN v_clean_products      p ON t.product_id = p.product_id
WHERE c.persona IS NOT NULL
  AND c.persona != '';


-- ============================================================
--  PHASE 1: SENSITIVITY FRAMEWORK — PRICE THRESHOLDS
-- ============================================================

-- 1.1 Demand distribution across price bands
--     Purpose: identify where demand drops significantly
SELECT
    CASE
        WHEN price < 10  THEN 'Band 1: Under $10'
        WHEN price < 20  THEN 'Band 2: $10–$20'
        WHEN price < 30  THEN 'Band 3: $20–$30'
        WHEN price < 50  THEN 'Band 4: $30–$50'
        WHEN price < 80  THEN 'Band 5: $50–$80'
        ELSE                  'Band 6: $80+'
    END                                                   AS price_band,
    COUNT(DISTINCT order_id)                              AS order_count,
    SUM(quantity)                                         AS total_units,
    SUM(revenue)                                          AS total_revenue,
    ROUND(AVG(quantity), 2)                               AS avg_units_per_order,
    ROUND(SUM(quantity) * 100.0 / SUM(SUM(quantity)) OVER (), 1) AS demand_share_pct
FROM v_master
GROUP BY 1
ORDER BY MIN(price);

-- 1.2 Threshold detection — demand drop score
--     Compares each band's units to the previous band
WITH band_demand AS (
    SELECT
        CASE
            WHEN price < 10  THEN 1
            WHEN price < 20  THEN 2
            WHEN price < 30  THEN 3
            WHEN price < 50  THEN 4
            WHEN price < 80  THEN 5
            ELSE 6
        END AS band_id,
        SUM(quantity) AS units
    FROM v_master
    GROUP BY 1
),
lagged AS (
    SELECT
        band_id,
        units,
        LAG(units) OVER (ORDER BY band_id) AS prev_units
    FROM band_demand
)
SELECT
    band_id,
    units,
    prev_units,
    ROUND((units - prev_units) * 100.0 / NULLIF(prev_units, 0), 1) AS demand_change_pct,
    CASE
        WHEN (units - prev_units) * 1.0 / NULLIF(prev_units, 0) < -0.30
        THEN 'THRESHOLD — SIGNIFICANT DROP'
        ELSE 'stable'
    END AS threshold_flag
FROM lagged
ORDER BY band_id;

-- 1.3 Persona-level price sensitivity
--     Compare demand distribution by persona across price bands
SELECT
    persona,
    CASE
        WHEN price < 10  THEN 'Under $10'
        WHEN price < 20  THEN '$10–$20'
        WHEN price < 30  THEN '$20–$30'
        WHEN price < 50  THEN '$30–$50'
        WHEN price < 80  THEN '$50–$80'
        ELSE '$80+'
    END                                        AS price_band,
    COUNT(DISTINCT order_id)                   AS orders,
    SUM(quantity)                              AS units,
    ROUND(AVG(price), 2)                       AS avg_price,
    -- % of persona's total volume in this band
    ROUND(
        SUM(quantity) * 100.0 /
        SUM(SUM(quantity)) OVER (PARTITION BY persona),
    1)                                         AS persona_demand_share_pct
FROM v_master
GROUP BY 1, 2
ORDER BY persona, MIN(price);

-- 1.4 Willingness-to-pay index by persona
--     Proxy: share of volume purchased above $30 (premium threshold)
SELECT
    persona,
    SUM(quantity)                                                    AS total_units,
    SUM(CASE WHEN price >= 30 THEN quantity ELSE 0 END)              AS units_above_30,
    SUM(CASE WHEN price >= 50 THEN quantity ELSE 0 END)              AS units_above_50,
    ROUND(SUM(CASE WHEN price >= 30 THEN quantity ELSE 0 END)
          * 100.0 / SUM(quantity), 1)                                AS pct_above_30,
    ROUND(SUM(CASE WHEN price >= 50 THEN quantity ELSE 0 END)
          * 100.0 / SUM(quantity), 1)                                AS pct_above_50,
    ROUND(AVG(price), 2)                                             AS avg_transaction_price,
    -- WTP Index: persona avg price relative to overall avg
    ROUND(AVG(price) / AVG(AVG(price)) OVER () * 100, 1)            AS wtp_index
FROM v_master
GROUP BY persona
ORDER BY wtp_index DESC;

-- 1.5 Quantity elasticity proxy by persona
--     Does avg order size change as price rises?
SELECT
    persona,
    CASE
        WHEN price < 10  THEN 'Under $10'
        WHEN price < 20  THEN '$10–$20'
        WHEN price < 30  THEN '$20–$30'
        WHEN price < 50  THEN '$30–$50'
        WHEN price < 80  THEN '$50–$80'
        ELSE '$80+'
    END                            AS price_band,
    COUNT(DISTINCT order_id)       AS order_count,
    ROUND(AVG(quantity), 2)        AS avg_qty_per_order
FROM v_master
GROUP BY 1, 2
ORDER BY persona, MIN(price);


-- ============================================================
--  PHASE 2: CONTEXTUAL OPTIMIZATION
-- ============================================================

-- 2.1 Product attribute premium: which claims command higher prices?
SELECT
    claim_tag,
    COUNT(DISTINCT m.product_id)  AS product_count,
    COUNT(DISTINCT order_id)      AS order_count,
    SUM(quantity)                 AS total_units,
    ROUND(AVG(price), 2)          AS avg_price,
    ROUND(MAX(price), 2)          AS max_price,
    -- Price premium vs overall average
    ROUND(AVG(price) - (SELECT AVG(price) FROM v_master), 2) AS price_premium_vs_avg
FROM v_master m
CROSS JOIN LATERAL (
    SELECT TRIM(value) AS claim_tag
    FROM STRING_SPLIT(m.claims, ',')
    WHERE TRIM(value) != ''
) AS claims_exploded
GROUP BY claim_tag
HAVING COUNT(DISTINCT order_id) >= 100
ORDER BY avg_price DESC;

-- 2.2 State-level pricing power
SELECT
    state,
    COUNT(DISTINCT order_id)   AS orders,
    SUM(quantity)              AS units,
    ROUND(SUM(revenue), 0)     AS total_revenue,
    ROUND(AVG(price), 2)       AS avg_price,
    ROUND(AVG(quantity), 2)    AS avg_qty_per_order,
    -- Revenue rank
    DENSE_RANK() OVER (ORDER BY SUM(revenue) DESC) AS revenue_rank
FROM v_master
WHERE state IS NOT NULL
GROUP BY state
ORDER BY total_revenue DESC;

-- 2.3 City tier analysis: pricing power vs volume trade-off
SELECT
    city_tier,
    COUNT(DISTINCT order_id)                          AS orders,
    SUM(quantity)                                     AS units,
    ROUND(SUM(revenue), 0)                            AS total_revenue,
    ROUND(AVG(price), 2)                              AS avg_price,
    -- Volume share
    ROUND(SUM(quantity) * 100.0 / SUM(SUM(quantity)) OVER (), 1) AS volume_share_pct,
    -- Revenue share
    ROUND(SUM(revenue) * 100.0 / SUM(SUM(revenue)) OVER (), 1)   AS revenue_share_pct
FROM v_master
WHERE city_tier IS NOT NULL
GROUP BY city_tier
ORDER BY avg_price DESC;

-- 2.4 Occasion-level pricing recommendation
SELECT
    occasion,
    COUNT(DISTINCT order_id)                          AS orders,
    SUM(quantity)                                     AS total_units,
    ROUND(AVG(price), 2)                              AS avg_price,
    ROUND(SUM(revenue), 0)                            AS total_revenue,
    -- Top persona for this occasion
    (
        SELECT persona
        FROM v_master v2
        WHERE v2.occasion = v1.occasion
        GROUP BY persona
        ORDER BY SUM(quantity) DESC
        LIMIT 1
    )                                                 AS dominant_persona,
    CASE
        WHEN AVG(price) >= 31 THEN 'Premium-tolerant'
        WHEN AVG(price) >= 29 THEN 'Mid-range'
        ELSE 'Price-sensitive'
    END                                               AS pricing_signal
FROM v_master v1
WHERE occasion IS NOT NULL
GROUP BY occasion
ORDER BY avg_price DESC;

-- 2.5 Cross-dimensional: Persona × City Tier optimal price point
SELECT
    persona,
    city_tier,
    COUNT(DISTINCT order_id)    AS orders,
    ROUND(AVG(price), 2)        AS avg_price,
    SUM(quantity)               AS units,
    ROUND(SUM(revenue), 0)      AS revenue
FROM v_master
WHERE persona IS NOT NULL
  AND city_tier IS NOT NULL
GROUP BY persona, city_tier
ORDER BY persona, city_tier;

-- 2.6 Revenue vs volume trade-off by price band
--     Which band maximizes revenue? Which maximizes volume?
SELECT
    CASE
        WHEN price < 10  THEN 'Band 1: Under $10'
        WHEN price < 20  THEN 'Band 2: $10–$20'
        WHEN price < 30  THEN 'Band 3: $20–$30'
        WHEN price < 50  THEN 'Band 4: $30–$50'
        WHEN price < 80  THEN 'Band 5: $50–$80'
        ELSE             'Band 6: $80+'
    END                                          AS price_band,
    SUM(quantity)                                AS total_units,
    ROUND(SUM(revenue), 0)                       AS total_revenue,
    ROUND(AVG(price), 2)                         AS avg_price,
    -- Revenue per unit (pricing efficiency)
    ROUND(SUM(revenue) / NULLIF(SUM(quantity), 0), 2) AS revenue_per_unit,
    -- Band-level revenue rank
    DENSE_RANK() OVER (ORDER BY SUM(revenue) DESC) AS revenue_rank,
    -- Band-level volume rank
    DENSE_RANK() OVER (ORDER BY SUM(quantity) DESC) AS volume_rank
FROM v_master
GROUP BY 1
ORDER BY MIN(price);

-- 2.7 Competitor benchmark — where do we stand?
SELECT
    cp.competitor_product_id,
    COUNT(cp.price)                AS observations,
    ROUND(AVG(CAST(cp.price AS DECIMAL(10,2))), 2) AS comp_avg_price,
    ROUND(MIN(CAST(cp.price AS DECIMAL(10,2))), 2) AS comp_min_price,
    ROUND(MAX(CAST(cp.price AS DECIMAL(10,2))), 2) AS comp_max_price,
    -- Segment the competitor into a tier
    CASE
        WHEN AVG(CAST(cp.price AS DECIMAL(10,2))) < 20 THEN 'Budget tier'
        WHEN AVG(CAST(cp.price AS DECIMAL(10,2))) < 35 THEN 'Mid tier'
        ELSE 'Premium tier'
    END AS competitor_tier
FROM competitor_pricing cp
WHERE cp.price IS NOT NULL AND cp.price != ''
GROUP BY cp.competitor_product_id
ORDER BY comp_avg_price;

-- 2.8 Optimal price recommendation per persona
--     Combines: WTP index, competitor floor, revenue/unit efficiency
WITH persona_metrics AS (
    SELECT
        persona,
        ROUND(AVG(price), 2)   AS actual_avg_price,
        ROUND(
            PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY price), 2
        )                      AS p75_price,
        ROUND(
            PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY price), 2
        )                      AS p90_price,
        SUM(revenue)           AS total_revenue,
        SUM(quantity)          AS total_units,
        ROUND(SUM(revenue) / NULLIF(SUM(quantity), 0), 2) AS revenue_per_unit
    FROM v_master
    GROUP BY persona
)
SELECT
    persona,
    actual_avg_price,
    p75_price,
    p90_price,
    revenue_per_unit,
    -- Recommended launch price = slightly above actual avg, guided by p75
    ROUND(actual_avg_price * 1.08, 2) AS recommended_floor,
    ROUND(p75_price        * 0.95, 2) AS recommended_ceiling,
    CASE persona
        WHEN 'budget'  THEN '$10–$20 sweet spot; elasticity high above $20'
        WHEN 'fitness' THEN '$25–$45 optimal; tolerates premium for functional claims'
        WHEN 'premium' THEN '$35–$60 viable; brand story justifies price'
        WHEN 'casual'  THEN '$15–$30 best range; price discovery still ongoing'
    END AS strategic_note
FROM persona_metrics
ORDER BY actual_avg_price DESC;
