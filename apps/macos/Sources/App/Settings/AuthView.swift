import SwiftUI

/// Authentication view: toggles between login and register forms.
/// Shows logged-in state when authenticated.
struct AuthView: View {
    @ObservedObject var authService: AuthService

    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false

    var body: some View {
        if authService.isAuthenticated {
            loggedInView
        } else {
            authFormView
        }
    }

    // MARK: - Logged In State

    private var loggedInView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            if let user = authService.currentUser {
                Text(user.email)
                    .font(.headline)
            }

            Text("Signed in")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Auth Form (Login / Register)

    private var authFormView: some View {
        VStack(spacing: 16) {
            Text(isRegistering ? "Create Account" : "Sign In")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .disableAutocorrection(true)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(isRegistering ? .newPassword : .password)
            }

            if let error = authService.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: submit) {
                if authService.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(isRegistering ? "Sign Up" : "Sign In")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(authService.isLoading || email.isEmpty || password.isEmpty)

            Button(isRegistering ? "Already have an account? Sign In" : "Don't have an account? Sign Up") {
                isRegistering.toggle()
                authService.errorMessage = nil
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.accentColor)
        }
        .padding(24)
        .frame(width: 300)
    }

    // MARK: - Actions

    private func submit() {
        Task {
            if isRegistering {
                await authService.register(email: email, password: password)
            } else {
                await authService.login(email: email, password: password)
            }

            // Clear password on success
            if authService.isAuthenticated {
                password = ""
            }
        }
    }
}
