from __future__ import annotations

from dataclasses import dataclass

from fastapi import Request
from pydantic import SecretStr

from openhands.integrations.service_types import AuthenticationError
from openhands.qadr.session import FreeGPTSession, get_session_from_request, login_required
from openhands.server.settings import Settings
from openhands.server.user_auth.default_user_auth import DefaultUserAuth
from openhands.server.user_auth.user_auth import UserAuth


@dataclass
class QadrFreeGPTUserAuth(DefaultUserAuth):
    session: FreeGPTSession | None = None

    def _require_session(self) -> FreeGPTSession | None:
        if self.session is not None:
            return self.session
        if login_required():
            raise AuthenticationError('Authentication required')
        return None

    async def get_user_id(self) -> str | None:
        session = self._require_session()
        return session.user_id if session else None

    async def get_user_email(self) -> str | None:
        session = self._require_session()
        return session.email if session else None

    async def get_access_token(self) -> SecretStr | None:
        return None

    async def get_user_settings(self) -> Settings | None:
        settings = await super().get_user_settings()
        if settings and self.session:
            settings.email = self.session.email
            settings.email_verified = True
            if self.session.name and not settings.git_user_name:
                settings.git_user_name = self.session.name
        return settings

    async def get_mcp_api_key(self) -> str | None:
        return None

    @classmethod
    async def get_instance(cls, request: Request) -> UserAuth:
        session = get_session_from_request(request)
        return QadrFreeGPTUserAuth(session=session)

    @classmethod
    async def get_for_user(cls, user_id: str) -> UserAuth:
        return QadrFreeGPTUserAuth(
            session=FreeGPTSession(
                user_id=user_id,
                email=f'{user_id}@freegpt.local',
            )
        )

