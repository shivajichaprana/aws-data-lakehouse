# ---------------------------------------------------------------------------
# BI / visualization layer.
#
# Stands up an Amazon QuickSight dashboard over the curated lake layer:
#
#   * an Athena data source bound to the analytics workgroup (so every dataset
#     query inherits the workgroup's result location, encryption, and cost cap);
#   * a SPICE dataset materialising the curated events table for fast,
#     concurrent dashboard reads;
#   * a daily SPICE refresh schedule; and
#   * an executive dashboard (KPI + category + trend visuals).
#
# Every QuickSight resource is gated on `enable_quicksight` AND a non-null
# `quicksight_principal_arn`. QuickSight requires an account subscription and a
# real principal to own the assets, so a credential-less `terraform plan` stays
# empty by default and only materialises once an operator opts in.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  region      = data.aws_region.current.name

  # Single switch the whole module keys off. Both an explicit opt-in and an
  # asset-owning principal are required for any QuickSight resource to exist.
  qs_enabled = var.enable_quicksight && var.quicksight_principal_arn != null

  # Stable, prefixed identifiers for the QuickSight assets.
  data_source_id = "${local.name_prefix}-curated-athena"
  data_set_id    = "${local.name_prefix}-curated-events"
  dashboard_id   = "${local.name_prefix}-curated-overview"

  # Curated table physical columns + Hive partition keys, mapped to QuickSight
  # column types. Declared once and reused by the dataset's input columns.
  curated_columns = [
    { name = "event_id", type = "STRING" },
    { name = "event_ts", type = "DATETIME" },
    { name = "user_id", type = "STRING" },
    { name = "country", type = "STRING" },
    { name = "session_id", type = "STRING" },
    { name = "value", type = "DECIMAL" },
    { name = "query", type = "STRING" },
    { name = "sku", type = "STRING" },
    { name = "quantity", type = "INTEGER" },
    { name = "processed_at", type = "DATETIME" },
    { name = "event_type", type = "STRING" },
    { name = "year", type = "STRING" },
    { name = "month", type = "STRING" },
    { name = "day", type = "STRING" },
  ]
}
