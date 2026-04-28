from __future__ import annotations

import html
import os
from ipaddress import ip_address, ip_network
from typing import Annotated
from urllib.parse import quote, urlparse

from fastapi import APIRouter, FastAPI, Form, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse

from openhands.qadr.session import (
    DEFAULT_LANGUAGE,
    SESSION_COOKIE_NAME,
    authenticate_with_freegpt,
    create_signed_session_cookie,
    get_session_from_request,
    login_required,
    sanitize_next_path,
)

AUTH_EXEMPT_PATHS = {
    '/alive',
    '/health',
    '/ready',
    '/server_info',
    '/favicon.ico',
    '/robots.txt',
    '/site.webmanifest',
    '/manifest.webmanifest',
    '/apple-touch-icon.png',
}
AUTH_EXEMPT_PREFIXES = (
    '/auth',
)


def _trusted_internal_webhook_networks() -> list:
    configured = os.getenv(
        'FREEGPT_OPENHANDS_INTERNAL_WEBHOOK_CIDRS',
        '172.19.0.0/16,127.0.0.1/32,::1/128',
    )
    trusted_networks = []
    for item in configured.split(','):
        item = item.strip()
        if not item:
            continue
        try:
            trusted_networks.append(ip_network(item, strict=False))
        except ValueError:
            continue
    return trusted_networks


def _trusted_internal_mcp_hosts() -> set[str]:
    configured = os.getenv('FREEGPT_OPENHANDS_INTERNAL_MCP_HOSTS', '').strip()
    trusted_hosts: set[str] = set()

    internal_mcp_base = os.getenv('OH_INTERNAL_MCP_URL', '').strip()
    if internal_mcp_base:
        parsed = urlparse(internal_mcp_base)
        if parsed.netloc:
            trusted_hosts.add(parsed.netloc.lower())

    if configured:
        trusted_hosts.update(
            {item.strip().lower() for item in configured.split(',') if item.strip()}
        )
        return trusted_hosts

    default_port = os.getenv('OPENHANDS_PORT', '39030').strip() or '39030'
    trusted_hosts.update(
        {
            f'host.docker.internal:{default_port}',
            f'127.0.0.1:{default_port}',
            f'localhost:{default_port}',
        }
    )
    return trusted_hosts


def _is_internal_mcp_request(request: Request) -> bool:
    if not request.url.path.startswith('/mcp'):
        return False

    conversation_id = request.headers.get('X-OpenHands-ServerConversation-ID', '').strip()
    if not conversation_id:
        return False

    host = (request.headers.get('host') or '').strip().lower()
    if host in _trusted_internal_mcp_hosts():
        return True

    client = getattr(request, 'client', None)
    client_host = getattr(client, 'host', '') if client else ''
    return client_host in {'127.0.0.1', '::1'}


def _is_internal_webhook_request(request: Request) -> bool:
    if not request.url.path.startswith('/api/v1/webhooks'):
        return False

    if bool(
        (request.headers.get('X-Session-API-Key') or '').strip()
        or (request.headers.get('X-Access-Token') or '').strip()
    ):
        return True

    client = getattr(request, 'client', None)
    client_host = getattr(client, 'host', '') if client else ''
    if not client_host:
        return False
    try:
        client_ip = ip_address(client_host)
    except ValueError:
        return False
    return any(client_ip in network for network in _trusted_internal_webhook_networks())


def _login_page(error_message: str | None = None, next_path: str = '/', email: str = '') -> str:
    error_html = ''
    if error_message:
        error_html = (
            '<div style="margin-bottom:16px;padding:12px 14px;border-radius:12px;'
            'background:#fef2f2;color:#991b1b;border:1px solid #fecaca">'
            f'{html.escape(error_message)}</div>'
        )

    return f"""<!doctype html>
<html lang="{html.escape(DEFAULT_LANGUAGE)}" dir="rtl">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>ورود به OpenHands</title>
    <style>
      body {{
        margin: 0;
        font-family: Tahoma, Arial, sans-serif;
        background: linear-gradient(135deg, #08131a 0%, #0f2f2a 100%);
        color: #e5f6ee;
        min-height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 24px;
      }}
      .card {{
        width: min(100%, 420px);
        background: rgba(7, 15, 19, 0.86);
        border: 1px solid rgba(110, 231, 183, 0.18);
        border-radius: 20px;
        box-shadow: 0 20px 60px rgba(0, 0, 0, 0.35);
        padding: 28px;
        backdrop-filter: blur(12px);
      }}
      h1 {{
        margin: 0 0 8px;
        font-size: 28px;
      }}
      p {{
        margin: 0 0 18px;
        line-height: 1.7;
        color: #b7d7ca;
      }}
      label {{
        display: block;
        margin: 0 0 8px;
        font-size: 14px;
        color: #d6f3e7;
      }}
      input {{
        width: 100%;
        box-sizing: border-box;
        border-radius: 12px;
        border: 1px solid rgba(148, 163, 184, 0.25);
        background: rgba(15, 23, 42, 0.6);
        color: #f8fafc;
        padding: 12px 14px;
        margin-bottom: 14px;
      }}
      button {{
        width: 100%;
        border: 0;
        border-radius: 12px;
        background: linear-gradient(90deg, #10b981 0%, #059669 100%);
        color: white;
        padding: 12px 14px;
        font-size: 15px;
        cursor: pointer;
      }}
      .note {{
        margin-top: 16px;
        font-size: 13px;
        color: #9cc8b5;
      }}
    </style>
  </head>
  <body>
    <main class="card">
      <h1>ورود به OpenHands</h1>
      <p>برای استفاده از سامانه، با حساب FreeGPT خودتان وارد شوید. پس از ورود، workspace و conversationهای شما به‌صورت مجزا نگهداری می‌شود.</p>
      {error_html}
      <form method="post" action="/auth/login">
        <input type="hidden" name="next" value="{html.escape(next_path)}" />
        <label for="email">ایمیل FreeGPT</label>
        <input id="email" name="email" type="email" value="{html.escape(email)}" autocomplete="username" required />
        <label for="password">رمز عبور</label>
        <input id="password" name="password" type="password" autocomplete="current-password" required />
        <button type="submit">ورود</button>
      </form>
      <div class="note">اگر هنوز حساب ندارید، ابتدا در FreeGPT ثبت‌نام کنید و بعد دوباره به این صفحه برگردید.</div>
    </main>
  </body>
</html>"""


def _set_session_cookie(response, session_cookie: str) -> None:
    response.set_cookie(
        key=SESSION_COOKIE_NAME,
        value=session_cookie,
        max_age=int(os.getenv('FREEGPT_OPENHANDS_SESSION_MAX_AGE', '43200')),
        httponly=True,
        secure=True,
        samesite='lax',
        path='/',
    )


def _clear_session_cookie(response) -> None:
    response.delete_cookie(
        key=SESSION_COOKIE_NAME,
        path='/',
        secure=True,
        httponly=True,
        samesite='lax',
    )


def _wants_html(request: Request) -> bool:
    accept = (request.headers.get('accept') or '').lower()
    if 'text/html' in accept:
        return True
    return request.url.path == '/' or '.' not in request.url.path.rsplit('/', 1)[-1]


def _is_auth_exempt(path: str) -> bool:
    if path in AUTH_EXEMPT_PATHS:
        return True
    return any(path.startswith(prefix) for prefix in AUTH_EXEMPT_PREFIXES)


router = APIRouter(prefix='/auth', tags=['QADR Auth'])


@router.get('', include_in_schema=False, response_model=None)
async def auth_root() -> RedirectResponse:
    return RedirectResponse('/auth/login', status_code=302)


@router.get('/login', include_in_schema=False, response_model=None)
async def auth_login_page(request: Request, next: str = '/') -> HTMLResponse:
    if not login_required():
        return HTMLResponse(_login_page(next_path=sanitize_next_path(next)))

    session = get_session_from_request(request)
    next_path = sanitize_next_path(next)
    if session:
        return RedirectResponse(next_path, status_code=302)

    return HTMLResponse(_login_page(next_path=next_path))


@router.post('/login', include_in_schema=False, response_model=None)
async def auth_login_submit(
    next: Annotated[str, Form()] = '/',
    email: Annotated[str, Form()] = '',
    password: Annotated[str, Form()] = '',
) -> HTMLResponse | RedirectResponse:
    next_path = sanitize_next_path(next)
    try:
        session = await authenticate_with_freegpt(email=email.strip(), password=password)
    except ValueError as exc:
        return HTMLResponse(
            _login_page(str(exc), next_path=next_path, email=email),
            status_code=401,
        )

    response = RedirectResponse(next_path, status_code=302)
    _set_session_cookie(response, create_signed_session_cookie(session))
    return response


@router.post('/api/login')
async def auth_login_api(request: Request) -> JSONResponse:
    payload = await request.json()
    email = str(payload.get('email') or '').strip()
    password = str(payload.get('password') or '')
    try:
        session = await authenticate_with_freegpt(email=email, password=password)
    except ValueError as exc:
        return JSONResponse({'error': str(exc)}, status_code=401)

    response = JSONResponse(
        {
            'user_id': session.user_id,
            'email': session.email,
            'name': session.name,
            'role': session.role,
        }
    )
    _set_session_cookie(response, create_signed_session_cookie(session))
    return response


@router.get('/logout', include_in_schema=False, response_model=None)
async def auth_logout(next: str = '/auth/login') -> RedirectResponse:
    response = RedirectResponse(sanitize_next_path(next), status_code=302)
    _clear_session_cookie(response)
    return response


@router.post('/logout')
async def auth_logout_api() -> JSONResponse:
    response = JSONResponse({'message': 'Logged out'})
    _clear_session_cookie(response)
    return response


@router.get('/session')
async def auth_session(request: Request) -> JSONResponse:
    session = get_session_from_request(request)
    if not session:
        return JSONResponse({'authenticated': False}, status_code=401)
    return JSONResponse(
        {
            'authenticated': True,
            'user_id': session.user_id,
            'email': session.email,
            'name': session.name,
            'role': session.role,
        }
    )


def install_qadr_auth(app: FastAPI) -> None:
    @app.middleware('http')
    async def qadr_auth_middleware(request: Request, call_next):
        session = get_session_from_request(request)
        request.state.freegpt_session = session

        if (
            not login_required()
            or _is_auth_exempt(request.url.path)
            or _is_internal_mcp_request(request)
            or _is_internal_webhook_request(request)
        ):
            return await call_next(request)

        if session is not None:
            return await call_next(request)

        if request.url.path.startswith('/api/'):
            return JSONResponse(
                {'error': 'Authentication required'},
                status_code=401,
                headers={'Cache-Control': 'no-store'},
            )

        if _wants_html(request):
            full_path = request.url.path
            if request.url.query:
                full_path = f'{full_path}?{request.url.query}'
            return RedirectResponse(
                f'/auth/login?next={quote(sanitize_next_path(full_path), safe="/?=&")}',
                status_code=302,
                headers={'Cache-Control': 'no-store'},
            )

        return JSONResponse(
            {'error': 'Authentication required'},
            status_code=401,
            headers={'Cache-Control': 'no-store'},
        )

    app.include_router(router)
