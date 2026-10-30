import SwiftUI
import UIKit

/// Oct 29 2026: THE FRONT DOOR, NATIVE. Until now "Ask to join" on the
/// sign-in screen opened the website's /request-access page in Safari. Kade
/// wanted the sight question asked at the door ("when we ask people for
/// phone and email and stuff"), and a native form is also the easier one to
/// fill in with VoiceOver: real labels, the question read as a question, and
/// one choice out of three instead of a wall of checkboxes.
///
/// It sends the same four answers the web form sends, plus `sight`, to the
/// same public doorbell (POST /api/access-request; see AskToJoinRequest for
/// the body). The web page stays one tap away at the bottom, and so does the
/// invite-code sign-up.
struct AskToJoinView: View {
    let client: KadeAPIClient
    let onClose: () -> Void

    @State private var form = AskToJoinRequest()
    @State private var sending = false
    @State private var sent = false
    @State private var message: String?
    @State private var webPage: AskToJoinWebPage?
    @State private var webLoadFailed = false

    private enum Field: Hashable { case name, contact, who, why }
    @FocusState private var typing: Field?
    private enum Spoken: Hashable { case message }
    @AccessibilityFocusState private var a11yFocus: Spoken?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Accounts here are personal invites. Kade reads every request herself, and if she knows you, expect to hear back. Published recordings are free once you have an account, and a donation is never required.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if sent {
                    sentSection
                } else {
                    fields
                    sightSection
                    sendSection
                }

                Section {
                    Button("Have an invite code? Create your account on the web") {
                        webPage = .register
                    }
                    .accessibilityHint("Opens the sign-up page for people Kade has already sent a code.")
                    Button("Use the request page on the web instead") {
                        webPage = .requestAccess
                    }
                    .accessibilityHint("Opens the same request form on kademurdock.com.")
                }
            }
            .navigationTitle("Ask to join")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? "Done" : "Cancel", action: onClose)
                }
            }
            .sheet(item: $webPage) { page in
                SafariView(url: page.url, loadFailed: $webLoadFailed)
                    .ignoresSafeArea()
            }
            .onChange(of: webLoadFailed) { _, failed in
                guard failed else { return }
                webPage = nil
                webLoadFailed = false
                say("Couldn't load the page. Check your connection and try again.")
            }
        }
    }

    // MARK: - The four questions the web form asks

    @ViewBuilder private var fields: some View {
        Section {
            TextField("Your name", text: $form.name)
                .textContentType(.name)
                .submitLabel(.next)
                .focused($typing, equals: .name)
                .onSubmit { typing = .contact }
                .accessibilityLabel("What do people call you?")
        } header: {
            Text("What do people call you?")
                .accessibilityHidden(true) // the field says the same words
        }

        Section {
            TextField("Phone number or email", text: $form.contact)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($typing, equals: .contact)
                .onSubmit { typing = .who }
                .accessibilityLabel("How can Kade reach you? Phone number or email")
        } header: {
            Text("How can Kade reach you?")
                .accessibilityHidden(true) // the field says the same words
        } footer: {
            Text("A phone number or an email address, whichever you'd rather.")
        }

        Section {
            TextField("A little about you", text: $form.whoYouAre, axis: .vertical)
                .lineLimit(3...8)
                .focused($typing, equals: .who)
                .accessibilityLabel("Tell Kade a little about yourself")
        } header: {
            Text("Tell Kade a little about yourself")
                .accessibilityHidden(true) // the field says the same words
        }

        Section {
            TextField("Optional", text: $form.whyHere, axis: .vertical)
                .lineLimit(2...8)
                .focused($typing, equals: .why)
                .accessibilityLabel("What would you like to watch or use? Optional")
        } header: {
            Text("What would you like to watch or use? (optional)")
                .accessibilityHidden(true) // the field says the same words
        }
    }

    // MARK: - The new question

    /// One choice out of three, read as a question. Nothing is picked to
    /// start with, and nothing has to be: no answer sends the same "not said"
    /// as "I'd rather not say". Built as a group of buttons rather than a
    /// Picker with an empty selection, so the chosen one always says
    /// "selected" to VoiceOver and nothing starts out invalid.
    private var sightSection: some View {
        Section {
            ForEach(AskToJoinSight.allCases) { choice in
                let chosen = form.sight == choice
                Button {
                    form.sight = choice
                } label: {
                    HStack {
                        Text(choice.label)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if chosen {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(chosen ? AccessibilityTraits.isSelected : AccessibilityTraits())
            }
        } header: {
            Text("Will you be looking at the screen?")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            Text("This only decides how the characters show up for you. People who watch the screen can see them move and talk on video; everyone hears the same voices. Answering is up to you, and you can change it any time in Settings.")
        }
    }

    // MARK: - Sending

    private var sendSection: some View {
        Section {
            if let message {
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Not sent. \(message)")
                    .accessibilityFocused($a11yFocus, equals: .message)
            }
            Button(action: send) {
                HStack {
                    if sending { ProgressView().padding(.trailing, 4) }
                    Text(sending ? "Sending…" : "Send my request")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(sending)
            .accessibilityHint("Sends your request to Kade. Nothing else happens until she answers.")
        }
    }

    private var sentSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(message ?? "Request sent.")
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if form.contactLooksLikePhone {
                    Text("You gave a phone number, so you'll sign in with that number. If you ever forget your password, choose Forgot your password on the sign-in screen, then Call my phone with a code.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityFocused($a11yFocus, equals: .message)
        } header: {
            Text("Sent")
        }
    }

    private func send() {
        guard !sending else { return }
        typing = nil
        if let missing = form.missing {
            message = missing
            focusMessage()
            return
        }
        sending = true
        message = nil
        let body = form.jsonBody()
        Task {
            var req = client.request(path: "api/access-request", method: "POST", timeout: 20)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            let answer: (sent: Bool, text: String)
            do {
                let (data, http) = try await client.send(req)
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let said = (json?["message"] as? String) ?? (json?["error"] as? String)
                answer = AskToJoinRequest.outcome(status: http.statusCode, serverMessage: said)
            } catch {
                answer = AskToJoinRequest.outcome(status: 0, serverMessage: nil)
            }
            sending = false
            message = answer.text
            if answer.sent { sent = true }
            focusMessage()
        }
    }

    /// Moves VoiceOver to the answer, a beat after the form has redrawn so
    /// the focus lands on the new text rather than the old button. Moving
    /// focus reads it; a separate announcement on top would say it twice.
    private func focusMessage() {
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            a11yFocus = .message
        }
    }

    private func say(_ text: String) {
        // After a request has gone, the "sent" words stay on screen; this
        // is only spoken.
        if sent {
            UIAccessibility.post(notification: .announcement, argument: text)
            return
        }
        message = text
        focusMessage()
    }
}

/// The two web pages this screen can still open.
enum AskToJoinWebPage: String, Identifiable {
    case requestAccess
    case register

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .requestAccess: return URL(string: "https://kademurdock.com/request-access")!
        case .register:      return URL(string: "https://kademurdock.com/register")!
        }
    }
}
