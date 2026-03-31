"""API routes for managing verified LLM models (admin only)."""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from server.email_validation import get_admin_user_id
from server.verified_models.verified_model_models import (
    VerifiedModel,
    VerifiedModelCreate,
    VerifiedModelPage,
    VerifiedModelUpdate,
)
from server.verified_models.verified_model_service import (
    VerifiedModelService,
    verified_model_store_dependency,
)

from openhands.app_server.config import get_db_session
from openhands.server.routes import public
from openhands.utils.llm import get_supported_llm_models

api_router = APIRouter(prefix='/api/admin/verified-models', tags=['Verified Models'])


@api_router.get('')
async def search_verified_models(
    provider: str | None = None,
    page_id: Annotated[
        str | None,
        Query(title='Optional next_page_id from the previously returned page'),
    ] = None,
    limit: Annotated[
        int, Query(title='The max number of results in the page', gt=0, le=100)
    ] = 100,
    user_id: str = Depends(get_admin_user_id),
    verified_model_service: VerifiedModelService = Depends(
        verified_model_store_dependency
    ),
) -> VerifiedModelPage:
    """List all verified models, optionally filtered by provider."""
    # Use SQL-level filtering and pagination
    result = await verified_model_service.search_verified_models(
        provider=provider,
        enabled_only=False,  # Admin sees all models including disabled
        page_id=page_id,
        limit=limit,
    )
    return result


@api_router.post('', status_code=201)
async def create_verified_model(
    data: VerifiedModelCreate,
    user_id: str = Depends(get_admin_user_id),
    verified_model_service: VerifiedModelService = Depends(
        verified_model_store_dependency
    ),
) -> VerifiedModel:
    """Create a new verified model."""
    try:
        model = await verified_model_service.create_verified_model(
            model_name=data.model_name,
            provider=data.provider,
            is_enabled=data.is_enabled,
        )
        return model
    except ValueError as ex:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(ex),
        )


@api_router.put('/{provider}/{model_name:path}')
async def update_verified_model(
    provider: str,
    model_name: str,
    data: VerifiedModelUpdate,
    user_id: str = Depends(get_admin_user_id),
    verified_model_service: VerifiedModelService = Depends(
        verified_model_store_dependency
    ),
) -> VerifiedModel:
    """Update a verified model by provider and model name."""
    model = await verified_model_service.update_verified_model(
        model_name=model_name,
        provider=provider,
        is_enabled=data.is_enabled,
    )
    if not model:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f'Model {provider}/{model_name} not found',
        )
    return model


@api_router.delete('/{provider}/{model_name:path}')
async def delete_verified_model(
    provider: str,
    model_name: str,
    user_id: str = Depends(get_admin_user_id),
    verified_model_service: VerifiedModelService = Depends(
        verified_model_store_dependency
    ),
) -> bool:
    """Delete a verified model by provider and model name."""
    try:
        await verified_model_service.delete_verified_model(
            model_name=model_name, provider=provider
        )
        return True
    except ValueError as ex:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(ex),
        )


async def get_saas_llm_models_dependency(request: Request) -> list[str]:
    """SaaS implementation for the LLM models endpoint."""
    async with get_db_session(request.state, request) as db_session:
        # Prevent circular import
        from openhands.server.shared import config

        verified_model_service = VerifiedModelService(db_session)
        page = await verified_model_service.search_verified_models(enabled_only=True)
        if page.next_page_id:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail='Too many models defined in database',
            )
        verified_models = [f'{m.provider}/{m.model_name}' for m in page.items]
        return get_supported_llm_models(config, verified_models)


async def get_freegpt_llm_models_dependency(request: Request) -> list[str]:
    """FreeGPT implementation for the LLM models endpoint.

    Fetches the user's FreeGPT role from their auth token and filters
    the available models based on role-to-model mapping from the IdP.
    """
    import fnmatch

    from server.auth.constants import ENABLE_FREEGPT_SSO
    from server.auth.freegpt_token_manager import FreeGPTTokenManager

    from openhands.server.shared import config
    from openhands.server.user_auth.user_auth import get_user_auth

    base_models = get_supported_llm_models(config, [])

    if not ENABLE_FREEGPT_SSO:
        return base_models

    try:
        user_auth = await get_user_auth(request)
        freegpt_role = getattr(user_auth, 'freegpt_role', 'user')

        mgr = FreeGPTTokenManager()
        allowed_patterns = await mgr.get_models_for_role(freegpt_role)

        if not allowed_patterns:
            return []

        # Wildcard "*" means all models
        if '*' in allowed_patterns:
            return base_models

        # Filter models by glob patterns
        filtered = []
        for model in base_models:
            # Model names may be "provider/model_name" — check against the model part
            model_short = model.split('/')[-1] if '/' in model else model
            for pattern in allowed_patterns:
                if fnmatch.fnmatch(model_short, pattern) or fnmatch.fnmatch(model, pattern):
                    filtered.append(model)
                    break
        return filtered
    except Exception:
        # If auth fails or IdP is unreachable, return the base model list
        return base_models


# Override the default implementation with SaaS implementation
# This must be called after the app is created in saas_server.py
def override_llm_models_dependency(app):
    """Override the default LLM models implementation with SaaS version."""
    from server.auth.constants import ENABLE_FREEGPT_SSO

    if ENABLE_FREEGPT_SSO:
        app.dependency_overrides[public.get_llm_models_dependency] = (
            get_freegpt_llm_models_dependency
        )
    else:
        app.dependency_overrides[public.get_llm_models_dependency] = (
            get_saas_llm_models_dependency
        )
