# ---------------------------------------------------------------------------
# Glue crawlers.
#
# The raw and curated tables already carry an explicit schema, so the crawlers
# run in "register new partitions only" mode: CRAWL_NEW_FOLDERS_ONLY with a
# LOG-only schema-change policy. They keep the catalog aware of newly arrived
# event_type/date partitions without ever rewriting the column definitions the
# ETL job depends on.
# ---------------------------------------------------------------------------

# --------------------------- Crawler IAM role -----------------------------
data "aws_iam_policy_document" "crawler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "crawler" {
  name                 = "${local.name_prefix}-glue-crawler"
  assume_role_policy   = data.aws_iam_policy_document.crawler_assume.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}

# Catalog access, logging, and Glue runtime permissions.
resource "aws_iam_role_policy_attachment" "crawler_service" {
  role       = aws_iam_role.crawler.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# The managed policy only grants S3 access to aws-glue-* buckets, so scope our
# lake buckets and CMK explicitly (read-only - crawlers never write data).
data "aws_iam_policy_document" "crawler_inline" {
  statement {
    sid    = "ReadLakeData"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      var.raw_bucket_arn,
      "${var.raw_bucket_arn}/*",
      var.curated_bucket_arn,
      "${var.curated_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "DecryptLakeObjects"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [var.kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "crawler_inline" {
  name   = "lake-access"
  role   = aws_iam_role.crawler.id
  policy = data.aws_iam_policy_document.crawler_inline.json
}

# Crawler behaviour shared by both layers: keep the declared schema, only add
# newly discovered partitions, and combine compatible schemas into one table.
locals {
  crawler_configuration = jsonencode({
    Version = 1.0
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })
}

# --------------------------- Raw crawler ----------------------------------
resource "aws_glue_crawler" "raw" {
  name          = "${local.name_prefix}-raw-events"
  description   = "Registers new raw-events partitions as Firehose delivers them."
  role          = aws_iam_role.crawler.arn
  database_name = aws_glue_catalog_database.raw.name
  schedule      = var.crawler_schedule

  security_configuration = aws_glue_security_configuration.this.name
  configuration          = local.crawler_configuration
  table_prefix           = ""

  s3_target {
    # Scoped to the events/ prefix, so Firehose error output under errors/ is
    # already out of scope (exclude patterns are ignored in new-folders mode).
    path = "s3://${var.raw_bucket_id}/${local.events_prefix}/"
  }

  recrawl_policy {
    recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "LOG"
  }

  lineage_configuration {
    crawler_lineage_settings = "DISABLE"
  }

  tags = merge(var.tags, { Layer = "raw" })

  depends_on = [aws_glue_catalog_table.raw_events]
}

# --------------------------- Curated crawler ------------------------------
resource "aws_glue_crawler" "curated" {
  name          = "${local.name_prefix}-curated-events"
  description   = "Registers curated-events partitions written by the ETL job."
  role          = aws_iam_role.crawler.arn
  database_name = aws_glue_catalog_database.curated.name
  schedule      = var.crawler_schedule

  security_configuration = aws_glue_security_configuration.this.name
  configuration          = local.crawler_configuration

  s3_target {
    path = "s3://${var.curated_bucket_id}/${local.events_prefix}/"
  }

  recrawl_policy {
    recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "LOG"
  }

  lineage_configuration {
    crawler_lineage_settings = "DISABLE"
  }

  tags = merge(var.tags, { Layer = "curated" })

  depends_on = [aws_glue_catalog_table.curated_events]
}
