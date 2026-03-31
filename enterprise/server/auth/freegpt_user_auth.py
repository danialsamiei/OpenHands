"""
FreeGPT.ir UserAuth implementation for OpenHands.

Authenticates users via the FreeGPT OIDC Identity Provider and provides
access to FreeGPT.ir's LLM models through LiteLLM.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

import jwt as pyjwt
from fastapi import Request
from pydantic import SecretStr
from server.auth.auth_error import (
    AuthError,
    CookieError,
    ExpiredError,
    NoCredentialsError,
)
from server.auth.constants import (
    FREEGPT_LITELLM_API_KEY,
    FREEGPT_LITELLM_API_URL,
)
from server.auth.freegpt_token_manager import FreeGPTTokenManager
from server.config import get_config
from server.logger import logger

from openhands.integrations.provider import PROVIDER_TOKEN_TYPE
from openhands.server.settings import Settings
from openhands.server.user_auth.user_auth import AuthType, UserAuth
from openhands.storage.data_models.secrets import Secrets
from openhands.storage.secrets.secrets_store import SecretsStore
from openhands.storage.settings.settings_store import SettingsStore

_token_manager = FreeGPTTokenManager()


@dataclass
class FreeGPTUserAuth(UserAuth):
    """UserAuth implementation for FreeGPT.ir SSO integration.

    Authenticates users via the FreeGPT OIDC IdP and provides
    settings/secrets using the FreeGPT LiteLLM backend.
    """

    refresh_token: SecretStr = field(default_factory=lambda: SecretStr(""))
    user_id: str = ""
    email: str | None = None
    email_verified: bool | None = None
    access_token: SecretStr | None = None
    freegpt_role: str = "pending"
    refreshed: bool = False
    _settings: Settings | None = None
    _secrets: Secrets | None = None
    auth_type: AuthType = AuthType.COOKIE

    async def get_user_id(self) -> str | None:
        return self.user_id

    async def get_user_email(self) -> str | None:
        return self.email

    async def get_access_token(self) -> SecretStr | None:
        logger.debug("freegpt_user_auth_get_access_token")
        try:
            if self.access_token is None or self._is_token_expired(self.access_token):
                await self._refresh_tokens()
            return self.access_token
        except AuthError:
            raise
        except Exception as e:
            raise AuthError() from e

    async def _refresh_tokens(self):
        """Refresh access and refresh tokens via the FreeGPT IdP."""
        if not self.refresh_token or not self.refresh_token.get_secret_value():
            raise ExpiredError()

        if self._is_token_expired(self.refresh_token):
            logger.debug("freegpt_user_auth_refresh:expired")
            raise ExpiredError()

        tokens = await _token_manager.refresh(self.refresh_token.get_secret_value())
        self.access_token = SecretStr(tokens["access_token"])
        self.refresh_token = SecretStr(tokens["refresh_token"])
        self.refreshed = True

        # Update user info from new access token
        payload = _token_manager.decode_token_unverified(tokens["access_token"])
        self.user_id = payload["sub"]
        self.email = payload.get("email")
        self.email_verified = payload.get("email_verified", False)
        self.freegpt_role = payload.get("freegpt_role", "pending")

    def _is_token_expired(self, token: SecretStr) -> bool:
        try:
            payload = pyjwt.decode(
                token.get_secret_value(), options={"verify_signature": False}
            )
            exp = payload.get("exp")
            if exp:
                # Add 30s buffer for clock skew
                return exp < (time.time() + 30)
            return False
        except Exception:
            return True

    async def get_provider_tokens(self) -> PROVIDER_TOKEN_TYPE | None:
        """FreeGPT integration doesn't use per-provider tokens.

        Model access is handled via the shared LiteLLM API key.
        """
        return None

    async def get_user_settings_store(self) -> SettingsStore:
        """Return a settings store backed by file storage.

        FreeGPT users get their LLM settings pre-configured to use
        the FreeGPT LiteLLM backend.
        """
        from openhands.storage.settings.file_settings_store import FileSettingsStore
        return FileSettingsStore()

    async def get_user_settings(self) -> Settings | None:
        """Return settings pre-configured with FreeGPT LiteLLM backend."""
        if self._settings:
            return self._settings

        settings_store = await self.get_user_settings_store()
        settings = await settings_store.load()

        if settings is None:
            settings = Settings()

        # Override LLM settings to use FreeGPT's LiteLLM
        if FREEGPT_LITELLM_API_URL:
            settings.llm_base_url = FREEGPT_LITELLM_API_URL
        if FREEGPT_LITELLM_API_KEY:
            settings.llm_api_key = SecretStr(FREEGPT_LITELLM_API_KEY)

        settings.email = self.email
        settings.email_verified = self.email_verified
        self._settings = settings
        return settings

    async def get_secrets_store(self) -> SecretsStore:
        from openhands.storage.secrets.file_secrets_store import FileSecretsStore
        return FileSecretsStore()

    async def get_secrets(self) -> Secrets | None:
        if self._secrets:
            return self._secrets
        secrets_store = await self.get_secrets_store()
        self._secrets = await secrets_store.load()
        return self._secrets

    async def get_allowed_models(self) -> list[str]:
        """Fetch the list of model name patterns this user can access
        based on their FreeGPT role."""
        return await _token_manager.get_models_for_role(self.freegpt_role)

    @classmethod
    async def get_instance(cls, request: Request) -> UserAuth:
        """Create a FreeGPTUserAuth instance from the request.

        Checks the 'freegpt_auth' cookie for signed JWT tokens.
        """
        logger.debug("freegpt_user_auth_get_instance")
        instance = await _freegpt_user_auth_from_cookie(request)
        if instance is None:
            logger.debug("freegpt_user_auth_get_instance:no_credentials")
            raise NoCredentialsError("failed to authenticate")
        return instance


async def _freegpt_user_auth_from_cookie(request: Request) -> FreeGPTUserAuth | None:
    """Extract FreeGPTUserAuth from the signed session cookie."""
    try:
        signed_token = request.cookies.get("freegpt_auth")
        if not signed_token:
            return None
        return _freegpt_user_auth_from_signed_token(signed_token)
    except Exception as exc:
        raise CookieError from exc


def _freegpt_user_auth_from_signed_token(signed_token: str) -> FreeGPTUserAuth:
    """Decode the signed session cookie and create a FreeGPTUserAuth."""
    logger.debug("freegpt_user_auth_from_signed_token")
    jwt_secret = get_config().jwt_secret.get_secret_value()
    decoded = pyjwt.decode(signed_token, jwt_secret, algorithms=["HS256"])

    access_token = decoded["access_token"]
    refresh_token = decoded["refresh_token"]

    # Extract user info from the access token (we signed the cookie, so we
    # trust the enclosed tokens came from our IdP)
    payload = pyjwt.decode(access_token, options={"verify_signature": False})

    return FreeGPTUserAuth(
        access_token=SecretStr(access_token),
        refresh_token=SecretStr(refresh_token),
        user_id=payload["sub"],
        email=payload.get("email"),
        email_verified=payload.get("email_verified", False),
        freegpt_role=payload.get("freegpt_role", "pending"),
        auth_type=AuthType.COOKIE,
    )
