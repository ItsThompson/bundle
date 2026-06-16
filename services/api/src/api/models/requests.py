"""Request validation schemas."""

from datetime import datetime

from pydantic import BaseModel, EmailStr, Field, field_validator

from api.models.domain import ArtifactType


class RegisterRequest(BaseModel):
    """Request body for user registration."""

    email: EmailStr
    password: str = Field(min_length=8, max_length=72)


class LoginRequest(BaseModel):
    """Request body for user login."""

    email: EmailStr
    password: str


class RefreshRequest(BaseModel):
    """Request body for token refresh."""

    refresh_token: str


class UpdateEmailRequest(BaseModel):
    """Request body for email update."""

    email: EmailStr


class ChangePasswordRequest(BaseModel):
    """Request body for password change."""

    current_password: str
    new_password: str = Field(min_length=8, max_length=72)


class ArtifactUploadParams(BaseModel):
    """Validated parameters for artifact upload (parsed from Form fields)."""

    type: ArtifactType
    content_text: str | None = Field(None, max_length=50_000)
    created_at: datetime

    @field_validator("content_text")
    @classmethod
    def validate_url_for_links(cls, v: str | None, info) -> str | None:
        """For link artifacts, validate URL scheme and length."""
        if info.data.get("type") == ArtifactType.LINK and v is not None:
            if len(v) > 2048:
                raise ValueError("URL must not exceed 2048 characters")
            if not v.startswith(("http://", "https://")):
                raise ValueError("URL must use http or https scheme")
        return v
