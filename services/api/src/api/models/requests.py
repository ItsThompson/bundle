"""Auth request schemas."""

from pydantic import BaseModel, EmailStr, Field


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
