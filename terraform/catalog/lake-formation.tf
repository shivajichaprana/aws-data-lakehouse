# ---------------------------------------------------------------------------
# Lake Formation governance for the catalog.
#
# Layers tag-based (LF-Tag) access control on top of the Glue databases and
# tables defined in glue-database.tf:
#
#   * data lake settings  - explicit admins and (optionally) the removal of the
#                           legacy "Super" grant to IAMAllowedPrincipals so that
#                           access is governed by Lake Formation grants instead
#                           of coarse IAM-only access control;
#   * data locations      - the raw/staging/curated bucket prefixes registered
#                           with Lake Formation so it can broker data access;
#   * LF-Tags             - two ontologies, `layer` (raw/staging/curated) and
#                           `sensitivity` (public/internal/confidential);
#   * tag assignments     - databases tagged by layer, the curated database
#                           tagged internal, and the PII columns of the curated
#                           events table tagged confidential;
#   * tag-based grants     - optional analyst/engineer principals granted access
#                           through LF-Tag expressions, demonstrating
#                           column-level security (analysts never see the
#                           confidential columns).
#
# All grants that target a real principal are gated on that principal being
# supplied, so a plan without analyst/engineer ARNs stays clean.
# ---------------------------------------------------------------------------

locals {
  # Fall back to the deploying identity so the account never locks itself out
  # of Lake Formation administration when no explicit admins are provided.
  data_lake_admins = length(var.data_lake_admin_arns) > 0 ? var.data_lake_admin_arns : [data.aws_caller_identity.current.arn]

  # Empty default permissions remove the legacy IAMAllowedPrincipals "Super"
  # grant, forcing access through Lake Formation. Flip enforce_lf_tag_access to
  # false to keep IAM-only behaviour during a phased migration.
  default_catalog_permissions = var.enforce_lf_tag_access ? [] : ["ALL"]

  # S3 prefixes registered with Lake Formation (one per lake layer).
  registered_locations = var.register_s3_locations ? {
    raw     = var.raw_bucket_arn
    staging = var.staging_bucket_arn
    curated = var.curated_bucket_arn
  } : {}
}

# --------------------------- Data lake settings ---------------------------
resource "aws_lakeformation_data_lake_settings" "this" {
  admins                  = local.data_lake_admins
  trusted_resource_owners = var.trusted_resource_owners

  # Govern new databases/tables through Lake Formation rather than the implicit
  # IAM "Super" permission. Empty permissions == revoke the legacy default.
  create_database_default_permissions {
    permissions = local.default_catalog_permissions
    principal   = "IAM_ALLOWED_PRINCIPALS"
  }

  create_table_default_permissions {
    permissions = local.default_catalog_permissions
    principal   = "IAM_ALLOWED_PRINCIPALS"
  }
}

# --------------------------- Registered data locations --------------------
# Registering the bucket prefixes lets Lake Formation vend scoped, temporary
# credentials for data access. Hybrid access keeps IAM-based access working for
# principals that have not yet been onboarded to Lake Formation grants.
resource "aws_lakeformation_resource" "data_location" {
  for_each = local.registered_locations

  arn                     = each.value
  role_arn                = var.registration_role_arn
  use_service_linked_role = var.registration_role_arn == null
  hybrid_access_enabled   = var.hybrid_access_enabled
}

# --------------------------- LF-Tag definitions ---------------------------
# Tag ontologies. Creating LF-Tags requires data-lake-admin rights, so these
# depend on the settings resource above.
resource "aws_lakeformation_lf_tag" "layer" {
  key    = "layer"
  values = ["raw", "staging", "curated"]

  depends_on = [aws_lakeformation_data_lake_settings.this]
}

resource "aws_lakeformation_lf_tag" "sensitivity" {
  key    = "sensitivity"
  values = ["public", "internal", "confidential"]

  depends_on = [aws_lakeformation_data_lake_settings.this]
}

# --------------------------- Tag assignments ------------------------------
# Each database carries its layer tag; tables and columns inherit it unless
# explicitly overridden below.
resource "aws_lakeformation_resource_lf_tags" "raw_db" {
  database {
    name = aws_glue_catalog_database.raw.name
  }

  lf_tag {
    key   = aws_lakeformation_lf_tag.layer.key
    value = "raw"
  }

  depends_on = [aws_lakeformation_data_lake_settings.this]
}

resource "aws_lakeformation_resource_lf_tags" "staging_db" {
  database {
    name = aws_glue_catalog_database.staging.name
  }

  lf_tag {
    key   = aws_lakeformation_lf_tag.layer.key
    value = "staging"
  }

  depends_on = [aws_lakeformation_data_lake_settings.this]
}

# Curated database: layer=curated and a baseline sensitivity of internal that
# every curated table/column inherits by default.
resource "aws_lakeformation_resource_lf_tags" "curated_db" {
  database {
    name = aws_glue_catalog_database.curated.name
  }

  lf_tag {
    key   = aws_lakeformation_lf_tag.layer.key
    value = "curated"
  }

  lf_tag {
    key   = aws_lakeformation_lf_tag.sensitivity.key
    value = "internal"
  }

  depends_on = [aws_lakeformation_data_lake_settings.this]
}

# Override sensitivity to confidential on the PII columns of the curated events
# table. Analyst grants that exclude `confidential` will not see these columns.
resource "aws_lakeformation_resource_lf_tags" "curated_pii_columns" {
  table_with_columns {
    database_name = aws_glue_catalog_database.curated.name
    name          = aws_glue_catalog_table.curated_events.name
    column_names  = var.confidential_columns
  }

  lf_tag {
    key   = aws_lakeformation_lf_tag.sensitivity.key
    value = "confidential"
  }

  depends_on = [aws_lakeformation_resource_lf_tags.curated_db]
}

# --------------------------- Tag-based grants -----------------------------
# Analysts: DESCRIBE on curated databases and SELECT on curated tables, but the
# tag expression excludes `confidential`, so Lake Formation transparently
# filters out the PII columns at query time (column-level security).
resource "aws_lakeformation_permissions" "analyst_database" {
  count = var.data_analyst_principal_arn == null ? 0 : 1

  principal   = var.data_analyst_principal_arn
  permissions = ["DESCRIBE"]

  lf_tag_policy {
    resource_type = "DATABASE"

    expression {
      key    = aws_lakeformation_lf_tag.layer.key
      values = ["curated"]
    }
  }

  depends_on = [aws_lakeformation_resource_lf_tags.curated_db]
}

resource "aws_lakeformation_permissions" "analyst_tables" {
  count = var.data_analyst_principal_arn == null ? 0 : 1

  principal   = var.data_analyst_principal_arn
  permissions = ["SELECT", "DESCRIBE"]

  lf_tag_policy {
    resource_type = "TABLE"

    expression {
      key    = aws_lakeformation_lf_tag.layer.key
      values = ["curated"]
    }

    expression {
      key    = aws_lakeformation_lf_tag.sensitivity.key
      values = ["public", "internal"]
    }
  }

  depends_on = [aws_lakeformation_resource_lf_tags.curated_pii_columns]
}

# Engineers: read/write across staging + curated at every sensitivity level,
# including the confidential columns.
resource "aws_lakeformation_permissions" "engineer_database" {
  count = var.data_engineer_principal_arn == null ? 0 : 1

  principal   = var.data_engineer_principal_arn
  permissions = ["DESCRIBE", "CREATE_TABLE"]

  lf_tag_policy {
    resource_type = "DATABASE"

    expression {
      key    = aws_lakeformation_lf_tag.layer.key
      values = ["staging", "curated"]
    }
  }

  depends_on = [aws_lakeformation_resource_lf_tags.curated_db]
}

resource "aws_lakeformation_permissions" "engineer_tables" {
  count = var.data_engineer_principal_arn == null ? 0 : 1

  principal                     = var.data_engineer_principal_arn
  permissions                   = ["SELECT", "DESCRIBE", "INSERT", "ALTER"]
  permissions_with_grant_option = ["SELECT", "DESCRIBE"]

  lf_tag_policy {
    resource_type = "TABLE"

    expression {
      key    = aws_lakeformation_lf_tag.layer.key
      values = ["staging", "curated"]
    }

    expression {
      key    = aws_lakeformation_lf_tag.sensitivity.key
      values = ["public", "internal", "confidential"]
    }
  }

  depends_on = [aws_lakeformation_resource_lf_tags.curated_pii_columns]
}
