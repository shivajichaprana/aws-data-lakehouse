# ---------------------------------------------------------------------------
# Orchestration module.
#
# Composes the standing data-lakehouse components into one daily run:
#
#   StartRawCrawler ->(poll until READY)-> RunCuratedEtl(.sync)
#     -> RunDataQuality(.sync) -> [RefreshDashboard] -> PipelineSucceeded
#
# The raw crawler is asynchronous, so the machine starts it and then polls
# glue:GetCrawler on a bounded budget (interval x attempts) until it returns
# to READY. The two Glue jobs use the startJobRun.sync service integration so
# the machine blocks on their completion. Any stage failure (or a crawler
# timeout) is funnelled to a single NotifyFailure -> SNS -> Fail tail. The
# QuickSight refresh tail is appended only when a dataset id is supplied.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  region      = data.aws_region.current.name

  state_machine_name = "${local.name_prefix}-daily-pipeline"

  # Derive the resource ARNs the IAM policy scopes to from the supplied names.
  raw_crawler_arn = "arn:${local.partition}:glue:${local.region}:${local.account_id}:crawler/${var.raw_crawler_name}"
  etl_job_arn     = "arn:${local.partition}:glue:${local.region}:${local.account_id}:job/${var.etl_job_name}"
  quality_job_arn = "arn:${local.partition}:glue:${local.region}:${local.account_id}:job/${var.quality_job_name}"

  # The dashboard-refresh tail is wired only when QuickSight is actually live.
  refresh_enabled = var.enable_dashboard_refresh && var.quicksight_data_set_id != null
  dataset_arn     = local.refresh_enabled ? "arn:${local.partition}:quicksight:${local.region}:${local.account_id}:dataset/${var.quicksight_data_set_id}" : null

  # Terminal target after the quality stage depends on whether we refresh BI.
  post_quality_state = local.refresh_enabled ? "RefreshDashboard" : "PipelineSucceeded"

  # ---- Reusable Retry / Catch fragments -------------------------------
  # StartCrawler: retry only on throttling/transient API errors. Crucially we
  # do NOT use the States.TaskFailed wildcard here, so CrawlerRunningException
  # is not retried but falls straight through to its dedicated Catch.
  crawler_start_retry = [{
    ErrorEquals     = ["Glue.ThrottlingException", "Glue.OperationTimeoutException"]
    IntervalSeconds = 5
    MaxAttempts     = 3
    BackoffRate     = 2.0
  }]

  # Idempotent read/SDK calls: a short wildcard retry smooths transient blips.
  transient_retry = [{
    ErrorEquals     = ["States.TaskFailed"]
    IntervalSeconds = 5
    MaxAttempts     = 3
    BackoffRate     = 2.0
  }]

  # Synchronous Glue runs: only re-queue when blocked by the concurrency cap.
  # A genuine job failure is expensive to blindly repeat, so it goes to Catch.
  glue_run_retry = [{
    ErrorEquals     = ["Glue.ConcurrentRunsExceededException"]
    IntervalSeconds = 30
    MaxAttempts     = 5
    BackoffRate     = 2.0
  }]

  fail_catch = [{
    ErrorEquals = ["States.ALL"]
    ResultPath  = "$.error"
    Next        = "NotifyFailure"
  }]

  # ---- Base states (refresh-independent) ------------------------------
  base_states = {
    Initialize = {
      Type       = "Pass"
      Comment    = "Seed the crawler poll counter carried through the wait loop."
      Result     = { poll_count = 0 }
      ResultPath = "$.control"
      Next       = "StartRawCrawler"
    }

    StartRawCrawler = {
      Type       = "Task"
      Comment    = "Start the raw crawler so new Firehose partitions are registered before the ETL reads them."
      Resource   = "arn:aws:states:::aws-sdk:glue:startCrawler"
      Parameters = { Name = var.raw_crawler_name }
      ResultPath = null
      Retry      = local.crawler_start_retry
      Catch = [{
        ErrorEquals = ["Glue.CrawlerRunningException"]
        Comment     = "A crawl from a prior trigger is already in flight; skip straight to polling."
        ResultPath  = null
        Next        = "WaitForCrawler"
      }]
      Next = "WaitForCrawler"
    }

    WaitForCrawler = {
      Type    = "Wait"
      Comment = "Give the crawler time to progress before checking its state."
      Seconds = var.crawler_poll_interval_seconds
      Next    = "GetCrawlerStatus"
    }

    GetCrawlerStatus = {
      Type           = "Task"
      Comment        = "Poll the crawler state (READY means the run has finished)."
      Resource       = "arn:aws:states:::aws-sdk:glue:getCrawler"
      Parameters     = { Name = var.raw_crawler_name }
      ResultSelector = { "state.$" = "$.Crawler.State" }
      ResultPath     = "$.crawler"
      Retry          = local.transient_retry
      Next           = "IsCrawlerReady"
    }

    IsCrawlerReady = {
      Type = "Choice"
      Choices = [
        {
          Variable     = "$.crawler.state"
          StringEquals = "READY"
          Next         = "RunCuratedEtl"
        },
        {
          Variable                 = "$.control.poll_count"
          NumericGreaterThanEquals = var.crawler_max_poll_attempts
          Next                     = "CrawlerTimedOut"
        },
      ]
      Default = "IncrementPoll"
    }

    IncrementPoll = {
      Type       = "Pass"
      Comment    = "Bump the poll counter and wait again."
      Parameters = { "poll_count.$" = "States.MathAdd($.control.poll_count, 1)" }
      ResultPath = "$.control"
      Next       = "WaitForCrawler"
    }

    CrawlerTimedOut = {
      Type       = "Pass"
      Comment    = "Crawler exceeded the poll budget; record a synthetic error and notify."
      Result     = { Error = "CrawlerTimeout", Cause = "Raw crawler did not return to READY within the poll budget." }
      ResultPath = "$.error"
      Next       = "NotifyFailure"
    }

    RunCuratedEtl = {
      Type           = "Task"
      Comment        = "Run the raw->curated PySpark ETL job and block until it completes."
      Resource       = "arn:aws:states:::glue:startJobRun.sync"
      Parameters     = { JobName = var.etl_job_name }
      ResultPath     = "$.etl"
      TimeoutSeconds = var.etl_timeout_seconds
      Retry          = local.glue_run_retry
      Catch          = local.fail_catch
      Next           = "RunDataQuality"
    }

    RunDataQuality = {
      Type           = "Task"
      Comment        = "Run the PyDeequ data-quality verification and block until it completes."
      Resource       = "arn:aws:states:::glue:startJobRun.sync"
      Parameters     = { JobName = var.quality_job_name }
      ResultPath     = "$.quality"
      TimeoutSeconds = var.quality_timeout_seconds
      Retry          = local.glue_run_retry
      Catch          = local.fail_catch
      Next           = local.post_quality_state
    }

    NotifyFailure = {
      Type     = "Task"
      Comment  = "Publish the failing execution payload to SNS, then fail the run."
      Resource = "arn:aws:states:::sns:publish"
      Parameters = {
        TopicArn    = aws_sns_topic.alerts.arn
        Subject     = "[${local.state_machine_name}] data pipeline FAILED"
        "Message.$" = "States.JsonToString($)"
      }
      ResultPath = "$.notification"
      Next       = "PipelineFailed"
    }

    PipelineFailed = {
      Type  = "Fail"
      Error = "PipelineFailed"
      Cause = "A pipeline stage failed; inspect the SNS notification and the execution history."
    }

    PipelineSucceeded = {
      Type = "Succeed"
    }
  }

  # ---- Optional QuickSight refresh tail -------------------------------
  refresh_states = local.refresh_enabled ? {
    RefreshDashboard = {
      Type     = "Task"
      Comment  = "Kick off a full SPICE refresh of the curated dataset that backs the dashboard."
      Resource = "arn:aws:states:::aws-sdk:quicksight:createIngestion"
      Parameters = {
        AwsAccountId    = local.account_id
        DataSetId       = var.quicksight_data_set_id
        "IngestionId.$" = "States.UUID()"
        IngestionType   = "FULL_REFRESH"
      }
      ResultPath = "$.ingestion"
      Retry      = local.transient_retry
      Catch      = local.fail_catch
      Next       = "PipelineSucceeded"
    }
  } : {}

  pipeline_definition = jsonencode({
    Comment        = "Daily data-lakehouse pipeline: crawl raw -> curated ETL -> data quality -> refresh BI."
    StartAt        = "Initialize"
    TimeoutSeconds = var.pipeline_timeout_seconds
    States         = merge(local.base_states, local.refresh_states)
  })
}
