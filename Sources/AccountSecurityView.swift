import SwiftUI
import UIKit

/// Session 26, leftovers item 7 (account management), scoped to what the
/// server actually supports. Two real operations:
///
/// CHANGE PASSWORD -- Oct 2 2026: POST /api/auth/changePassword (signed in,
/// rate limited like the reset route) with the current password and the new
/// one. The server checks the current password, sets the new one, keeps this
/// phone signed in and emails nothing. It answers `{ message }` in plain
/// words, which are said as they are. This replaced a reset-link flow that
/// asked /requestPasswordReset for a link and spent it at once: since Sep 8
/// that route emails the link instead of handing it back, so the old screen
/// failed for everyone.
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

    @State private var currentPassword = ""
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
                SecureField("Current password", text: $currentPassword)
                    .textContentType(.password)
                    .accessibilityLabel("Current password")
                    .accessibilityHint("The password you sign in with now.")
                SecureField("New password", text: $newPassword)
                    .textContentType(.newPassword)
                    .accessibilityLabel("New password")
                    .accessibilityHint("At least 8 characters.")
                SecureField("Confirm new password", text: $confirmPassword)
                    .textContentType(.newPassword)
                    .accessibilityLabel("Confirm new password")
                    .accessibilityHint("Type the new password again.")
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
                .accessibilityHint("Changes it right away. You stay signed in on this phone.")
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

    /// The server's answer: `{ ok, message }` on success, `{ message }` when
    /// nothing changed. Every message is a plain sentence meant to be heard.
    private struct ChangePasswordAnswer: Decodable {
        let message: String?
    }

    private func changePassword() async {
        let current = currentPassword
        let password = newPassword
        guard !current.isEmpty else {
            speakStatus("Type your current password first. Nothing changed.")
            return
        }
        guard password.count >= 8 else {
            speakStatus("The new password needs at least 8 characters. Nothing changed.")
            return
        }
        guard password == confirmPassword else {
            speakStatus("The two new passwords don't match. Nothing changed.")
            return
        }
        guard password != current else {
            speakStatus("The new password is the same as the current one. Nothing changed.")
            return
        }
        guard signedInEmail != nil else {
            speakStatus("Sign in first, then change your password.")
            return
        }
        isChanging = true
        defer { isChanging = false }

        let body = ["currentPassword": current, "newPassword": password]
        var reply = await sendPasswordChange(body)
        // An access token that ran out is renewed once from the sign-in cookie.
        if reply?.status == 401, await auth.refreshAccessToken() {
            reply = await sendPasswordChange(body)
        }
        guard let answer = reply else {
            KadeHaptics.error()
            speakStatus("Couldn't reach the server. Check your connection and try again. Nothing changed.")
            return
        }
        if answer.status == 200 {
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
            KadeHaptics.success()
            speakStatus("Password changed. Use the new one next time you sign in.")
            return
        }
        let said = ((try? JSONDecoder().decode(ChangePasswordAnswer.self, from: answer.data))?.message ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message: String
        switch answer.status {
        case 401:
            message = "Your sign-in has run out. Sign out, sign back in, then try again. Nothing changed."
        case 404:
            message = "The website can't change passwords from the app yet. Nothing changed."
        case 429:
            message = "Too many tries in a row. Wait a few minutes, then try again. Nothing changed."
        default:
            message = said.isEmpty ? "The password could not be changed. Nothing changed." : said
        }
        KadeHaptics.error()
        speakStatus(message)
    }

    /// One try at POST api/auth/changePassword. Nil when the site could not
    /// be reached.
    private func sendPasswordChange(_ body: [String: String]) async -> (data: Data, status: Int)? {
        var req = apiClient.request(path: "api/auth/changePassword", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, http) = try? await apiClient.send(req) else { return nil }
        return (data: data, status: http.statusCode)
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
