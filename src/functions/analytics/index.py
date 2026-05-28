import json
import os
from datetime import datetime, timezone, timedelta

import boto3
from botocore.exceptions import ClientError

ANALYTICS_TABLE_NAME = os.environ["ANALYTICS_TABLE_NAME"]

_dynamodb = boto3.resource("dynamodb")
_table = _dynamodb.Table(ANALYTICS_TABLE_NAME)

_TTL_DAYS = 90


def _log(level: str, message: str, **kwargs) -> None:
    print(json.dumps({"level": level, "message": message, **kwargs}))


def _process_record(body: dict, message_id: str) -> None:
    event_type = body.get("event_type")
    short_code = body.get("short_code")

    if not short_code:
        raise ValueError("Missing short_code in message body")

    if event_type != "click":
        _log("info", "Skipping non-click event", event_type=event_type, message_id=message_id)
        return

    event_timestamp = body.get("timestamp", datetime.now(timezone.utc).isoformat())
    # Composite SK: ISO timestamp + message ID ensures uniqueness across concurrent
    # clicks and idempotency across SQS at-least-once redeliveries of the same message.
    timestamp_sk = f"{event_timestamp}#{message_id}"
    ttl = int((datetime.now(timezone.utc) + timedelta(days=_TTL_DAYS)).timestamp())

    try:
        _table.put_item(
            Item={
                "short_code": short_code,
                "timestamp": timestamp_sk,
                "event_type": event_type,
                "click_count": 1,
                "ttl": ttl,
            },
            ConditionExpression="attribute_not_exists(short_code) AND attribute_not_exists(#ts)",
            ExpressionAttributeNames={"#ts": "timestamp"},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Record already exists — duplicate SQS delivery, safe to skip
            _log("info", "Duplicate event skipped", message_id=message_id, short_code=short_code)
            return
        raise


def handler(event, context):
    failed_items = []

    for record in event.get("Records", []):
        message_id = record["messageId"]
        try:
            body = json.loads(record["body"])
            _process_record(body, message_id)
        except json.JSONDecodeError as e:
            _log("error", "Failed to parse SQS message body", message_id=message_id, error=str(e))
            failed_items.append({"itemIdentifier": message_id})
        except Exception as e:
            _log("error", "Failed to process record", message_id=message_id, error=str(e))
            failed_items.append({"itemIdentifier": message_id})

    return {"batchItemFailures": failed_items}
