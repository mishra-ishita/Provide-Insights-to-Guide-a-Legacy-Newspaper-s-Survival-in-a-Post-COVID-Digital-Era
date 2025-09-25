use postcovidpress;

-- 1. Monthly Circulation Drop Check
WITH circulation_mom AS (
    SELECT 
        fs.city_ID,
        c.city AS city_name,
        DATE_FORMAT(fs.month, '%Y-%m') AS month_yyyy_mm,
        fs.net_circulation,
        LAG(fs.net_circulation) OVER (
            PARTITION BY fs.city_ID 
            ORDER BY fs.month
        ) AS prev_net_circulation
    FROM fact_print_sales fs
    JOIN dim_city c 
        ON fs.city_ID = c.city_id
    WHERE fs.Year BETWEEN 2019 AND 2024
)
SELECT 
    city_name,
    month_yyyy_mm,
    net_circulation,
    (net_circulation - prev_net_circulation) AS circulation_drop
FROM circulation_mom
WHERE prev_net_circulation IS NOT NULL
ORDER BY circulation_drop ASC   -- ASC because largest decline = most negative
LIMIT 3;

-- 2. Yearly Revenue Concentration by Category
WITH category_yearly_revenue AS (
    SELECT 
        fr.year,
        dac.standard_ad_category AS category_name,
        SUM(fr.ad_revenue) AS category_revenue
    FROM fact_ad_revenue fr
    JOIN dim_ad_category dac 
        ON fr.ad_category = dac.raw_ad_category
    GROUP BY fr.year, dac.standard_ad_category
),
yearly_total AS (
    SELECT 
        year,
        SUM(category_revenue) AS total_revenue_year
    FROM category_yearly_revenue
    GROUP BY year
)
SELECT 
    cyr.year,
    cyr.category_name,
    cyr.category_revenue,
    yt.total_revenue_year,
    ROUND((cyr.category_revenue / yt.total_revenue_year) * 100, 2) AS pct_of_year_total
FROM category_yearly_revenue cyr
JOIN yearly_total yt 
    ON cyr.year = yt.year
ORDER BY cyr.year, pct_of_year_total DESC;

-- 3. 2024 Print Efficiency Leaderboard
WITH city_efficiency AS (
    SELECT 
        dc.city AS city_name,
        SUM(fs.copies_printed) AS copies_printed_2024,
        SUM(fs.net_circulation) AS net_circulation_2024,
        ROUND(SUM(fs.net_circulation) / NULLIF(SUM(fs.copies_printed), 0), 4) AS efficiency_ratio
    FROM fact_print_sales fs
    JOIN dim_city dc 
        ON fs.city_ID = dc.city_id
    WHERE fs.Year = 2024
    GROUP BY dc.city
)
SELECT 
    city_name,
    copies_printed_2024,
    net_circulation_2024,
    efficiency_ratio,
    RANK() OVER (ORDER BY efficiency_ratio DESC) AS efficiency_rank_2024
FROM city_efficiency
ORDER BY efficiency_rank_2024
LIMIT 5;

-- 4. Internet Readiness Growth (2021) 
WITH q1 AS (
    SELECT 
        cr.city_id,
        cr.internet_penetration AS internet_rate_q1_2021
    FROM fact__city__readiness cr
    WHERE cr.quarter = '2021-Q1'
),
q4 AS (
    SELECT 
        cr.city_id,
        cr.internet_penetration AS internet_rate_q4_2021
    FROM fact__city__readiness cr
    WHERE cr.quarter = '2021-Q4'
)
SELECT 
    dc.city AS city_name,
    q1.internet_rate_q1_2021,
    q4.internet_rate_q4_2021,
    (q4.internet_rate_q4_2021 - q1.internet_rate_q1_2021) AS delta_internet_rate
FROM q1
JOIN q4 ON q1.city_id = q4.city_id
JOIN dim_city dc ON q1.city_id = dc.city_id
ORDER BY delta_internet_rate DESC
LIMIT 1;

-- 5. Consistent Multi-Year Decline (2019→2024)
WITH circulation_summary AS (
    SELECT 
        dc.city,
        fps.year,
        SUM(fps.net_circulation) AS yearly_net_circulation
    FROM fact_print_sales fps
    JOIN dim_city dc 
        ON fps.city_id = dc.city_id
    WHERE fps.year IN (2019, 2024)
    GROUP BY dc.city, fps.year
),

revenue_summary AS (
    SELECT 
        dc.city,
        fr.year,
        SUM(fr.ad_revenue) AS yearly_ad_revenue
    FROM fact_ad_revenue fr
    JOIN fact_print_sales fps 
        ON fr.edition_id = fps.edition_id
    JOIN dim_city dc 
        ON fps.city_id = dc.city_id
    WHERE fr.year IN (2019, 2024)
    GROUP BY dc.city, fr.year
),

combined AS (
    SELECT 
        c2019.city,
        c2019.yearly_net_circulation AS circulation_2019,
        c2024.yearly_net_circulation AS circulation_2024,
        CASE 
            WHEN c2024.yearly_net_circulation < c2019.yearly_net_circulation THEN 'Decrease'
            WHEN c2024.yearly_net_circulation > c2019.yearly_net_circulation THEN 'Increase'
            ELSE 'Stable'
        END AS circulation_trend,
        
        r2019.yearly_ad_revenue AS revenue_2019,
        r2024.yearly_ad_revenue AS revenue_2024,
        CASE 
            WHEN r2024.yearly_ad_revenue < r2019.yearly_ad_revenue THEN 'Decrease'
            WHEN r2024.yearly_ad_revenue > r2019.yearly_ad_revenue THEN 'Increase'
            ELSE 'Stable'
        END AS revenue_trend
    FROM circulation_summary c2019
    JOIN circulation_summary c2024 
        ON c2019.city = c2024.city AND c2019.year = 2019 AND c2024.year = 2024
    JOIN revenue_summary r2019 
        ON c2019.city = r2019.city AND r2019.year = 2019
    JOIN revenue_summary r2024 
        ON c2019.city = r2024.city AND r2024.year = 2024
),

final AS (
    SELECT *,
        CASE 
            WHEN circulation_trend = 'Decrease' AND revenue_trend = 'Decrease' THEN 'Both Declined'
            WHEN circulation_trend = 'Increase' AND revenue_trend = 'Increase' THEN 'Both Increased'
            ELSE 'Mixed Trend'
        END AS overall_trend
    FROM combined
)

SELECT * 
FROM final
ORDER BY city;


-- 6. 2021 Readiness vs Pilot Engagement Outlier 
WITH readiness_2021 AS (
    SELECT 
        cr.city_id,
        AVG((cr.literacy_rate + cr.smartphone_penetration + cr.internet_penetration) / 3) AS readiness_score_2021
    FROM fact__city__readiness cr
    WHERE cr.quarter LIKE '2021%'   
    GROUP BY cr.city_id
),
engagement_2021 AS (
    SELECT 
        dp.city_id,
        SUM(dp.users_reached) AS engagement_metric_2021
    FROM fact_digital_pilot dp
    WHERE dp.launch_month LIKE '2021%'
    GROUP BY dp.city_id
),
combined AS (
    SELECT 
        dc.city AS city_name,
        r.readiness_score_2021,
        e.engagement_metric_2021,
        RANK() OVER (ORDER BY r.readiness_score_2021 DESC) AS readiness_rank_desc,
        RANK() OVER (ORDER BY e.engagement_metric_2021 ASC) AS engagement_rank_asc
    FROM readiness_2021 r
    JOIN engagement_2021 e ON r.city_id = e.city_id
    JOIN dim_city dc ON r.city_id = dc.city_id
)
SELECT 
    city_name,
    readiness_score_2021,
    engagement_metric_2021,
    readiness_rank_desc,
    engagement_rank_asc,
    CASE 
        WHEN readiness_rank_desc = 1 
             AND engagement_rank_asc <= 3 THEN 'Yes'
        ELSE 'No'
    END AS is_outlier
FROM combined
ORDER BY readiness_rank_desc, engagement_rank_asc;


