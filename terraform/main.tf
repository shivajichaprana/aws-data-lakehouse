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

  # Lake Formation governance (Day 87): admins, tag-based access, registration.
  data_lake_admin_arns        = var.data_lake_admin_arns
  data_analyst_principal_arn  = var.data_analyst_principal_arn
  data_engineer_principal_arn = var.data_engineer_principal_arn
  enforce_lf_tag_access       = var.enforce_lf_tag_access
  register_s3_locations       = var.register_s3_locations

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

module "query" {
  source = "./query"

  project     = var.project
  environment = var.environment

  kms_key_arn           = module.storage.kms_key_arn
  access_logs_bucket_id = module.storage.access_logs_bucket_id

  # Athena queries target the curated layer produced by the catalog ETL job.
  curated_database_name = module.catalog.curated_database_name
  curated_table_name    = module.catalog.curated_events_table_name

  force_destroy         = var.force_destroy_buckets
  result_retention_days = var.athena_result_retention_days

  tags = var.tags
}

module "viz" {
  source = "./viz"

  project     = var.project
  environment = var.environment

  # QuickSight BI over the curated layer, through the Athena workgroup. Gated
  # off by default so a baseline plan needs no QuickSight subscription.
  enable_quicksight        = var.enable_quicksight
  quicksight_principal_arn = var.quicksight_principal_arn

  athena_workgroup_name = module.query.workgroup_name
  curated_database_name = module.catalog.curated_database_name
  curated_table_name    = module.catalog.curated_events_table_name

  tags = var.tags
}

module "quality" {
  source = "./quality"

  project     = var.project
  environment = var.environment

  curated_database_name = module.catalog.curated_database_name
  curated_table_name    = module.catalog.curated_events_table_name

  curated_bucket_id  = module.storage.bucket_ids["curated"]
  curated_bucket_arn = module.storage.bucket_arns["curated"]
  staging_bucket_id  = module.storage.bucket_ids["staging"]
  staging_bucket_arn = module.storage.bucket_arns["staging"]
  kms_key_arn        = module.storage.kms_key_arn

  # Reuse the catalog's Glue security configuration (same lake CMK posture).
  security_configuration_name = module.catalog.security_configuration_name

  deequ_jar_s3_uri    = var.deequ_jar_s3_uri
  enable_job_schedule = var.enable_quality_schedule
  job_schedule        = var.quality_job_schedule
  allowed_event_types = var.allowed_event_types
  alarm_email         = var.quality_alarm_email

  tags = var.tags
}
