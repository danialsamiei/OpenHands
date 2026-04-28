from unittest.mock import MagicMock

from openhands.qadr.app_auth import _is_internal_webhook_request


def _request(path: str, client_host: str, headers: dict[str, str] | None = None):
    request = MagicMock()
    request.url.path = path
    request.headers = headers or {}
    request.client = MagicMock()
    request.client.host = client_host
    return request


def test_internal_webhook_request_allows_trusted_docker_network_without_header(
    monkeypatch,
):
    monkeypatch.setenv(
        'FREEGPT_OPENHANDS_INTERNAL_WEBHOOK_CIDRS',
        '172.19.0.0/16,127.0.0.1/32',
    )

    request = _request(
        '/api/v1/webhooks/events/abc',
        '172.19.0.18',
    )

    assert _is_internal_webhook_request(request) is True


def test_internal_webhook_request_rejects_untrusted_client_without_header(monkeypatch):
    monkeypatch.setenv(
        'FREEGPT_OPENHANDS_INTERNAL_WEBHOOK_CIDRS',
        '172.19.0.0/16,127.0.0.1/32',
    )

    request = _request(
        '/api/v1/webhooks/events/abc',
        '172.18.0.5',
    )

    assert _is_internal_webhook_request(request) is False


def test_internal_webhook_request_allows_session_api_key_from_any_client():
    request = _request(
        '/api/v1/webhooks/events/abc',
        '172.18.0.5',
        headers={'X-Session-API-Key': 'test-key'},
    )

    assert _is_internal_webhook_request(request) is True
