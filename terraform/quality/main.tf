# ---------------------------------------------------------------------------
# Data-quality module.
#
# Runs a PyDeequ-based Glue job over the curated events layer and turns the
# verification result into operational signal:
#
#   * a Glue job (deequ-job.tf) executes completeness, uniqueness, and range
#     constraints, emits CloudWatch custom metrics, and persists the full
#     result set to S3;
#   * CloudWatch alarms (cloudwatch-alarms.tf) watch those metrics and notify
#     an SNS topic when a constraint fails, a run reports failure, or results
#     go stale.
#
# The job reads curated Parquet directly from S3 (not through the Lake
# Formation-governed catalog) so it needs only S3 + KMS access and does not
# require an LF grant. Lake Formation hybrid access keeps that IAM read working
# alongside tag-based governance.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  region      = data.aws_region.current.name

  job_name = "${local.name_prefix}-data-quality"

  # Curated Parquet location and where verification results are persisted.
  curated_path  = "s3://${var.curated_bucket_id}/${var.events_prefix}/"
  results_path  = "s3://${var.staging_bucket_id}/quality/${var.curated_table_name}/"
  script_key    = "assets/glue/quality_checks.py"
  script_source = "${path.module}/../../glue-scripts/quality_checks.py"

  # Base Glue arguments shared by every run.
  base_job_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-disable"
    "--enable-metrics"                   = "true"
    "--enable-observability-metrics"     = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "false"
    "--additional-python-modules"        = var.additional_python_modules

    "--curated_path"             = local.curated_path
    "--results_path"             = local.results_path
    "--database"                 = var.curated_database_name
    "--table"                    = var.curated_table_name
    "--metric_namespace"         = var.metric_namespace
    "--metric_job_name"          = local.job_name
    "--region"                   = local.region
    "--process_date"             = ""
    "--fail_on_error"            = tostring(var.fail_on_error)
    "--required_completeness"    = tostring(var.required_completeness)
    "--min_user_id_completeness" = tostring(var.min_user_id_completeness)
    "--allowed_event_types"      = join(",", var.allowed_event_types)
    "--max_quantity"             = var.max_quantity == null ? "" : tostring(var.max_quantity)

    "--TempDir" = "s3://${var.staging_bucket_id}/glue-temp/quality/"
  }

  # Deequ ships as a Scala assembly jar; PyDeequ is only the Python wrapper.
  # When a jar URI is supplied, put it (and our wrapper) ahead of Glue's
  # bundled jars on the classpath.
  deequ_jar_arguments = var.deequ_jar_s3_uri == null ? {} : {
    "--extra-jars"     = var.deequ_jar_s3_uri
    "--user-jars-first" = "true"
  }

  job_arguments = merge(local.base_job_arguments, local.deequ_jar_arguments)
}
