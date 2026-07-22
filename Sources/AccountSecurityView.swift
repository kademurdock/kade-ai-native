import SwiftUI
import UIKit

/// Session 26, leftovers item 7 (account management), scoped to what the
/// server actually supports. Two real operations:
///
/// CHANGE PASSWORD -- LibreChat has no authenticated change-password
/// route; it has the reset flow. On THIS deployment there is deliberately
/// no email service, and `requestPasswordReset` (AuthService.js) returns
/// the reset `link` DIRECTLY in the response body when email is
/// unconfigured -- so the app can run the whole flow in-app: request a
/// reset for the signed-in user's own email, parse `token` + `userId` off
/// the returned link, then POST /api/auth/resetPassword. The token lives
/// 900 seconds; this flow uses it within one breath of minting it.
///
/// DELETE ACCOUNT -- DELETE /api/user/delete (requireJwtAuth +
/// canDeleteAccount; ALLOW_ACCOUNT_DELETION defaults on). Irreversible
/// server-side, so it is DOUBLE-confirmed here, both alerts spoken, the
/// second one naming exactly what dies. On success the app signs out.
///
/// CHANGE EMAIL is not offered: no such route exists server-side. The
/// footer says so plainly instead of hiding the row.
struct AccountSecurityView: View {
    let apiClient: KadeAPIClient
    @EnvironmentObject private var auth: AuthService

    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isChanging = false
    @State private var statusMessage: String?

    @State private var confirmingDelete = false
    @State private var confirmingDeleteFinal = false
    @State private var isDeleting = false

    @AccessibilityFocusState private var focusStatus: Bool

    private var signedInEmail: String? {
        if case .signedIn(let user) = auth.state { return user.email }
        return nil
    }

    var body: some View {
        Form {
            Section {
                SecureField("New password", text: $newPassword)
                    .textContentType(.newPassword)
                    .accessibilityHint("At least 8 characters.")
                SecureField("Confirm new password", text: $confirmPassword)
                    .textContentType(.newPassword)
                    .accessibilityHint("Type the same password again.")
                Button {
                    Task { await changePassword() }
                } label: {
                    if isChanging {
                        ProgressView()
                            .accessibilityLabel("Changing your password")
                    } else {
                        Text("Change password")
                    }
                }
                .disabled(isChanging)
                .accessibilityHint("Sets the new password right away. You stay signed in on this phone.")
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityFocused($focusStatus)
                }
            } header: {
                Text("Password")
            } footer: {
                Text("Takes effect immediately — use the new password next time you sign in anywhere. Changing your sign-in email isn't available.")
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    if isDeleting {
                        ProgressView()
                            .accessibilityLabel("Deleting this account")
                    } else {
                        Text("Delete this account")
                    }
                }
                .disabled(isDeleting)
                .accessibilityHint("Permanently deletes the account and everything in it. Asks twice before doing anything.")
            } header: {
                Text("Danger zone")
            } footer: {
                Text("Deleting removes the account, every conversation, and everything made with it, for good. There is no undo.")
            }
        }
        .navigationTitle("Password & Account")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete this account?", isPresented: $confirmingDelete) {
            Button("Keep my account", role: .cancel) {}
            Button("Continue to the last step", role: .destructive) {
                confirmingDeleteFinal = true
            }
        } message: {
            Text("This is the first of two confirmations. Nothing has been deleted yet.")
        }
        .alert("Really delete everything?", isPresented: $confirmingDeleteFinal) {
            Button("Keep my account", role: .cancel) {}
            Button("Delete it all forever", role: .destructive) {
                Task { await deleteAccount() }
            }
        } message: {
            Text("Last chance: the account, every conversation, every creation — gone for good, no undo.")
        }
    }

    // MARK: - Password change

    private struct ResetRequestResponse: Decodable {
        let link: String?
        let message: String?
    }

    private func changePassword() async {
        let password = newPassword
        guard password.count >= 8 else {
            speakStatus("Passwords need at least 8 characters. Nothing changed.")
            return
        }
        guard password == confirmPassword else {
            speakStatus("The two passwords don't match. Nothing changed.")
            return
        }
        guard let email = signedInEmail else {
            speakStatus("You need to be signed in to change the password.")
            return
        }
        isChanging = true
        defer { isChanging = false }

        // Step 1: mint a reset token for OUR OWN email. With no email
        // service configured the link comes straight back in the response
        // (verified against AuthService.js's `return { link }` branch).
        var req = apiClient.request(path: "api/auth/requestPasswordReset", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email])
        guard let (data, http) = try? await apiClient.send(req) else {
            speakStatus("Couldn't reach the server. Check your connection and try again.")
            return
        }
        if http.statusCode == 429 {
            speakStatus("Too many tries in a row. Wait a few minutes, then try again.")
            return
        }
        guard http.statusCode == 200,
              let parsed = try? JSONDecoder().decode(ResetRequestResponse.self, from: data),
              let link = parsed.link,
              let comps = URLComponents(string: link),
              let token = comps.queryItems?.first(where: { $0.name == "token" })?.value,
              let userId = comps.queryItems?.first(where: { $0.name == "userId" })?.value else {
            speakStatus("The server didn't hand back a reset link — it may have email delivery turned on now. Nothing changed.")
            return
        }

        // Step 2: spend the token on the new password immediately.
        var resetReq = apiClient.request(path: "api/auth/resetPassword", method: "POST")
        resetReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        resetReq.httpBody = try? JSONSerialization.data(withJSONObject: [
            "userId": userId,
            "token": token,
            "password": password,
        ])
        guard let (_, resetHttp) = try? await apiClient.send(resetReq), resetHttp.statusCode == 200 else {
            speakStatus("Couldn't set the new password. Nothing changed — try again.")
            return
        }
        newPassword = ""
        confirmPassword = ""
        KadeHaptics.success()
        speakStatus("Password changed. Use the new one next time you sign in.")
    }

    private func speakStatus(_ message: String) {
        statusMessage = message
        UIAccessibility.post(notification: .announcement, argument: message)
        focusStatus = true
    }

    // MARK: - Delete

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        let req = apiClient.request(path: "api/user/delete", method: "DELETE", authorized: true)
        guard let (_, http) = try? await apiClient.send(req), (200...204).contains(http.statusCode) else {
            speakStatus("Couldn't delete the account. Nothing was removed — try again.")
            KadeHaptics.error()
            return
        }
        UIAccessibility.post(notification: .announcement, argument: "Account deleted. Signing out.")
        auth.signOut()
    }
}
