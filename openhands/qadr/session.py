from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import time
from dataclasses import dataclass
from typing import Any

import httpx
from fastapi import Request

SESSION_COOKIE_NAME = os.getenv(
    'FREEGPT_OPENHANDS_SESSION_COOKIE_NAME', 'qadr_openhands_session'
)
DEFAULT_LANGUAGE = os.getenv('FREEGPT_OPENHANDS_DEFAULT_LANGUAGE', 'fa')


@dataclass(slots=True)
class FreeGPTSession:
    user_id: str
    email: str
    name: str | None = None
    role: str | None = None
    issued_at: int = 0
    expires_at: int = 0

    def to_payload(self) -> dict[str, Any]:
        return {
            'uid': self.user_id,
            'email': self.email,
            'name': self.name,
            'role': self.role,
            'iat': self.issued_at,
            'exp': self.expires_at,
        }


def login_required() -> bool:
    return os.getenv('FREEGPT_OPENHANDS_REQUIRE_LOGIN', 'true').lower() == 'true'


def session_max_age_seconds() -> int:
    return int(os.getenv('FREEGPT_OPENHANDS_SESSION_MAX_AGE', '43200'))


def freegpt_auth_base_url() -> str:
    return os.getenv('FREEGPT_AUTH_BASE_URL', 'https://chat.freegpt.ir').rstrip('/')


def get_session_secret() -> str | None:
    secret = os.getenv('FREEGPT_OPENHANDS_SESSION_SECRET')
    if secret:
        return secret
    return None


def _urlsafe_b64encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode('utf-8').rstrip('=')


def _urlsafe_b64decode(data: str) -> bytes:
    padding = '=' * (-len(data) % 4)
    return base64.urlsafe_b64decode(f'{data}{padding}')


def _sign(data: str, secret: str) -> str:
    return hmac.new(secret.encode('utf-8'), data.encode('utf-8'), hashlib.sha256).hexdigest()


def create_signed_session_cookie(session: FreeGPTSession) -> str:
    secret = get_session_secret()
    if not secret:
        raise RuntimeError('FREEGPT_OPENHANDS_SESSION_SECRET is not configured')

    payload = json.dumps(
        session.to_payload(),
        ensure_ascii=True,
        separators=(',', ':'),
        sort_keys=True,
    )
    encoded = _urlsafe_b64encode(payload.encode('utf-8'))
    signature = _sign(encoded, secret)
    return f'{encoded}.{signature}'


def parse_signed_session_cookie(raw_cookie: str | None) -> FreeGPTSession | None:
    if not raw_cookie:
        return None

    secret = get_session_secret()
    if not secret:
        return None

    try:
        encoded, signature = raw_cookie.split('.', 1)
    except ValueError:
        return None

    expected_signature = _sign(encoded, secret)
    if not hmac.compare_digest(signature, expected_signature):
        return None

    try:
        payload = json.loads(_urlsafe_b64decode(encoded).decode('utf-8'))
    except (ValueError, json.JSONDecodeError):
        return None

    expires_at = int(payload.get('exp') or 0)
    if expires_at <= int(time.time()):
        return None

    user_id = str(payload.get('uid') or '').strip()
    email = str(payload.get('email') or '').strip()
    if not user_id or not email:
        return None

    return FreeGPTSession(
        user_id=user_id,
        email=email,
        name=(payload.get('name') or None),
        role=(payload.get('role') or None),
        issued_at=int(payload.get('iat') or 0),
        expires_at=expires_at,
    )


def get_session_from_request(request: Request) -> FreeGPTSession | None:
    cached_session = getattr(request.state, 'freegpt_session', None)
    if cached_session is not None:
        return cached_session

    session = parse_signed_session_cookie(request.cookies.get(SESSION_COOKIE_NAME))
    request.state.freegpt_session = session
    return session


def sanitize_next_path(next_path: str | None) -> str:
    if not next_path:
        return '/'
    if not next_path.startswith('/'):
        return '/'
    if next_path.startswith('//'):
        return '/'
    return next_path


def _extract_freegpt_user_payload(
    payload: dict[str, Any],
    fallback_email: str,
) -> tuple[str, str, str | None, str | None]:
    candidates: list[dict[str, Any]] = [payload]

    for key in ('user', 'data', 'result'):
        candidate = payload.get(key)
        if isinstance(candidate, dict):
            candidates.append(candidate)
            nested_user = candidate.get('user')
            if isinstance(nested_user, dict):
                candidates.append(nested_user)

    for candidate in candidates:
        user_id = str(
            candidate.get('id') or candidate.get('user_id') or candidate.get('uid') or ''
        ).strip()
        user_email = str(candidate.get('email') or fallback_email).strip()
        if user_id and user_email:
            return (
                user_id,
                user_email,
                (candidate.get('name') or payload.get('name') or None),
                (candidate.get('role') or payload.get('role') or None),
            )

    raise ValueError('FreeGPT login response did not include a valid user id')


async def authenticate_with_freegpt(
    email: str,
    password: str,
    http_client: httpx.AsyncClient | None = None,
) -> FreeGPTSession:
    if not email or not password:
        raise ValueError('Email and password are required')

    owns_client = http_client is None
    client = http_client or httpx.AsyncClient(timeout=20.0)

    try:
        response = await client.post(
            f'{freegpt_auth_base_url()}/api/v1/auths/signin',
            json={'email': email, 'password': password},
            headers={'Accept': 'application/json'},
        )
        response.raise_for_status()
        payload = response.json()
    except httpx.HTTPStatusError as exc:
        detail = 'Authentication failed'
        try:
            error_payload = exc.response.json()
            detail = (
                error_payload.get('detail')
                or error_payload.get('error')
                or detail
            )
        except ValueError:
            pass
        raise ValueError(str(detail)) from exc
    finally:
        if owns_client:
            await client.aclose()

    user_id, user_email, user_name, user_role = _extract_freegpt_user_payload(
        payload,
        email,
    )

    now = int(time.time())
    return FreeGPTSession(
        user_id=user_id,
        email=user_email,
        name=user_name,
        role=user_role,
        issued_at=now,
        expires_at=now + session_max_age_seconds(),
    )
