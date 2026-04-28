from __future__ import annotations

import os

from openhands.server.config.server_config import ServerConfig


class QadrServerConfig(ServerConfig):
    hide_llm_settings = os.environ.get('HIDE_LLM_SETTINGS', 'true') == 'true'
    settings_store_class = 'openhands.qadr.storage.QadrUserSettingsStore'
    secret_store_class = 'openhands.qadr.storage.QadrUserSecretsStore'
    conversation_store_class = 'openhands.qadr.storage.QadrUserConversationStore'
    user_auth_class = 'openhands.qadr.user_auth.QadrFreeGPTUserAuth'

    def verify_config(self):
        if (
            os.environ.get('FREEGPT_OPENHANDS_REQUIRE_LOGIN', 'true').lower() == 'true'
            and not os.environ.get('FREEGPT_OPENHANDS_SESSION_SECRET')
        ):
            raise ValueError('FREEGPT_OPENHANDS_SESSION_SECRET is required when login is enabled')
