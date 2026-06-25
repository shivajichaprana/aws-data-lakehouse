# ---------------------------------------------------------------------------
# Query layer.
#
# Provides the interactive-analytics entrypoint over the curated lake layer:
#
#   * a dedicated, hardened S3 bucket for Athena query results;
#   * an Athena workgroup that enforces a result location, KMS encryption, and
#     (optionally) a per-query data-scanned cost guardrail;
#   * a catalogue of saved named queries over the curated events table.
#
# Lake Formation (catalog module) governs which columns each principal can read;
# this module governs where results land and how spend is capped.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  region      = data.aws_region.current.name

  # Fully-qualified curated table reference used by the named queries.
  curated_table_fqn = "\"${var.curated_database_name}\".\"${var.curated_table_name}\""
}
