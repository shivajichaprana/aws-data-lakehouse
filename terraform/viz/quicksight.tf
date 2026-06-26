# ---------------------------------------------------------------------------
# QuickSight Athena data source, SPICE dataset, refresh schedule, dashboard.
#
# Data flow:
#   curated Glue table --(Athena workgroup)--> QuickSight data source
#                      --> SPICE dataset (daily full refresh)
#                      --> executive dashboard (KPI + category + trend).
#
# The QuickSight service role (aws-quicksight-service-role-v0) must already be
# permitted to use Athena, read the curated/results S3 buckets, and decrypt
# with the lake CMK. That account-level grant is intentionally out of module
# scope; this module owns only the analytics assets.
# ---------------------------------------------------------------------------

# --------------------------- Athena data source ---------------------------
resource "aws_quicksight_data_source" "athena" {
  count = local.qs_enabled ? 1 : 0

  aws_account_id = local.account_id
  data_source_id = local.data_source_id
  name           = "${local.name_prefix} curated (Athena)"
  type           = "ATHENA"

  parameters {
    athena {
      work_group = var.athena_workgroup_name
    }
  }

  # SSL is the default for ATHENA; pin it explicitly so a future provider
  # default change cannot silently downgrade the transport.
  ssl_properties {
    disable_ssl = false
  }

  permissions {
    principal = var.quicksight_principal_arn
    actions = [
      "quicksight:DescribeDataSource",
      "quicksight:DescribeDataSourcePermissions",
      "quicksight:PassDataSource",
      "quicksight:UpdateDataSource",
      "quicksight:UpdateDataSourcePermissions",
      "quicksight:DeleteDataSource",
    ]
  }

  tags = merge(var.tags, { Layer = "viz" })
}

# --------------------------- SPICE dataset --------------------------------
# A relational table over the curated events Glue table. Importing into SPICE
# decouples dashboard reads from Athena scan latency and cost; the daily
# refresh below keeps it current after the curated ETL job lands.
resource "aws_quicksight_data_set" "curated" {
  count = local.qs_enabled ? 1 : 0

  aws_account_id = local.account_id
  data_set_id    = local.data_set_id
  name           = "${local.name_prefix} curated events"
  import_mode    = var.spice_import_mode

  physical_table_map {
    physical_table_map_id = "curated-events"

    relational_table {
      data_source_arn = aws_quicksight_data_source.athena[0].arn
      catalog         = "AwsDataCatalog"
      schema          = var.curated_database_name
      name            = var.curated_table_name

      dynamic "input_columns" {
        for_each = local.curated_columns
        content {
          name = input_columns.value.name
          type = input_columns.value.type
        }
      }
    }
  }

  # Derive a coarse calendar day from the event timestamp for trend visuals.
  logical_table_map {
    logical_table_map_id = "curated-events-logical"
    alias                = "curated_events"

    source {
      physical_table_id = "curated-events"
    }

    data_transforms {
      create_columns_operation {
        columns {
          column_name = "event_date"
          column_id   = "event_date"
          expression  = "truncDate('DD', {event_ts})"
        }
      }
    }
  }

  permissions {
    principal = var.quicksight_principal_arn
    actions = [
      "quicksight:DescribeDataSet",
      "quicksight:DescribeDataSetPermissions",
      "quicksight:PassDataSet",
      "quicksight:DescribeIngestion",
      "quicksight:ListIngestions",
      "quicksight:UpdateDataSet",
      "quicksight:UpdateDataSetPermissions",
      "quicksight:DeleteDataSet",
      "quicksight:CreateIngestion",
      "quicksight:CancelIngestion",
    ]
  }

  tags = merge(var.tags, { Layer = "viz" })
}

# --------------------------- SPICE refresh schedule -----------------------
resource "aws_quicksight_refresh_schedule" "curated" {
  count = local.qs_enabled && var.spice_import_mode == "SPICE" ? 1 : 0

  aws_account_id = local.account_id
  data_set_id    = aws_quicksight_data_set.curated[0].data_set_id
  schedule_id    = "${local.name_prefix}-daily-full-refresh"

  schedule {
    refresh_type = "FULL_REFRESH"

    schedule_frequency {
      interval        = "DAILY"
      time_of_the_day = var.refresh_time_of_day
      timezone        = var.refresh_timezone
    }
  }
}

# --------------------------- Dashboard ------------------------------------
# Executive overview: total volume KPI, events by type, and a daily trend.
resource "aws_quicksight_dashboard" "curated" {
  count = local.qs_enabled ? 1 : 0

  aws_account_id      = local.account_id
  dashboard_id        = local.dashboard_id
  name                = "${local.name_prefix} curated overview"
  version_description  = "Curated lakehouse overview: volume, mix, and trend."

  dashboard_publish_options {
    ad_hoc_filtering_option {
      availability_status = "ENABLED"
    }
    export_to_csv_option {
      availability_status = "ENABLED"
    }
    sheet_controls_option {
      visibility_state = "COLLAPSED"
    }
  }

  definition {
    data_set_identifiers_declarations {
      data_set_arn = aws_quicksight_data_set.curated[0].arn
      identifier   = "curated"
    }

    sheets {
      sheet_id = "overview"
      name     = "Overview"

      # --- KPI: total events ---------------------------------------------
      visuals {
        kpi_visual {
          visual_id = "total-events"

          title {
            format_text {
              plain_text = "Total Events"
            }
          }

          chart_configuration {
            field_wells {
              values {
                numerical_measure_field {
                  field_id = "kpi-event-count"
                  column {
                    data_set_identifier = "curated"
                    column_name         = "event_id"
                  }
                  aggregation_function {
                    simple_numerical_aggregation = "COUNT"
                  }
                }
              }
            }
          }
        }
      }

      # --- KPI: total revenue (sum of value) -----------------------------
      visuals {
        kpi_visual {
          visual_id = "total-revenue"

          title {
            format_text {
              plain_text = "Total Value"
            }
          }

          chart_configuration {
            field_wells {
              values {
                numerical_measure_field {
                  field_id = "kpi-value-sum"
                  column {
                    data_set_identifier = "curated"
                    column_name         = "value"
                  }
                  aggregation_function {
                    simple_numerical_aggregation = "SUM"
                  }
                }
              }
            }
          }
        }
      }

      # --- Bar chart: events by type -------------------------------------
      visuals {
        bar_chart_visual {
          visual_id = "events-by-type"

          title {
            format_text {
              plain_text = "Events by Type"
            }
          }

          chart_configuration {
            field_wells {
              bar_chart_aggregated_field_wells {
                category {
                  categorical_dimension_field {
                    field_id = "cat-event-type"
                    column {
                      data_set_identifier = "curated"
                      column_name         = "event_type"
                    }
                  }
                }
                values {
                  numerical_measure_field {
                    field_id = "bar-event-count"
                    column {
                      data_set_identifier = "curated"
                      column_name         = "event_id"
                    }
                    aggregation_function {
                      simple_numerical_aggregation = "COUNT"
                    }
                  }
                }
              }
            }

            orientation = "HORIZONTAL"

            sort_configuration {
              category_items_limit {
                items_limit = 20
                other_categories = "INCLUDE"
              }
            }
          }
        }
      }

      # --- Line chart: daily event volume --------------------------------
      visuals {
        line_chart_visual {
          visual_id = "daily-volume"

          title {
            format_text {
              plain_text = "Daily Event Volume"
            }
          }

          chart_configuration {
            field_wells {
              line_chart_aggregated_field_wells {
                category {
                  date_dimension_field {
                    field_id         = "line-event-day"
                    date_granularity = "DAY"
                    column {
                      data_set_identifier = "curated"
                      column_name         = "event_ts"
                    }
                  }
                }
                values {
                  numerical_measure_field {
                    field_id = "line-event-count"
                    column {
                      data_set_identifier = "curated"
                      column_name         = "event_id"
                    }
                    aggregation_function {
                      simple_numerical_aggregation = "COUNT"
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  permissions {
    principal = var.quicksight_principal_arn
    actions = [
      "quicksight:DescribeDashboard",
      "quicksight:ListDashboardVersions",
      "quicksight:QueryDashboard",
      "quicksight:DescribeDashboardPermissions",
      "quicksight:UpdateDashboard",
      "quicksight:UpdateDashboardPermissions",
      "quicksight:UpdateDashboardPublishedVersion",
      "quicksight:DeleteDashboard",
    ]
  }

  tags = merge(var.tags, { Layer = "viz" })
}
