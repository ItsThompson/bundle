"""Integration tests for the auth endpoints with a real database."""

from typing import Any

from fastapi.testclient import TestClient


class TestRegister:
    """Test POST /api/auth/register."""

    def test_register_success(self, client: TestClient) -> None:
        """Successful registration returns user and tokens."""
        response = client.post(
            "/api/auth/register",
            json={"email": "newuser@example.com", "password": "ValidPass1"},
        )
        assert response.status_code == 201
        data = response.json()

        assert data["user"]["email"] == "newuser@example.com"
        assert "id" in data["user"]
        assert "access_token" in data
        assert "refresh_token" in data

    def test_register_duplicate_email(self, client: TestClient) -> None:
        """Registering with existing email returns 409."""
        client.post(
            "/api/auth/register",
            json={"email": "dupe@example.com", "password": "ValidPass1"},
        )
        response = client.post(
            "/api/auth/register",
            json={"email": "dupe@example.com", "password": "ValidPass2"},
        )
        assert response.status_code == 409
        assert "already registered" in response.json()["detail"]

    def test_register_weak_password(self, client: TestClient) -> None:
        """Registration with weak password returns 422."""
        response = client.post(
            "/api/auth/register",
            json={"email": "weak@example.com", "password": "nodigit"},
        )
        assert response.status_code == 422

    def test_register_invalid_email(self, client: TestClient) -> None:
        """Registration with invalid email returns 422."""
        response = client.post(
            "/api/auth/register",
            json={"email": "not-an-email", "password": "ValidPass1"},
        )
        assert response.status_code == 422


class TestLogin:
    """Test POST /api/auth/login."""

    def test_login_success(
        self, client: TestClient, registered_user: dict[str, Any]
    ) -> None:
        """Login with correct credentials returns tokens."""
        response = client.post(
            "/api/auth/login",
            json={"email": "test@example.com", "password": "TestPass1"},
        )
        assert response.status_code == 200
        data = response.json()

        assert data["user"]["email"] == "test@example.com"
        assert "access_token" in data
        assert "refresh_token" in data

    def test_login_wrong_password(
        self, client: TestClient, registered_user: dict[str, Any]
    ) -> None:
        """Login with wrong password returns 401 with generic message."""
        response = client.post(
            "/api/auth/login",
            json={"email": "test@example.com", "password": "WrongPass1"},
        )
        assert response.status_code == 401
        assert response.json()["detail"] == "Invalid credentials"

    def test_login_nonexistent_email(self, client: TestClient) -> None:
        """Login with non-existent email returns same 401 (no email leak)."""
        response = client.post(
            "/api/auth/login",
            json={"email": "ghost@example.com", "password": "TestPass1"},
        )
        assert response.status_code == 401
        assert response.json()["detail"] == "Invalid credentials"

    def test_login_rate_limit(
        self, client: TestClient, registered_user: dict[str, Any]
    ) -> None:
        """Exceeding rate limit returns 429."""
        # Clear rate limiter state for this test
        from api.dependencies import _rate_limiter

        _rate_limiter._attempts.clear()

        # Make 10 attempts (limit)
        for _ in range(10):
            client.post(
                "/api/auth/login",
                json={"email": "test@example.com", "password": "WrongPass1"},
            )

        # 11th attempt should be rate limited
        response = client.post(
            "/api/auth/login",
            json={"email": "test@example.com", "password": "TestPass1"},
        )
        assert response.status_code == 429
        assert "Rate limit exceeded" in response.json()["detail"]


class TestRefresh:
    """Test POST /api/auth/refresh."""

    def test_refresh_success(
        self, client: TestClient, registered_user: dict[str, Any]
    ) -> None:
        """Valid refresh token returns new token pair."""
        response = client.post(
            "/api/auth/refresh",
            json={"refresh_token": registered_user["refresh_token"]},
        )
        assert response.status_code == 200
        data = response.json()

        assert "access_token" in data
        assert "refresh_token" in data
        # New tokens should differ from the original
        assert data["refresh_token"] != registered_user["refresh_token"]

    def test_refresh_blacklists_old_token(
        self, client: TestClient, registered_user: dict[str, Any]
    ) -> None:
        """Used refresh token cannot be reused (blacklisted)."""
        # First refresh succeeds
        client.post(
            "/api/auth/refresh",
            json={"refresh_token": registered_user["refresh_token"]},
        )
        # Second refresh with same token fails
        response = client.post(
            "/api/auth/refresh",
            json={"refresh_token": registered_user["refresh_token"]},
        )
        assert response.status_code == 401
        assert "revoked" in response.json()["detail"]

    def test_refresh_invalid_token(self, client: TestClient) -> None:
        """Invalid refresh token returns 401."""
        response = client.post(
            "/api/auth/refresh",
            json={"refresh_token": "invalid.token.here"},
        )
        assert response.status_code == 401


class TestLogout:
    """Test POST /api/auth/logout."""

    def test_logout_success(
        self,
        client: TestClient,
        registered_user: dict[str, Any],
        auth_headers: dict[str, str],
    ) -> None:
        """Logout blacklists the refresh token."""
        response = client.post(
            "/api/auth/logout",
            json={"refresh_token": registered_user["refresh_token"]},
            headers=auth_headers,
        )
        assert response.status_code == 200
        assert "Logged out" in response.json()["message"]

        # Refresh should fail now
        refresh_response = client.post(
            "/api/auth/refresh",
            json={"refresh_token": registered_user["refresh_token"]},
        )
        assert refresh_response.status_code == 401

    def test_logout_requires_auth(self, client: TestClient) -> None:
        """Logout without auth header returns 401 (no credentials)."""
        response = client.post(
            "/api/auth/logout",
            json={"refresh_token": "some-token"},
        )
        assert response.status_code == 401


class TestGetMe:
    """Test GET /api/auth/me."""

    def test_get_me_success(
        self,
        client: TestClient,
        registered_user: dict[str, Any],
        auth_headers: dict[str, str],
    ) -> None:
        """Authenticated user gets their profile."""
        response = client.get("/api/auth/me", headers=auth_headers)
        assert response.status_code == 200
        data = response.json()

        assert data["email"] == "test@example.com"
        assert "id" in data
        assert "created_at" in data

    def test_get_me_no_auth(self, client: TestClient) -> None:
        """No auth header returns 401 (no credentials provided)."""
        response = client.get("/api/auth/me")
        assert response.status_code == 401

    def test_get_me_invalid_token(self, client: TestClient) -> None:
        """Invalid token returns 401."""
        response = client.get(
            "/api/auth/me",
            headers={"Authorization": "Bearer invalid.token.here"},
        )
        assert response.status_code == 401


class TestUpdateEmail:
    """Test PUT /api/auth/me."""

    def test_update_email_success(
        self,
        client: TestClient,
        registered_user: dict[str, Any],
        auth_headers: dict[str, str],
    ) -> None:
        """Authenticated user can update their email."""
        response = client.put(
            "/api/auth/me",
            json={"email": "newemail@example.com"},
            headers=auth_headers,
        )
        assert response.status_code == 200
        assert response.json()["email"] == "newemail@example.com"

    def test_update_email_duplicate(
        self,
        client: TestClient,
        registered_user: dict[str, Any],
        auth_headers: dict[str, str],
    ) -> None:
        """Updating to an existing email returns 409."""
        # Register another user
        client.post(
            "/api/auth/register",
            json={"email": "taken@example.com", "password": "ValidPass1"},
        )
        # Try to update to that email
        response = client.put(
            "/api/auth/me",
            json={"email": "taken@example.com"},
            headers=auth_headers,
        )
        assert response.status_code == 409


class TestChangePassword:
    """Test POST /api/auth/me/password."""

    def test_change_password_success(
        self,
        client: TestClient,
        registered_user: dict[str, Any],
        auth_headers: dict[str, str],
    ) -> None:
        """Password change succeeds, returns new tokens, and revokes old sessions."""
        import time

        time.sleep(1.1)  # Ensure revocation timestamp is in a later second

        response = client.post(
            "/api/auth/me/password",
            json={"current_password": "TestPass1", "new_password": "NewPass1x"},
            headers=auth_headers,
        )
        assert response.status_code == 200
        data = response.json()

        # Returns new tokens for the current device
        assert "access_token" in data
        assert "refresh_token" in data
        assert data["user"]["email"] == "test@example.com"

        # New tokens work
        new_headers = {"Authorization": f"Bearer {data['access_token']}"}
        me_response = client.get("/api/auth/me", headers=new_headers)
        assert me_response.status_code == 200

        # Login with new password should work
        login_response = client.post(
            "/api/auth/login",
            json={"email": "test@example.com", "password": "NewPass1x"},
        )
        assert login_response.status_code == 200

    def test_change_password_wrong_current(
        self,
        client: TestClient,
        registered_user: dict[str, Any],
        auth_headers: dict[str, str],
    ) -> None:
        """Wrong current password returns 401."""
        response = client.post(
            "/api/auth/me/password",
            json={"current_password": "WrongPass1", "new_password": "NewPass1x"},
            headers=auth_headers,
        )
        assert response.status_code == 401
        assert "incorrect" in response.json()["detail"].lower()

    def test_change_password_weak_new(
        self,
        client: TestClient,
        registered_user: dict[str, Any],
        auth_headers: dict[str, str],
    ) -> None:
        """Weak new password returns 422."""
        response = client.post(
            "/api/auth/me/password",
            json={"current_password": "TestPass1", "new_password": "weak"},
            headers=auth_headers,
        )
        assert response.status_code == 422

    def test_old_token_rejected_after_password_change(
        self,
        client: TestClient,
        registered_user: dict[str, Any],
        auth_headers: dict[str, str],
    ) -> None:
        """Access token issued before password change is rejected.

        A small sleep is needed because JWT 'iat' uses integer seconds and
        the revocation check compares at the same precision. In production,
        login and password change are always seconds apart.
        """
        import time

        time.sleep(1.1)

        # Change password
        client.post(
            "/api/auth/me/password",
            json={"current_password": "TestPass1", "new_password": "NewPass1x"},
            headers=auth_headers,
        )

        # Old token should be rejected
        response = client.get("/api/auth/me", headers=auth_headers)
        assert response.status_code == 401

    def test_old_refresh_token_rejected_after_password_change(
        self,
        client: TestClient,
        registered_user: dict[str, Any],
        auth_headers: dict[str, str],
    ) -> None:
        """Refresh token issued before password change returns 401.

        After password change, a compromised device cannot use a pre-change
        refresh token to obtain new access tokens.
        """
        import time

        time.sleep(1.1)

        # Change password
        client.post(
            "/api/auth/me/password",
            json={"current_password": "TestPass1", "new_password": "NewPass1x"},
            headers=auth_headers,
        )

        # Old refresh token should be rejected
        response = client.post(
            "/api/auth/refresh",
            json={"refresh_token": registered_user["refresh_token"]},
        )
        assert response.status_code == 401
        assert "revoked" in response.json()["detail"].lower()

    def test_new_tokens_work_after_password_change(
        self,
        client: TestClient,
        registered_user: dict[str, Any],
        auth_headers: dict[str, str],
    ) -> None:
        """Tokens issued after password change are accepted normally."""
        import time

        time.sleep(1.1)

        # Change password: returns new tokens
        response = client.post(
            "/api/auth/me/password",
            json={"current_password": "TestPass1", "new_password": "NewPass1x"},
            headers=auth_headers,
        )
        assert response.status_code == 200
        data = response.json()

        # New access token works
        new_headers = {"Authorization": f"Bearer {data['access_token']}"}
        me_response = client.get("/api/auth/me", headers=new_headers)
        assert me_response.status_code == 200

        # New refresh token works
        refresh_response = client.post(
            "/api/auth/refresh",
            json={"refresh_token": data["refresh_token"]},
        )
        assert refresh_response.status_code == 200
        assert "access_token" in refresh_response.json()
