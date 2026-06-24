# ---------------------------------------------------------------------------
# Root composition for the data lakehouse.
#
# Layers wired so far:
#   storage  layered raw/staging/curated buckets + CMK + lifecycle
#   ingest   Kinesis Firehose landing events into the raw bucket
#   catalog  Glue databases, tables, crawlers, and the raw->curated ETL job
#
# Query, BI, quality, and orchestration modules are composed in here as they
# are added.
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

module "catalog" {
  source = "./catalog"

  project     = var.project
  environment = var.environment

  raw_bucket_id      = module.storage.raw_bucket_id
  raw_bucket_arn     = module.storage.raw_bucket_arn
  staging_bucket_id  = module.storage.bucket_ids["staging"]
  staging_bucket_arn = module.storage.bucket_arns["staging"]
  curated_bucket_id  = module.storage.bucket_ids["curated"]
  curated_bucket_arn = module.storage.bucket_arns["curated"]
  kms_key_arn        = module.storage.kms_key_arn

  crawler_schedule    = var.crawler_schedule
  enable_job_schedule = var.enable_etl_schedule
  job_schedule        = var.etl_job_schedule

  tags = var.tags
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

  # Parquet conversion binds to the canonical raw-events Glue table. It stays
  # opt-in (enable_parquet_conversion defaults false); the names are wired
  # unconditionally so flipping the flag needs no further plumbing.
  enable_parquet_conversion = var.enable_parquet_conversion
  glue_database_name        = module.catalog.raw_database_name
  glue_table_name           = module.catalog.raw_events_table_name

  tags = var.tags
}
