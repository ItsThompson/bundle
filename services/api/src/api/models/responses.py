"""Auth response schemas."""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class UserResponse(BaseModel):
    """Public user profile."""

    id: UUID
    email: str
    created_at: datetime
    updated_at: datetime


class AuthResponse(BaseModel):
    """Authentication response with user and tokens."""

    user: UserResponse
    access_token: str
    refresh_token: str


class TokenResponse(BaseModel):
    """Token pair response (used for refresh)."""

    access_token: str
    refresh_token: str


class MessageResponse(BaseModel):
    """Simple message response."""

    message: str
