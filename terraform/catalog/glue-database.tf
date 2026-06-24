# ---------------------------------------------------------------------------
# Glue Data Catalog databases and canonical table schemas.
#
# One database per lake layer. The raw and curated tables are declared
# explicitly (rather than left entirely to crawler discovery) so that:
#
#   * Firehose Parquet conversion has a stable, apply-time table to bind to;
#   * the ETL job has an unambiguous input/output schema contract;
#   * the crawlers only need to register NEW partitions, never (re)derive the
#     column schema.
#
# event_type / year / month / day are Hive partition keys produced by the
# Firehose dynamic-partitioning prefix, so they are declared as partition_keys
# and intentionally omitted from the data columns.
# ---------------------------------------------------------------------------

resource "aws_glue_catalog_database" "raw" {
  name        = local.database_names.raw
  description = "Raw, source-fidelity events landed by Kinesis Firehose (JSON/GZIP)."

  tags = merge(var.tags, { Layer = "raw" })
}

resource "aws_glue_catalog_database" "staging" {
  name        = local.database_names.staging
  description = "Intermediate, cleansed datasets produced during transformation."

  tags = merge(var.tags, { Layer = "staging" })
}

resource "aws_glue_catalog_database" "curated" {
  name        = local.database_names.curated
  description = "Analytics-ready, partitioned Parquet tables for Athena and BI."

  tags = merge(var.tags, { Layer = "curated" })
}

# --------------------------- Raw events table -----------------------------
# OpenX JSON SerDe over the Firehose landing prefix. Tolerant of malformed
# rows and missing payload keys so a single bad record cannot fail a scan.
resource "aws_glue_catalog_table" "raw_events" {
  database_name = aws_glue_catalog_database.raw.name
  name          = local.raw_table
  description   = "Canonical raw clickstream events as delivered by Firehose."
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL                 = "TRUE"
    classification           = "json"
    "partition_filtering"    = "true"
    "projection.enabled"     = "false"
    "compressionType"        = "gzip"
    "objectCount"            = "0"
    "areColumnsQuoted"       = "false"
    "skip.header.line.count" = "0"
  }

  storage_descriptor {
    location      = "s3://${var.raw_bucket_id}/${local.events_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "openx-json"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = {
        "ignore.malformed.json" = "true"
        "dots.in.keys"          = "false"
        "case.insensitive"      = "true"
      }
    }

    columns {
      name = "event_id"
      type = "string"
    }
    columns {
      name = "ts"
      type = "string"
    }
    columns {
      name = "user_id"
      type = "string"
    }
    # Union of known payload keys; absent keys resolve to null.
    columns {
      name = "payload"
      type = "struct<country:string,session_id:string,value:double,query:string,sku:string,quantity:int>"
    }
  }

  partition_keys {
    name = "event_type"
    type = "string"
  }
  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }

  lifecycle {
    # The crawler registers partitions and may evolve table parameters; do not
    # fight it on every plan for partition-count bookkeeping.
    ignore_changes = [parameters["objectCount"]]
  }
}

# --------------------------- Curated events table -------------------------
# Flattened, strongly typed Parquet written by the ETL job. Day 87 layers
# Lake Formation permissions and Athena queries on top of this table.
resource "aws_glue_catalog_table" "curated_events" {
  database_name = aws_glue_catalog_database.curated.name
  name          = local.curated_table
  description   = "Curated, flattened, deduplicated events in Snappy Parquet."
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL              = "TRUE"
    classification        = "parquet"
    "partition_filtering" = "true"
    "parquet.compression" = "SNAPPY"
  }

  storage_descriptor {
    location      = "s3://${var.curated_bucket_id}/${local.events_prefix}/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "parquet"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name = "event_id"
      type = "string"
    }
    columns {
      name = "event_ts"
      type = "timestamp"
    }
    columns {
      name = "user_id"
      type = "string"
    }
    columns {
      name = "country"
      type = "string"
    }
    columns {
      name = "session_id"
      type = "string"
    }
    columns {
      name = "value"
      type = "double"
    }
    columns {
      name = "query"
      type = "string"
    }
    columns {
      name = "sku"
      type = "string"
    }
    columns {
      name = "quantity"
      type = "int"
    }
    columns {
      name = "processed_at"
      type = "timestamp"
    }
  }

  partition_keys {
    name = "event_type"
    type = "string"
  }
  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }
}
