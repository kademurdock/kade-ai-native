import SwiftUI

/* ⭐ PART 109 — THE SCREEN APPLE ASKED FOR, AND WHY IT IS A SCREEN AND NOT A LINK.
 *
 * App Review rejected version 2.0 (build 245) on Aug 31 2026 under guidelines
 * 5.1.1(i) Data Collection and 5.1.2(i) Data Use. Their words:
 *
 *   "The app appears to share the user's personal data with a third-party AI
 *    service but the app does not clearly explain what data is sent, identify
 *    who the data is sent to, and ask the user's permission before sharing
 *    the data."
 *
 * And the sentence that decides the shape of the fix:
 *
 *   "Note that only including this information in the app's Terms of Service
 *    or Privacy Policy is not sufficient."
 *
 * So a link to the policy does not close this. Permission has to be asked
 * INSIDE the app, before anything leaves the phone, in words a person can
 * actually read. Their four requirements, and where each one is met here:
 *
 *   1. Disclose what data will be sent          -> the "What gets sent" list
 *   2. Specify who the data is sent to          -> the "Who receives it" list,
 *                                                  by company name, not by
 *                                                  category. "AI model
 *                                                  providers, accessed through
 *                                                  an aggregator" is what the
 *                                                  old privacy policy said and
 *                                                  is almost certainly what got
 *                                                  flagged.
 *   3. Obtain permission BEFORE sending          -> this is a fullScreenCover
 *                                                  presented the moment sign-in
 *                                                  succeeds, with no dismiss
 *                                                  gesture and no skip. Nothing
 *                                                  in the app is reachable
 *                                                  behind it, so no message,
 *                                                  recording, photo or location
 *                                                  can be sent before Agree.
 *   4. Privacy policy covers collection and use  -> kademurdock.com/privacy,
 *                                                  linked below and rewritten
 *                                                  the same day this shipped.
 *
 * ⚠️ ACCURACY IS THE WHOLE POINT. Every company named below was confirmed
 * against the live configuration, not from memory — Kade fact-checked the list
 * herself before this was written. If a provider is ever added, swapped or
 * dropped, THIS FILE AND THE PRIVACY POLICY BOTH CHANGE IN THE SAME COMMIT. A
 * disclosure that has quietly gone stale is worse than none: it is a false
 * statement to every user who reads it, and a second rejection if a reviewer
 * checks.
 *
 * ⚠️ AND THE HONEST ARCHITECTURE, stated the way it actually is rather than the
 * way it flatters us: the app itself only ever talks to Kade's own servers.
 * The AI companies are reached server-side, from her infrastructure, never
 * directly from the phone. That distinction is real and it is NOT a defence —
 * the user's words still end up at those companies, which is exactly what
 * 5.1.2(i) is about — so the copy below says "reaches" and never implies the
 * data stops at kademurdock.com.
 *
 * BLIND-FIRST, because that is who this app is for and a consent screen a
 * screen-reader user cannot navigate is not consent:
 *   - every section is a real VoiceOver heading, so the Headings rotor walks
 *     the screen in one gesture instead of swiping through forty items
 *   - the two lists are single accessibility elements each, read as one
 *     sentence, rather than a dozen separate bullet stops
 *   - the buttons say what they DO ("Agree and continue"), and the decline
 *     path spells out its consequence in its own hint rather than hiding it
 *   - no time limit, no auto-dismiss, no motion, nothing that vanishes
 */

/// What the app sends, who it reaches, and the ask. Presented once per account.
struct DataUseConsentView: View {
    /// The account this consent belongs to. Consent is stored PER USER, not per
    /// device: a shared iPad must not let one person's Agree speak for another.
    let userId: String
    let onAgree: () -> Void
    let onDecline: () -> Void

    @State private var showingPolicy = false

    /// The single source of truth for both lists, so the screen and the
    /// Settings re-read can never drift apart.
    static let whatIsSent = """
        The messages you type. Voice recordings you make when you talk instead \
        of typing. Photos, video and documents you choose to share or ask about. \
        Your location, but only while the app is open and only if you switch \
        Share my location on. And the things you ask a companion to remember.
        """

    static let whoReceivesIt = """
        Your words and recordings go first to Kade-AI's own servers, and from \
        there they reach the companies that do the actual work: Z.AI, \
        OpenRouter, Moonshot AI and DeepSeek write the replies. Deepgram turns \
        your speech into text. Inworld and Fish Audio speak the replies out \
        loud. Google reads photos, video and documents you share, and indexes \
        your saved memories so they can be found again. Tavily searches the web \
        when you ask for research. fal.ai and Black Forest Labs make images and \
        video when you ask for them. Twilio carries phone calls and text \
        messages. Backblaze stores backups and avatars.
        """

    static let promise = """
        Each company gets only what it needs for the job you asked for, and \
        nothing is sold or used to advertise to you. You can read the full \
        policy any time, and you can find this screen again in Settings.
        """

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Kade-AI uses AI services run by other companies. Here is exactly what that means before you start.")
                        .font(.body)

                    section(
                        "What gets sent",
                        Self.whatIsSent,
                        hint: "The kinds of information that leave your phone when you use Kade-AI."
                    )

                    section(
                        "Who receives it",
                        Self.whoReceivesIt,
                        hint: "The companies your information reaches, by name."
                    )

                    section(
                        "What they may do with it",
                        Self.promise,
                        hint: "The limits on how these companies may use your information."
                    )

                    Button {
                        showingPolicy = true
                    } label: {
                        Label("Read the full privacy policy", systemImage: "doc.text")
                    }
                    .accessibilityHint("Opens the complete privacy policy. You can come back here without losing your place.")

                    VStack(spacing: 12) {
                        Button {
                            DataUseConsent.record(for: userId)
                            onAgree()
                        } label: {
                            Text("Agree and continue")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityHint("Agrees to your information being shared with the companies listed above, and opens the app.")

                        Button(role: .cancel) {
                            onDecline()
                        } label: {
                            Text("No thanks, sign me out")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .accessibilityHint("Signs you out without sharing anything. Kade-AI cannot answer you without sending your words to these services, so there is nothing to use until you agree.")
                    }
                    .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("Before you start")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
            .sheet(isPresented: $showingPolicy) {
                SafariView(url: DataUseConsent.policyURL, loadFailed: .constant(false))
                    .ignoresSafeArea()
            }
        }
    }

    /// A heading plus its body, collapsed into ONE VoiceOver stop. Read as a
    /// sentence, not as a heading and then a wall of separate bullet noises.
    @ViewBuilder
    private func section(_ title: String, _ body: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(body)
                .font(.body)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint)
    }
}

/// Where the consent decision lives.
///
/// Per USER, never per device — a family iPad must not let one person's Agree
/// speak for the next person who signs in. Keyed by the LibreChat user id.
///
/// ⚠️ The version number is load-bearing. When the list of companies changes,
/// bump `currentVersion` in the same commit and every account is asked again,
/// because consent to the old list is not consent to the new one. That is the
/// whole reason this is not a bare Bool.
enum DataUseConsent {
    /// Bump when `whatIsSent` or `whoReceivesIt` changes materially.
    static let currentVersion = 1
    static let policyURL = URL(string: "https://kademurdock.com/privacy")!

    private static func key(_ userId: String) -> String { "kadeDataUseConsent.v.\(userId)" }

    static func hasAgreed(userId: String) -> Bool {
        UserDefaults.standard.integer(forKey: key(userId)) >= currentVersion
    }

    static func record(for userId: String) {
        UserDefaults.standard.set(currentVersion, forKey: key(userId))
    }

    /// Only for the Settings re-read to show state honestly; never used to
    /// revoke silently.
    static func clear(userId: String) {
        UserDefaults.standard.removeObject(forKey: key(userId))
    }
}
