import json
import os
import secrets
import string
import time
from datetime import datetime, timezone, timedelta
from urllib.parse import urlparse

import boto3
from botocore.exceptions import ClientError

URLS_TABLE_NAME = os.environ["URLS_TABLE_NAME"]
SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]
DOMAIN_NAME = os.environ["DOMAIN_NAME"]

_dynamodb = boto3.resource("dynamodb")
_sqs = boto3.client("sqs")
_table = _dynamodb.Table(URLS_TABLE_NAME)

_ALPHANUM = string.ascii_letters + string.digits
_CODE_LENGTH = 7
_TTL_DAYS = 90
_MAX_ATTEMPTS = 5


def _log(level: str, message: str, **kwargs) -> None:
    print(json.dumps({"level": level, "message": message, **kwargs}))


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _generate_code() -> str:
    while True:
        raw = secrets.token_urlsafe(_CODE_LENGTH * 2)
        filtered = "".join(c for c in raw if c in _ALPHANUM)
        if len(filtered) >= _CODE_LENGTH:
            return filtered[:_CODE_LENGTH]


def _validate_url(url: str) -> bool:
    if len(url) > 2048:
        return False
    if url != url.strip() or any(c in url for c in "\r\n\t"):
        return False
    try:
        parsed = urlparse(url)
        return parsed.scheme in ("http", "https") and bool(parsed.netloc)
    except Exception:
        return False


def handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
    except (json.JSONDecodeError, TypeError):
        return _response(400, {"error": "Invalid JSON body"})

    url = body.get("url", "")
    owner_id = body.get("owner_id", "")

    if not url or not owner_id:
        return _response(400, {"error": "url and owner_id are required"})

    if not isinstance(url, str) or not isinstance(owner_id, str):
        return _response(400, {"error": "url and owner_id must be strings"})

    if not _validate_url(url):
        return _response(400, {"error": "url must be a valid http/https URL with no control characters (max 2048 chars)"})

    now = datetime.now(timezone.utc)
    created_at = now.isoformat()
    expires_at = int((now + timedelta(days=_TTL_DAYS)).timestamp())

    short_code = None
    for attempt in range(_MAX_ATTEMPTS):
        candidate = _generate_code()
        try:
            _table.put_item(
                Item={
                    "short_code": candidate,
                    "original_url": url,
                    "owner_id": owner_id,
                    "created_at": created_at,
                    "expires_at": expires_at,
                },
                ConditionExpression="attribute_not_exists(short_code)",
            )
            short_code = candidate
            break
        except ClientError as e:
            code = e.response["Error"]["Code"]
            if code == "ConditionalCheckFailedException":
                _log("warn", "Short code collision, retrying", attempt=attempt, short_code=candidate)
                continue
            _log("error", "DynamoDB put_item failed", error_code=code, attempt=attempt)
            return _response(500, {"error": "Internal server error"})

    if short_code is None:
        _log("error", "Exceeded max short code collision retries", max_attempts=_MAX_ATTEMPTS)
        return _response(500, {"error": "Internal server error"})

    try:
        _sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=json.dumps({
                "event_type": "url_created",
                "short_code": short_code,
                "owner_id": owner_id,
                "timestamp": created_at,
            }),
        )
    except Exception as e:
        _log("warn", "Failed to publish analytics event", error=str(e), short_code=short_code)

    short_url = f"https://{DOMAIN_NAME}/api/{short_code}"
    _log("info", "URL shortened", short_code=short_code, owner_id=owner_id)
    return _response(201, {"short_code": short_code, "short_url": short_url})
