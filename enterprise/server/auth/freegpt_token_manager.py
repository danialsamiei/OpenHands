"""
Token manager for FreeGPT.ir OIDC Identity Provider.

Handles token exchange, refresh, JWKS-based verification, and user info
retrieval — talking standard OIDC to the FreeGPT IdP instead of Keycloak.
"""

from __future__ import annotations

import time
from typing import Any

import httpx
import jwt as pyjwt
from jwt import PyJWKClient
from server.auth.constants import (
    FREEGPT_CLIENT_ID,
    FREEGPT_CLIENT_SECRET,
    FREEGPT_IDP_URL,
    FREEGPT_IDP_URL_EXT,
)
from server.logger import logger

from openhands.utils.http_session import httpx_verify_option


class FreeGPTUserInfo:
    """Parsed user info from the FreeGPT IdP."""

    def __init__(self, data: dict[str, Any]):
        self.sub: str = data["sub"]
        self.email: str | None = data.get("email")
        self.email_verified: bool = data.get("email_verified", False)
        self.name: str | None = data.get("name")
        self.preferred_username: str | None = data.get("preferred_username")
        self.freegpt_role: str = data.get("freegpt_role", "pending")
        self.picture: str | None = data.get("picture")


class FreeGPTTokenManager:
    """Manages OIDC token operations against the FreeGPT Identity Provider."""

    def __init__(self):
        self._jwk_client: PyJWKClient | None = None
        self._discovery: dict[str, Any] | None = None
        self._discovery_fetched_at: float = 0

    @property
    def _internal_base(self) -> str:
        """Internal URL for server-to-server calls (Docker network)."""
        return FREEGPT_IDP_URL.rstrip("/")

    @property
    def _external_base(self) -> str:
        """External URL for browser-facing redirects."""
        return (FREEGPT_IDP_URL_EXT or FREEGPT_IDP_URL).rstrip("/")

    async def get_discovery(self) -> dict[str, Any]:
        """Fetch and cache the OIDC discovery document."""
        if self._discovery and (time.time() - self._discovery_fetched_at) < 3600:
            return self._discovery
        async with httpx.AsyncClient(verify=httpx_verify_option()) as client:
            resp = await client.get(
                f"{self._internal_base}/.well-known/openid-configuration"
            )
            resp.raise_for_status()
            self._discovery = resp.json()
            self._discovery_fetched_at = time.time()
            return self._discovery

    def _get_jwk_client(self) -> PyJWKClient:
        if not self._jwk_client:
            self._jwk_client = PyJWKClient(f"{self._internal_base}/jwks")
        return self._jwk_client

    async def exchange_code(
        self, code: str, redirect_uri: str
    ) -> dict[str, str]:
        """Exchange an authorization code for tokens.

        Returns dict with: access_token, refresh_token, id_token, expires_in
        """
        async with httpx.AsyncClient(verify=httpx_verify_option()) as client:
            resp = await client.post(
                f"{self._internal_base}/token",
                data={
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": redirect_uri,
                    "client_id": FREEGPT_CLIENT_ID,
                    "client_secret": FREEGPT_CLIENT_SECRET,
                },
            )
            if resp.status_code != 200:
                logger.error(
                    f"FreeGPT token exchange failed: {resp.status_code} {resp.text}"
                )
                raise Exception(f"Token exchange failed: {resp.status_code}")
            return resp.json()

    async def refresh(self, refresh_token: str) -> dict[str, str]:
        """Refresh tokens using a refresh token.

        Returns dict with: access_token, refresh_token, id_token, expires_in
        """
        async with httpx.AsyncClient(verify=httpx_verify_option()) as client:
            resp = await client.post(
                f"{self._internal_base}/token",
                data={
                    "grant_type": "refresh_token",
                    "refresh_token": refresh_token,
                    "client_id": FREEGPT_CLIENT_ID,
                    "client_secret": FREEGPT_CLIENT_SECRET,
                },
            )
            if resp.status_code != 200:
                logger.error(
                    f"FreeGPT token refresh failed: {resp.status_code} {resp.text}"
                )
                raise Exception(f"Token refresh failed: {resp.status_code}")
            return resp.json()

    async def get_user_info(self, access_token: str) -> FreeGPTUserInfo:
        """Fetch user info from the IdP's /userinfo endpoint."""
        async with httpx.AsyncClient(verify=httpx_verify_option()) as client:
            resp = await client.get(
                f"{self._internal_base}/userinfo",
                headers={"Authorization": f"Bearer {access_token}"},
            )
            if resp.status_code != 200:
                logger.error(
                    f"FreeGPT userinfo failed: {resp.status_code} {resp.text}"
                )
                raise Exception(f"Userinfo request failed: {resp.status_code}")
            return FreeGPTUserInfo(resp.json())

    def decode_token_unverified(self, token: str) -> dict[str, Any]:
        """Decode a JWT without signature verification (for extracting claims
        from tokens we issued/refreshed ourselves)."""
        return pyjwt.decode(token, options={"verify_signature": False})

    def verify_token(self, token: str) -> dict[str, Any]:
        """Verify and decode a JWT using the IdP's JWKS."""
        jwk_client = self._get_jwk_client()
        signing_key = jwk_client.get_signing_key_from_jwt(token)
        return pyjwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=FREEGPT_CLIENT_ID,
        )

    def get_authorize_url(
        self,
        redirect_uri: str,
        state: str = "",
        scope: str = "openid profile email",
        nonce: str = "",
    ) -> str:
        """Build the authorization URL for browser redirect."""
        from urllib.parse import urlencode

        params = {
            "client_id": FREEGPT_CLIENT_ID,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": scope,
            "state": state,
        }
        if nonce:
            params["nonce"] = nonce
        return f"{self._external_base}/authorize?{urlencode(params)}"

    async def get_models_for_role(self, role: str) -> list[str]:
        """Fetch the list of allowed model names for a given role."""
        async with httpx.AsyncClient(verify=httpx_verify_option()) as client:
            resp = await client.get(
                f"{self._internal_base}/api/models",
                params={"role": role},
            )
            if resp.status_code != 200:
                logger.warning(f"FreeGPT model access check failed: {resp.status_code}")
                return []
            data = resp.json()
            return data.get("models", [])
