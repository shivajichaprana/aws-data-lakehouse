# ---------------------------------------------------------------------------
# Root composition for the data lakehouse.
#
# Day-one scope wires the two foundational layers:
#   storage  layered raw/staging/curated buckets + CMK + lifecycle
#   ingest   Kinesis Firehose landing events into the raw bucket
#
# Catalog, query, BI, quality, and orchestration modules are composed in here
# as they are added.
# ---------------------------------------------------------------------------

module "storage" {
  source = "./storage"

  project                  = var.project
  environment              = var.environment
  kms_deletion_window_days = var.kms_deletion_window_days
  force_destroy            = var.force_destroy_buckets
  raw_lifecycle            = var.raw_lifecycle
  tags                     = var.tags
}

module "ingest" {
  source = "./ingest"

  project     = var.project
  environment = var.environment

  raw_bucket_arn = module.storage.raw_bucket_arn
  kms_key_arn    = module.storage.kms_key_arn

  buffer_size_mb          = var.firehose_buffer_size_mb
  buffer_interval_seconds = var.firehose_buffer_interval_seconds
  log_retention_days      = var.log_retention_days

  # Parquet conversion is enabled once the Glue catalog (catalog module) lands.
  enable_parquet_conversion = var.enable_parquet_conversion

  tags = var.tags
}
