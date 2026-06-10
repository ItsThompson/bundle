import SwiftUI

/// Account management section: displays user info, allows email change and password change.
struct AccountView: View {
    @ObservedObject var authService: AuthService
    let artifactCount: Int

    @State private var emailField = ""
    @State private var emailError: String?
    @State private var emailSuccess = false
    @State private var isUpdatingEmail = false

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var passwordError: String?
    @State private var passwordSuccess = false
    @State private var isChangingPassword = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            accountInfoSection
            Divider()
            changeEmailSection
            Divider()
            changePasswordSection
        }
        .padding(.vertical, 8)
        .onAppear {
            emailField = authService.currentUser?.email ?? ""
        }
        .onChange(of: authService.currentUser?.email) {
            if let email = authService.currentUser?.email, !isUpdatingEmail {
                emailField = email
            }
        }
    }

    // MARK: - Account Info

    private var accountInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Account", systemImage: "person.circle")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "Email", value: authService.currentUser?.email ?? "—")
                infoRow(label: "Created", value: formattedCreationDate)
                infoRow(label: "Artifacts", value: "\(artifactCount)")
            }
        }
    }

    private var formattedCreationDate: String {
        guard let date = authService.currentUser?.createdAt else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .font(.subheadline)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.subheadline)
            Spacer()
        }
    }

    // MARK: - Change Email

    private var changeEmailSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Change Email")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 8) {
                TextField("New email", text: $emailField)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .disableAutocorrection(true)
                    .onChange(of: emailField) {
                        emailError = nil
                        emailSuccess = false
                    }

                Button("Update") {
                    updateEmail()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isUpdatingEmail || emailField.isEmpty || emailField == authService.currentUser?.email)
            }

            if let error = emailError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if emailSuccess {
                Text("Email updated successfully")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
    }

    // MARK: - Change Password

    private var changePasswordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Change Password")
                .font(.subheadline)
                .fontWeight(.medium)

            SecureField("Current password", text: $currentPassword)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)

            SecureField("New password", text: $newPassword)
                .textFieldStyle(.roundedBorder)
                .textContentType(.newPassword)

            SecureField("Confirm new password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)
                .textContentType(.newPassword)
                .onChange(of: confirmPassword) {
                    passwordError = nil
                    passwordSuccess = false
                }

            if let error = passwordError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if passwordSuccess {
                Text("Password changed successfully")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            Button("Change Password") {
                changePassword()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
                isChangingPassword
                || currentPassword.isEmpty
                || newPassword.isEmpty
                || confirmPassword.isEmpty
            )
        }
    }

    // MARK: - Actions

    private func updateEmail() {
        isUpdatingEmail = true
        emailError = nil
        emailSuccess = false

        Task {
            let error = await authService.updateEmail(emailField)
            isUpdatingEmail = false
            if let error = error {
                emailError = error
            } else {
                emailSuccess = true
            }
        }
    }

    private func changePassword() {
        isChangingPassword = true
        passwordError = nil
        passwordSuccess = false

        Task {
            let error = await authService.changePassword(
                current: currentPassword,
                new: newPassword,
                confirmation: confirmPassword
            )
            isChangingPassword = false
            if let error = error {
                passwordError = error
            } else {
                passwordSuccess = true
                currentPassword = ""
                newPassword = ""
                confirmPassword = ""
            }
        }
    }
}
