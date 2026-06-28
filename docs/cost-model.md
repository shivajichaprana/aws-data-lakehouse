# Cost model

This document breaks down what drives the cost of running the lakehouse, gives
an **illustrative** small-workload monthly estimate, and lists the levers that
move the bill the most.

> The figures below are rough, list-price estimates for `us-east-1` intended to
> build intuition — **not** a quote. Prices change and vary by region and usage;
> always validate against the
> [AWS Pricing Calculator](https://calculator.aws/) for your own numbers.

## Cost drivers

| Service             | Billed on                                              | Notes                                                            |
|---------------------|--------------------------------------------------------|------------------------------------------------------------------|
| Kinesis Firehose    | GB ingested (+ optional format conversion/partitioning)| The ingest meter; scales linearly with event volume             |
| S3                  | GB-month per tier + request + lifecycle transitions    | Raw dominates; tiering to IA/Glacier cuts long-tail storage      |
| KMS                 | Per key-month + per request                            | One CMK; **bucket keys** sharply reduce per-object request cost   |
| Glue (ETL/quality)  | DPU-hour, per-second after a 1-minute minimum          | Daily jobs are short; cost tracks runtime × DPUs                  |
| Glue crawlers       | DPU-hour                                                | `CRAWL_NEW_FOLDERS_ONLY` keeps crawls cheap                       |
| Athena              | TB scanned (\$5/TB)                                     | Partition pruning + Parquet are the main savings                  |
| QuickSight          | Per author-month + per reader-session                  | **Opt-in**; the single largest line when enabled                  |
| Step Functions      | State transitions (STANDARD)                            | Negligible at a daily cadence                                     |
| EventBridge / SNS / CloudWatch | Invocations / notifications / alarms + log GB | Effectively rounding error at this scale                  |

## Illustrative monthly estimate (baseline, QuickSight off)

Assumptions: ~50 GB/month of events ingested; ~50 GB raw + ~10 GB curated
Parquet retained; one daily crawler, one daily raw→curated ETL (G.1X, ~5 min),
and one daily PyDeequ run; ~100 GB/month scanned by Athena; ~30 pipeline
executions.

| Line item                         | Assumption                          | Est. / month |
|-----------------------------------|-------------------------------------|--------------|
| Firehose ingest                   | 50 GB × ~\$0.029/GB                  | ~\$1.50      |
| S3 storage + requests             | ~60 GB across layers, bucket keys   | ~\$1.50      |
| KMS                               | 1 CMK + scoped requests             | ~\$1.20      |
| Glue ETL + quality + crawler      | ~3 short daily jobs, 2 DPU each     | ~\$6.00      |
| Athena                            | ~0.1 TB scanned                     | ~\$0.50      |
| Step Functions + EventBridge      | ~30 runs, daily schedule            | <\$0.05      |
| CloudWatch alarms + logs          | ~3 alarms + modest log volume       | ~\$0.80      |
| SNS                               | a few email alerts                  | ~\$0.00      |
| **Baseline total**                |                                     | **~\$12–15** |

The estimate is dominated by **Glue compute** and **Firehose ingest**, both of
which scale with how often you run and how much data you move — not with the
number of resources Terraform creates.

## QuickSight (when enabled)

QuickSight is billed independently of the rest of the stack and is usually the
largest single line once switched on: roughly **\$18/author-month** (Enterprise)
plus reader-session charges (capped per reader). A team of two authors is on the
order of **\$36+/month** before readers. Leave `enable_quicksight = false`
unless the BI layer is actively used.

## Levers to control cost

1. **Scan less in Athena.** Curated data is Parquet and partitioned by
   `event_type/year/month/day`; always filter on partitions. The workgroup can
   also enforce a per-query bytes-scanned cap.
2. **Right-size and batch Glue.** Fewer, larger daily runs beat many small ones
   (the 1-minute minimum adds up). Job bookmarks avoid reprocessing.
3. **Lean on lifecycle.** Raw tiers to IA at 30 days and Glacier at 90; tune
   `raw_lifecycle` to your replay needs. Curated is rebuildable, so it does not
   need long-term archival.
4. **Keep bucket keys on.** They cut KMS request charges on high-object-count
   buckets by orders of magnitude (already enabled).
5. **Gate the optional layers.** QuickSight, X-Ray tracing, and the schedules
   are all flags — turn them off in environments that do not need them.
6. **Shorten retention where safe.** `athena_result_retention_days` and
   `log_retention_days` trim S3 and CloudWatch Logs storage.

## What this estimate excludes

Data transfer out of AWS, NAT/egress, cross-region replication, support plans,
and any pre-existing shared infrastructure (CloudTrail, Config) are not counted
here. Add them based on your environment.
