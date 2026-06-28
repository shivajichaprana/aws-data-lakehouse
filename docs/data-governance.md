# Data governance

Governance in this lakehouse is enforced at three layers: **encryption**
(everything under one customer-managed key), **access control** (Lake Formation
tag-based grants, including column-level masking), and **lifecycle** (retention
and tiering on the raw layer). This document describes the model and how to
operate it.

## Encryption

A single customer-managed KMS key (the "lake CMK", key rotation enabled)
encrypts:

- all three S3 layers (SSE-KMS with bucket keys to cut KMS request cost),
- Firehose delivery and its CloudWatch error logs,
- Glue catalog output, job bookmarks, and job CloudWatch logs (via the Glue
  security configuration),
- Athena query results,
- the data-quality and pipeline SNS topics.

The key policy grants S3, Firehose, and Glue service principals usage scoped by
`aws:SourceAccount`, so cross-account use is denied by default.

## Lake Formation tag-based access control

Catalog access is governed by Lake Formation rather than IAM table grants.

**Administrators.** `aws_lakeformation_data_lake_settings` registers explicit
admin principals (`data_lake_admin_arns`), falling back to the deploying
identity when none are supplied. When `enforce_lf_tag_access = true` the legacy
`IAMAllowedPrincipals` super-grant is removed, so nothing is readable without an
explicit LF grant.

**Registered locations.** The raw, staging, and curated bucket prefixes are
registered as Lake Formation data locations (`register_s3_locations`), with
hybrid access enabled so service roles (for example the quality job) can still
read directly from S3.

**LF-Tags.** Two tags drive every grant:

| LF-Tag        | Values                            | Applied to                                              |
|---------------|-----------------------------------|---------------------------------------------------------|
| `layer`       | `raw`, `staging`, `curated`       | Databases per layer                                      |
| `sensitivity` | `public`, `internal`, `confidential` | Curated DB (`internal`); PII columns (`confidential`) |

The curated `user_id` and `session_id` columns are tagged
`sensitivity = confidential` via a `table_with_columns` assignment.

**Grants.** Two optional principals demonstrate the model:

- **Analyst** (`data_analyst_principal_arn`): `SELECT` on `layer = curated`
  **excluding** `sensitivity = confidential` columns. The analyst can query
  curated events but never sees `user_id` / `session_id` — column-level security
  enforced by Lake Formation.
- **Engineer** (`data_engineer_principal_arn`): read/write across `staging` and
  `curated`.

Both grants are gated on a non-null principal ARN, so a plan without those
inputs stays clean.

## Column-level security in practice

Because confidential columns are masked by tag rather than by view, the same
physical table serves both audiences:

```sql
-- Analyst session: returns business columns, no PII.
SELECT event_type, country, SUM(value) AS revenue
FROM curated.events
WHERE year = '2026' AND month = '06'
GROUP BY event_type, country;

-- Selecting a confidential column as the analyst principal is denied by
-- Lake Formation, not merely empty:
SELECT user_id FROM curated.events LIMIT 10;   -- access denied
```

## Data lifecycle and retention

The raw layer is the system of record and is tiered, not deleted early:
Infrequent Access at 30 days, Glacier at 90, expiration at 365
(`raw_lifecycle`, all tunable). Noncurrent versions expire after 30 days and
aborted multipart uploads are cleaned up. Staging and curated carry
housekeeping-only rules; curated is meant to be rebuildable from raw by
re-running the ETL job, so it is safe to treat as derived data.

Athena results expire from the results bucket after
`athena_result_retention_days` (default 30).

## Auditability

- **CloudTrail** (account-level, not provisioned here) captures Lake Formation
  grant changes and S3 data-plane events where enabled.
- **Glue job bookmarks + CloudWatch logs** record every ETL and quality run.
- **Data-quality results** are persisted as a full result set in S3 in addition
  to the emitted CloudWatch metrics, giving a durable history of constraint
  outcomes.
- **Step Functions execution history** (vended logs) records each daily
  pipeline run end to end.

## Operating checklist

1. Set `data_lake_admin_arns` to your platform team's roles before enabling
   `enforce_lf_tag_access` in a shared account — otherwise only the deploying
   identity administers the catalog.
2. Supply `data_analyst_principal_arn` / `data_engineer_principal_arn` to grant
   real consumers; review the LF-Tag assignments when adding PII columns.
3. Keep `force_destroy_buckets = false` outside throwaway environments so the
   raw system-of-record cannot be emptied by a `terraform destroy`.
