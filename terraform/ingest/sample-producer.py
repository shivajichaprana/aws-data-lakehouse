#!/usr/bin/env python3
"""Publish synthetic events to the lakehouse Kinesis Firehose stream.

The events mirror the schema the ingest stream expects::

    {
        "event_type": "page_view",
        "event_id":   "8f1c...",
        "ts":         "2026-06-22T11:30:00.123456+00:00",
        "user_id":    "user_000042",
        "payload":    { ... }
    }

``event_type`` drives Firehose dynamic partitioning, so the producer emits a
configurable mix of event types. Records are sent with ``put_record_batch`` in
chunks of up to 500 (the Firehose API limit), and any per-record failures are
retried with bounded exponential backoff.

Example::

    python sample-producer.py --stream lakehouse-dev-ingest --count 1000
"""

from __future__ import annotations

import argparse
import json
import logging
import random
import sys
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, Iterable, Iterator, List, Sequence

try:
    import boto3
    from botocore.config import Config
    from botocore.exceptions import BotoCoreError, ClientError
except ImportError:  # pragma: no cover - dependency hint for operators
    print("boto3 is required: pip install boto3", file=sys.stderr)
    raise

LOGGER = logging.getLogger("sample-producer")

# Firehose put_record_batch accepts at most 500 records per call.
FIREHOSE_MAX_BATCH = 500

EVENT_TYPES: Sequence[str] = (
    "page_view",
    "add_to_cart",
    "checkout",
    "search",
    "login",
)

COUNTRIES: Sequence[str] = ("US", "GB", "IN", "DE", "BR", "JP")


def build_event(event_type: str) -> Dict[str, Any]:
    """Construct a single synthetic event record."""
    now = datetime.now(timezone.utc)
    payload: Dict[str, Any] = {
        "country": random.choice(COUNTRIES),
        "session_id": uuid.uuid4().hex,
        "value": round(random.uniform(0.0, 500.0), 2),
    }
    if event_type == "search":
        payload["query"] = random.choice(["shoes", "laptop", "coffee", "tent"])
    elif event_type in {"add_to_cart", "checkout"}:
        payload["sku"] = f"SKU-{random.randint(1000, 9999)}"
        payload["quantity"] = random.randint(1, 5)

    return {
        "event_type": event_type,
        "event_id": uuid.uuid4().hex,
        "ts": now.isoformat(),
        "user_id": f"user_{random.randint(0, 9999):06d}",
        "payload": payload,
    }


def generate_events(count: int, weights: Sequence[float] | None = None) -> Iterator[Dict[str, Any]]:
    """Yield ``count`` events with an optional per-type weighting."""
    for _ in range(count):
        event_type = random.choices(EVENT_TYPES, weights=weights, k=1)[0]
        yield build_event(event_type)


def chunked(items: Iterable[Dict[str, Any]], size: int) -> Iterator[List[Dict[str, Any]]]:
    """Split an iterable into lists of at most ``size`` items."""
    batch: List[Dict[str, Any]] = []
    for item in items:
        batch.append(item)
        if len(batch) >= size:
            yield batch
            batch = []
    if batch:
        yield batch


def _to_record(event: Dict[str, Any]) -> Dict[str, bytes]:
    # A trailing newline keeps records line-delimited even before the
    # AppendDelimiterToRecord processor runs, which helps local debugging.
    return {"Data": (json.dumps(event, separators=(",", ":")) + "\n").encode("utf-8")}


def send_batch(
    client: Any,
    stream: str,
    events: Sequence[Dict[str, Any]],
    *,
    max_retries: int = 5,
) -> int:
    """Send one batch, retrying only the records Firehose reports as failed.

    Returns the number of records that were ultimately delivered.
    """
    records = [_to_record(e) for e in events]
    attempt = 0

    while True:
        try:
            response = client.put_record_batch(DeliveryStreamName=stream, Records=records)
        except (ClientError, BotoCoreError) as exc:
            attempt += 1
            if attempt > max_retries:
                LOGGER.error("Batch failed after %d retries: %s", max_retries, exc)
                raise
            backoff = min(2 ** attempt, 30) + random.uniform(0, 0.5)
            LOGGER.warning("put_record_batch error (attempt %d): %s; retrying in %.1fs", attempt, exc, backoff)
            time.sleep(backoff)
            continue

        failed = int(response.get("FailedPutCount", 0))
        if failed == 0:
            return len(records)

        # Retry only the failed records (those carrying an ErrorCode).
        responses = response.get("RequestResponses", [])
        retry_records = [rec for rec, res in zip(records, responses) if res.get("ErrorCode")]
        delivered = len(records) - len(retry_records)

        attempt += 1
        if attempt > max_retries:
            LOGGER.error("%d records still failing after %d retries; giving up on them", len(retry_records), max_retries)
            return delivered

        backoff = min(2 ** attempt, 30) + random.uniform(0, 0.5)
        LOGGER.warning("%d/%d records failed; retrying in %.1fs", failed, len(records), backoff)
        time.sleep(backoff)
        records = retry_records


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stream", required=True, help="Firehose delivery stream name.")
    parser.add_argument("--count", type=int, default=100, help="Number of events to publish (default: 100).")
    parser.add_argument("--region", default=None, help="AWS region (defaults to the environment/profile).")
    parser.add_argument(
        "--batch-size",
        type=int,
        default=FIREHOSE_MAX_BATCH,
        help=f"Records per put_record_batch call (1-{FIREHOSE_MAX_BATCH}).",
    )
    parser.add_argument("--rate", type=float, default=0.0, help="Optional pause in seconds between batches.")
    parser.add_argument("--seed", type=int, default=None, help="Seed the RNG for reproducible event streams.")
    parser.add_argument("--verbose", action="store_true", help="Enable debug logging.")
    args = parser.parse_args(argv)

    if args.count <= 0:
        parser.error("--count must be positive")
    if not 1 <= args.batch_size <= FIREHOSE_MAX_BATCH:
        parser.error(f"--batch-size must be between 1 and {FIREHOSE_MAX_BATCH}")
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    if args.seed is not None:
        random.seed(args.seed)

    client = boto3.client(
        "firehose",
        region_name=args.region,
        config=Config(retries={"max_attempts": 3, "mode": "standard"}),
    )

    delivered = 0
    started = time.monotonic()
    for batch in chunked(generate_events(args.count), args.batch_size):
        delivered += send_batch(client, args.stream, batch)
        LOGGER.info("Delivered %d/%d events", delivered, args.count)
        if args.rate > 0:
            time.sleep(args.rate)

    elapsed = time.monotonic() - started
    LOGGER.info("Done: %d events to %s in %.1fs", delivered, args.stream, elapsed)
    return 0 if delivered == args.count else 1


if __name__ == "__main__":
    raise SystemExit(main())
