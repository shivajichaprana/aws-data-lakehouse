# ---------------------------------------------------------------------------
# Saved Athena named queries over the curated events table.
#
# Every query lives in the analytics workgroup (so it inherits the enforced
# result location + KMS encryption) and targets the curated database. Queries
# filter and/or group on the Hive partition columns (event_type/year/month/day)
# wherever possible so Athena prunes partitions and scans less data.
#
# Columns available on the curated events table:
#   event_id, event_ts, user_id, country, session_id, value, query, sku,
#   quantity, processed_at  (+ partitions event_type, year, month, day)
# ---------------------------------------------------------------------------

resource "aws_athena_named_query" "daily_event_counts" {
  name        = "${local.name_prefix}-daily-event-counts"
  description = "Event volume by day and event type."
  database    = var.curated_database_name
  workgroup   = aws_athena_workgroup.this.id

  query = <<-SQL
    SELECT year, month, day, event_type, COUNT(*) AS events
    FROM ${local.curated_table_fqn}
    GROUP BY year, month, day, event_type
    ORDER BY year DESC, month DESC, day DESC, events DESC;
  SQL
}

resource "aws_athena_named_query" "revenue_by_date" {
  name        = "${local.name_prefix}-revenue-by-date"
  description = "Daily purchase revenue, order count, and average order value."
  database    = var.curated_database_name
  workgroup   = aws_athena_workgroup.this.id

  query = <<-SQL
    SELECT year, month, day,
           COUNT(*)   AS purchases,
           SUM(value) AS revenue,
           AVG(value) AS avg_order_value
    FROM ${local.curated_table_fqn}
    WHERE event_type = 'purchase'
    GROUP BY year, month, day
    ORDER BY year DESC, month DESC, day DESC;
  SQL
}

resource "aws_athena_named_query" "top_skus_by_quantity" {
  name        = "${local.name_prefix}-top-skus-by-quantity"
  description = "Best-selling SKUs by units across cart and purchase events."
  database    = var.curated_database_name
  workgroup   = aws_athena_workgroup.this.id

  query = <<-SQL
    SELECT sku,
           SUM(quantity) AS units,
           COUNT(*)      AS line_items
    FROM ${local.curated_table_fqn}
    WHERE event_type IN ('add_to_cart', 'purchase')
      AND sku IS NOT NULL
    GROUP BY sku
    ORDER BY units DESC
    LIMIT 50;
  SQL
}

resource "aws_athena_named_query" "top_search_queries" {
  name        = "${local.name_prefix}-top-search-queries"
  description = "Most frequent search terms and the sessions that issued them."
  database    = var.curated_database_name
  workgroup   = aws_athena_workgroup.this.id

  query = <<-SQL
    SELECT lower(query)              AS search_term,
           COUNT(*)                  AS searches,
           COUNT(DISTINCT session_id) AS sessions
    FROM ${local.curated_table_fqn}
    WHERE event_type = 'search'
      AND query IS NOT NULL
      AND query <> ''
    GROUP BY lower(query)
    ORDER BY searches DESC
    LIMIT 50;
  SQL
}

resource "aws_athena_named_query" "daily_active_users" {
  name        = "${local.name_prefix}-daily-active-users"
  description = "Distinct active users and sessions per day."
  database    = var.curated_database_name
  workgroup   = aws_athena_workgroup.this.id

  query = <<-SQL
    SELECT year, month, day,
           COUNT(DISTINCT user_id)    AS dau,
           COUNT(DISTINCT session_id) AS sessions
    FROM ${local.curated_table_fqn}
    WHERE user_id IS NOT NULL
    GROUP BY year, month, day
    ORDER BY year DESC, month DESC, day DESC;
  SQL
}

resource "aws_athena_named_query" "events_by_country" {
  name        = "${local.name_prefix}-events-by-country"
  description = "Event and user counts grouped by viewer country."
  database    = var.curated_database_name
  workgroup   = aws_athena_workgroup.this.id

  query = <<-SQL
    SELECT country,
           COUNT(*)                AS events,
           COUNT(DISTINCT user_id) AS users
    FROM ${local.curated_table_fqn}
    WHERE country IS NOT NULL
    GROUP BY country
    ORDER BY events DESC;
  SQL
}

resource "aws_athena_named_query" "hourly_event_rate" {
  name        = "${local.name_prefix}-hourly-event-rate"
  description = "Event rate per hour and type over the last 7 days."
  database    = var.curated_database_name
  workgroup   = aws_athena_workgroup.this.id

  query = <<-SQL
    SELECT date_trunc('hour', event_ts) AS event_hour,
           event_type,
           COUNT(*)                      AS events
    FROM ${local.curated_table_fqn}
    WHERE event_ts >= current_timestamp - interval '7' day
    GROUP BY date_trunc('hour', event_ts), event_type
    ORDER BY event_hour DESC, events DESC;
  SQL
}

resource "aws_athena_named_query" "partition_freshness" {
  name        = "${local.name_prefix}-partition-freshness"
  description = "Latest partition and processing timestamp per event type (data freshness check)."
  database    = var.curated_database_name
  workgroup   = aws_athena_workgroup.this.id

  query = <<-SQL
    SELECT event_type,
           MAX(concat(year, '-', month, '-', day)) AS latest_partition,
           MAX(processed_at)                        AS last_processed_at
    FROM ${local.curated_table_fqn}
    GROUP BY event_type
    ORDER BY event_type;
  SQL
}
