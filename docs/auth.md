# Auth System

## Overview

Authentication uses JWT Bearer tokens. The backend issues access and refresh tokens, the macOS app stores them in macOS Keychain, and the `APIClient` handles automatic refresh on 401.

Canonical sources:
- Backend auth service: `services/api/src/api/services/auth_service.py`
- Auth middleware: `services/api/src/api/middleware/auth.py`
- Auth router: `services/api/src/api/routers/auth.py`
- macOS auth service: `apps/macos/Sources/App/Networking/AuthService.swift`
- Token storage: `apps/macos/Sources/App/Storage/KeychainManager.swift`

## Token Architecture

| Token | TTL | Storage (client) | Delivery |
|-------|-----|-------------------|----------|
| Access token | 15 minutes | macOS Keychain | `Authorization: Bearer` header |
| Refresh token | 7 days | macOS Keychain | POST body to `/api/auth/refresh` |

### Access Token Claims

| Claim | Value |
|-------|-------|
| `sub` | User ID (UUID string) |
| `iat` | Issued-at (Unix timestamp) |
| `exp` | Expiration (Unix timestamp) |
| `type` | `"access"` |

### Refresh Token Claims

| Claim | Value |
|-------|-------|
| `sub` | User ID (UUID string) |
| `jti` | Unique token ID (UUID, for blacklisting) |
| `iat` | Issued-at (Unix timestamp) |
| `exp` | Expiration (Unix timestamp) |
| `type` | `"refresh"` |

## Token Refresh Flow

1. `APIClient` sends request with access token
2. Backend returns 401 (expired)
3. `APIClient` automatically calls `POST /api/auth/refresh` with refresh token
4. Backend blacklists old refresh token, issues new pair
5. `APIClient` saves new tokens to Keychain, retries original request
6. If refresh also fails: tokens cleared, `sessionExpired` error raised

This is handled transparently in `apps/macos/Sources/App/Networking/APIClient.swift`.

## Session Revocation

- `tokens_revoked_at` column on `auth.users`: any access token with `iat` before this timestamp is rejected
- Password change sets `tokens_revoked_at = now()`, invalidating all other sessions
- Current session receives fresh tokens after password change

## Password Requirements

- Length: 8-72 characters
- Must contain: 1 uppercase, 1 lowercase, 1 digit
- Validated on both client (Swift) and server (Python)
- Hashed with bcrypt (cost factor configurable via `BCRYPT_COST` env var)

## Rate Limiting

Login endpoint is rate-limited per IP: 10 attempts per 60-second window. Exceeding returns 429.

## Session Restoration

On app launch, `AuthService.restoreSession()` attempts to validate stored tokens by calling `GET /api/auth/me`. If tokens are invalid/expired beyond refresh, they are cleared and the user is shown the login view.
