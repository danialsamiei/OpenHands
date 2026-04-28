from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

from pydantic import TypeAdapter

from openhands.core.config.openhands_config import OpenHandsConfig
from openhands.storage import get_file_store
from openhands.storage.conversation.conversation_store import ConversationStore
from openhands.storage.data_models.conversation_metadata import ConversationMetadata
from openhands.storage.data_models.conversation_metadata_result_set import (
    ConversationMetadataResultSet,
)
from openhands.storage.data_models.secrets import Secrets
from openhands.storage.data_models.settings import Settings
from openhands.storage.files import FileStore
from openhands.storage.locations import (
    CONVERSATION_BASE_DIR,
    get_conversation_dir,
    get_conversation_metadata_filename,
)
from openhands.storage.secrets.secrets_store import SecretsStore
from openhands.storage.settings.settings_store import SettingsStore
from openhands.utils.async_utils import call_sync_from_async
from openhands.utils.search_utils import offset_to_page_id, page_id_to_offset

from openhands.qadr.session import DEFAULT_LANGUAGE

conversation_metadata_type_adapter = TypeAdapter(ConversationMetadata)

_SAFE_USER_ID_RE = re.compile(r'[^a-zA-Z0-9._-]+')


def sanitize_user_id(user_id: str | None) -> str:
    if not user_id:
        return 'root'
    cleaned = _SAFE_USER_ID_RE.sub('_', user_id).strip('._-')
    return cleaned or 'root'


def _build_file_store(config: OpenHandsConfig) -> FileStore:
    return get_file_store(
        file_store_type=config.file_store,
        file_store_path=config.file_store_path,
        file_store_web_hook_url=config.file_store_web_hook_url,
        file_store_web_hook_headers=config.file_store_web_hook_headers,
        file_store_web_hook_batch=config.file_store_web_hook_batch,
    )


def _user_path(user_id: str | None, relative_path: str) -> str:
    prefix = f'users/{sanitize_user_id(user_id)}'
    return str(Path(prefix) / relative_path).replace('\\', '/')


def _user_conversation_path(user_id: str | None, conversation_id: str | None = None) -> str:
    if user_id is None:
        if conversation_id:
            return get_conversation_dir(conversation_id).rstrip('/')
        return CONVERSATION_BASE_DIR

    safe_user_id = sanitize_user_id(user_id)
    if conversation_id:
        return get_conversation_dir(conversation_id, safe_user_id).rstrip('/')
    return f'users/{safe_user_id}/conversations'


def _apply_settings_defaults(settings: Settings | None) -> Settings | None:
    if settings is None:
        return None
    settings.v1_enabled = True
    if not settings.language:
        settings.language = DEFAULT_LANGUAGE
    return settings


@dataclass
class QadrUserSettingsStore(SettingsStore):
    file_store: FileStore
    user_id: str | None
    path: str = 'settings.json'

    async def load(self) -> Settings | None:
        try:
            json_str = await call_sync_from_async(
                self.file_store.read,
                _user_path(self.user_id, self.path),
            )
            settings = Settings(**json.loads(json_str))
            return _apply_settings_defaults(settings)
        except FileNotFoundError:
            pass

        try:
            json_str = await call_sync_from_async(self.file_store.read, self.path)
            settings = Settings(**json.loads(json_str))
            return _apply_settings_defaults(settings)
        except FileNotFoundError:
            pass

        return _apply_settings_defaults(Settings.from_config())

    async def store(self, settings: Settings) -> None:
        json_str = settings.model_dump_json(context={'expose_secrets': True})
        await call_sync_from_async(
            self.file_store.write,
            _user_path(self.user_id, self.path),
            json_str,
        )

    @classmethod
    async def get_instance(
        cls, config: OpenHandsConfig, user_id: str | None
    ) -> QadrUserSettingsStore:
        return QadrUserSettingsStore(_build_file_store(config), user_id)


@dataclass
class QadrUserSecretsStore(SecretsStore):
    file_store: FileStore
    user_id: str | None
    path: str = 'secrets.json'

    async def load(self) -> Secrets | None:
        try:
            json_str = await call_sync_from_async(
                self.file_store.read,
                _user_path(self.user_id, self.path),
            )
            kwargs = json.loads(json_str)
            provider_tokens = {
                k: v
                for k, v in (kwargs.get('provider_tokens') or {}).items()
                if v.get('token')
            }
            kwargs['provider_tokens'] = provider_tokens
            return Secrets(**kwargs)
        except FileNotFoundError:
            return None

    async def store(self, secrets: Secrets) -> None:
        json_str = secrets.model_dump_json(context={'expose_secrets': True})
        await call_sync_from_async(
            self.file_store.write,
            _user_path(self.user_id, self.path),
            json_str,
        )

    @classmethod
    async def get_instance(
        cls, config: OpenHandsConfig, user_id: str | None
    ) -> QadrUserSecretsStore:
        return QadrUserSecretsStore(_build_file_store(config), user_id)


@dataclass
class QadrUserConversationStore(ConversationStore):
    file_store: FileStore
    user_id: str | None

    def get_conversation_metadata_dir(self) -> str:
        return _user_conversation_path(self.user_id)

    def get_conversation_metadata_filename(self, conversation_id: str) -> str:
        if self.user_id is None:
            return get_conversation_metadata_filename(conversation_id)
        return get_conversation_metadata_filename(
            conversation_id,
            sanitize_user_id(self.user_id),
        )

    async def save_metadata(self, metadata: ConversationMetadata) -> None:
        json_str = conversation_metadata_type_adapter.dump_json(metadata)
        await call_sync_from_async(
            self.file_store.write,
            self.get_conversation_metadata_filename(metadata.conversation_id),
            json_str,
        )

    async def get_metadata(self, conversation_id: str) -> ConversationMetadata:
        path = self.get_conversation_metadata_filename(conversation_id)
        json_str = await call_sync_from_async(self.file_store.read, path)
        json_obj = json.loads(json_str)
        if 'created_at' not in json_obj:
            raise FileNotFoundError(path)
        if 'github_user_id' in json_obj:
            json_obj.pop('github_user_id')
        return conversation_metadata_type_adapter.validate_python(json_obj)

    async def delete_metadata(self, conversation_id: str) -> None:
        path = str(Path(self.get_conversation_metadata_filename(conversation_id)).parent)
        await call_sync_from_async(self.file_store.delete, path)

    async def exists(self, conversation_id: str) -> bool:
        try:
            await call_sync_from_async(
                self.file_store.read,
                self.get_conversation_metadata_filename(conversation_id),
            )
            return True
        except FileNotFoundError:
            return False

    async def search(
        self,
        page_id: str | None = None,
        limit: int = 20,
    ) -> ConversationMetadataResultSet:
        metadata_dir = self.get_conversation_metadata_dir()
        try:
            conversation_ids = [
                Path(path).name
                for path in self.file_store.list(metadata_dir)
                if not Path(path).name.startswith('.')
            ]
        except FileNotFoundError:
            return ConversationMetadataResultSet([])

        num_conversations = len(conversation_ids)
        start = page_id_to_offset(page_id)
        end = min(limit + start, num_conversations)
        conversations: list[ConversationMetadata] = []

        for conversation_id in conversation_ids:
            try:
                conversations.append(await self.get_metadata(conversation_id))
            except Exception:
                continue

        conversations.sort(key=_sort_key, reverse=True)
        conversations = conversations[start:end]
        next_page_id = offset_to_page_id(end, end < num_conversations)
        return ConversationMetadataResultSet(conversations, next_page_id)

    @classmethod
    async def get_instance(
        cls, config: OpenHandsConfig, user_id: str | None
    ) -> QadrUserConversationStore:
        return QadrUserConversationStore(_build_file_store(config), user_id)


def _sort_key(conversation: ConversationMetadata) -> str:
    created_at = conversation.created_at
    if created_at:
        return created_at.isoformat()
    return ''
