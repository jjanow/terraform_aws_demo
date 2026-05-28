import json
import os
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

URLS_TABLE_NAME = os.environ["URLS_TABLE_NAME"]
SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]

_dynamodb = boto3.resource("dynamodb")
_sqs = boto3.client("sqs")
_table = _dynamodb.Table(URLS_TABLE_NAME)


def _log(level: str, message: str, **kwargs) -> None:
    print(json.dumps({"level": level, "message": message, **kwargs}))


def handler(event, context):
    short_code = (event.get("pathParameters") or {}).get("short_code", "").strip()
    if not short_code:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "Missing short_code"}),
        }

    try:
        result = _table.get_item(Key={"short_code": short_code})
    except ClientError as e:
        _log("error", "DynamoDB get_item failed", error_code=e.response["Error"]["Code"], short_code=short_code)
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "Internal server error"}),
        }

    item = result.get("Item")
    if not item:
        return {
            "statusCode": 404,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "URL not found"}),
        }

    # DynamoDB TTL deletion is eventual; check expiry explicitly
    expires_at = item.get("expires_at")
    if expires_at and int(expires_at) < int(time.time()):
        _log("info", "URL expired", short_code=short_code)
        return {
            "statusCode": 404,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "URL not found or expired"}),
        }

    original_url = item["original_url"]

    try:
        _sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=json.dumps({
                "event_type": "click",
                "short_code": short_code,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }),
        )
    except Exception as e:
        _log("warn", "Failed to publish click event", error=str(e), short_code=short_code)

    _log("info", "Redirecting", short_code=short_code)
    return {
        "statusCode": 301,
        "headers": {
            "Location": original_url,
            "Cache-Control": "no-store",
        },
        "body": "",
    }
