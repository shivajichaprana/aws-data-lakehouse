# aws-data-lakehouse

An end-to-end, Terraform-managed **data lakehouse on AWS**: streaming ingest →
layered object storage → cataloging → governed query → BI, with automated data
quality checks.

```
producer ─▶ Kinesis Firehose ─▶ S3 raw ─▶ Glue (catalog + ETL) ─▶ S3 curated
                                                        │
                                                        ▼
                                  Lake Formation ─▶ Athena ─▶ QuickSight
```

> Status: under active development. The ingest and storage layers are in place;
> catalog, query, BI, and orchestration layers are added incrementally.

## Why a lakehouse

A lakehouse keeps the low cost and openness of a data lake (object storage,
open file formats, schema-on-read) while adding the governance and query
ergonomics traditionally associated with a warehouse (central catalog,
fine-grained access control, ACID-friendly curated tables). This repository
codifies that pattern with reusable Terraform modules so a team can stand up a
governed analytics platform from scratch.

## Layered storage model

| Layer    | Bucket suffix | Format            | Purpose                                            |
|----------|---------------|-------------------|----------------------------------------------------|
| Raw      | `-raw`        | Source-fidelity JSON (GZIP) | Immutable landing zone; exactly what producers sent |
| Staging  | `-staging`    | Parquet           | Cleansed, de-duplicated, type-coerced intermediate |
| Curated  | `-curated`    | Parquet (SNAPPY)  | Analytics-ready, partitioned, catalogued tables     |

Raw data is partitioned on write by `event_type` and ingestion date
(`year/month/day`) so downstream crawlers and queries can prune aggressively.

## Repository layout

```
terraform/
  ingest/      Kinesis Firehose delivery stream + IAM + sample producer
  storage/     Layered raw/staging/curated S3 buckets + KMS + lifecycle
  catalog/     Glue databases, crawlers, raw->curated ETL        (later)
  query/       Athena workgroup + named queries                  (later)
  viz/         QuickSight data source + dashboards                (later)
  quality/     PyDeequ data-quality checks + alarms               (later)
scripts/       Operational helper scripts
docs/          Architecture, governance, and cost documentation
```

Each Terraform directory is a self-contained module composed by the root
configuration in `terraform/`.

## Quick start

```bash
git clone https://github.com/shivajichaprana/aws-data-lakehouse.git
cd aws-data-lakehouse/terraform

terraform init
terraform plan  -var 'project=lakehouse' -var 'environment=dev'
terraform apply -var 'project=lakehouse' -var 'environment=dev'
```

Publish a few sample events once the stream exists:

```bash
python terraform/ingest/sample-producer.py \
  --stream "$(terraform output -raw firehose_stream_name)" \
  --count 500
```

## Requirements

- Terraform >= 1.5
- AWS provider >= 5.40
- An AWS account with permission to create Firehose, S3, KMS, IAM, and (later)
  Glue / Lake Formation / Athena / QuickSight resources
- Python 3.9+ with `boto3` for the sample producer

## Security

Please report security issues through a
[GitHub Security Advisory](https://github.com/shivajichaprana/aws-data-lakehouse/security/advisories/new)
rather than a public issue.

## License

Released under the [MIT License](LICENSE).
