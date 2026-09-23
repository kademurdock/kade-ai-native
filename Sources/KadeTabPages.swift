import SwiftUI

// MARK: - Sep 23 2026 redesign: the tab pages
//
// The old Home held 23 buttons under one title, two Backs behind the chat the
// app opens into. Its contents now live on the five tabs:
//   Talk     Spotter first (her standing rule), Talk to your main character,
//            Describe and Transcribe, then the conversation list itself.
//   Library  the Library (ReadingRoomView), unchanged as a destination.
//   Create   Sound Booth, My Creations, Wall of Fame, Agent Builder, Prompts.
//   Play     The Parlor, Kade's Clubhouse, Debate Room, Matchmaker, Marketplace.
//   More     account, search, Alerts / Announcements / Agent work with "new"
//            badges, Bookmarks, Settings, Help, feedback, web, Admin, Sign out.
//
// Every spoken label and hint below is carried over from the old Home word for
// word unless the redesign changed it on purpose (B1 captions are visible-only;
// B2 says "character"; B11 adds "N new").

// MARK: - Talk

/// The first rows of the Talk tab's conversation list (ConversationListView
/// renders this as its first section). One row holding its own buttons, each a
/// custom-styled Button so a List row can never merge their taps.
struct TalkHeader: View {
    @Environment(\.kadeNavigation) private var nav
    @EnvironmentObject private var agentsService: AgentsService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KadeWhatsNewCard()

            Button {
                // Session 23 garnish kept: the one big action gets the one
                // medium tap, gated like every haptic in the app.
                KadeHaptics.press()
                nav.callSpotter()
            } label: {
                Label("Call your Spotter", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KadeHeroButtonStyle())
            .accessibilityLabel("Call your Spotter")
            .accessibilityHint("Starts a live call with your Spotter, who sees through your camera, straight away, without picking anyone first.")

            Button {
                nav.startChat(nil)
            } label: {
                HStack(spacing: 12) {
                    KadeCharacterFace(
                        agentID: DefaultAgentStore.resolveId(in: agentsService.agents),
                        name: DefaultAgentStore.displayName,
                        size: 44
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Talk to \(DefaultAgentStore.displayName)")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Start a new chat")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(KadeCardButtonStyle())
            .accessibilityLabel("Talk to \(DefaultAgentStore.displayName)")
            .accessibilityHint("Opens a new conversation with your main character.")

            KadeToolRow {
                Button { nav.open(.describe) } label: {
                    Label("Describe", systemImage: "plus.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KadeCardButtonStyle())
                .labelStyle(KadeCaptionedTileLabelStyle(tint: .teal, caption: "Photos, videos, papers"))
                .accessibilityLabel("Describe a photo, video, or document")
                .accessibilityHint("Take or choose a photo or video, or pick a document, and get it described or read back to you.")

                Button { nav.open(.transcribe) } label: {
                    Label("Transcribe", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KadeCardButtonStyle())
                .labelStyle(KadeCaptionedTileLabelStyle(tint: .purple, caption: "Your voice into text"))
                .accessibilityLabel("Transcribe a voice memo")
                .accessibilityHint("Records what you say and turns it into text you can edit, tidy up and share.")
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }
}

// MARK: - Create

struct CreateHomeView: View {
    @Environment(\.kadeNavigation) private var nav

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                KadePaintedHeader(imageName: "HeaderCreate", symbol: "wand.and.stars", tint: .purple)

                /* Part 120's Sound Booth card, unchanged by ear. */
                Button { nav.open(.soundBooth) } label: {
                    Label("Sound Booth", systemImage: "mic.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KadeCardButtonStyle())
                .labelStyle(KadeRowLabelStyle(tint: .indigo, caption: "Songs, scenes with voices, sound effects"))
                .accessibilityLabel("The Sound Booth")
                .accessibilityHint("Write something and have it performed: a song, a scene with several voices, music and sound effects, or your words read in a voice.")

                KadeToolRow {
                    kadeTile("My Creations", caption: "Everything you've made", spoken: "My Creations", icon: "photo.stack", tint: .yellow, hint: "Every picture, video, and song you've made — play them, save them to Photos, or put them on the family Wall of Fame.", route: .myCreations)
                    kadeTile("Wall of Fame", caption: "What the family shared", spoken: "Wall of Fame", icon: "trophy", tint: .brown, hint: "Creations the whole family chose to share, newest first.", route: .wallOfFame)
                }
                KadeToolRow {
                    kadeTile("Agent Builder", caption: "Make your own character", spoken: "Agent Builder", icon: "person.crop.circle.badge.plus", tint: .cyan, hint: "Create or edit your own characters.", route: .agentBuilder)
                    kadeTile("Prompts", caption: "Saved things to say", spoken: "The Prompt Library", icon: "text.badge.star", tint: .green, hint: "Saved prompts you can drop into a fresh chat pre-typed, plus a form to save new ones.", route: .prompts)
                }
            }
            .padding()
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Create")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func kadeTile(_ title: String, caption: String, spoken: String, icon: String, tint: Color, hint: String, route: HomeRoute) -> some View {
        KadeTabTile(title: title, caption: caption, spoken: spoken, icon: icon, tint: tint, hint: hint) { nav.open(route) }
    }
}

// MARK: - Play

struct PlayHomeView: View {
    @Environment(\.kadeNavigation) private var nav

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                KadePaintedHeader(imageName: "HeaderPlay", symbol: "suit.club.fill", tint: .green)

                KadeToolRow {
                    kadeTile("The Parlor", caption: "Card and table games", spoken: "The Parlor", icon: "suit.club.fill", tint: .mint, hint: "Every game on a menu — play your own cards with buttons, seat characters if you want company, and a house narrator calls the table.", route: .parlor)
                    kadeTile("Kade's Clubhouse", caption: "Live family voice rooms", spoken: "Kade's Clubhouse", icon: "hifispeaker.2.fill", tint: .pink, hint: "Live family voice rooms with a shared jukebox anyone can drive, private Hotel rooms with passcodes, and character guests you can invite in.", route: .lounge)
                }
                KadeToolRow {
                    kadeTile("Debate Room", caption: "Characters talk it out", spoken: "Debate Room", icon: "person.3.fill", tint: .indigo, hint: "Set a topic, cast 2 to 6 characters, and let them go back and forth. Also reaches the Conversation Hall.", route: .debateRoom)
                    kadeTile("Matchmaker", caption: "Find a character you'd like", spoken: "Matchmaker", icon: "person.2.fill", tint: .pink, hint: "Five quick questions, then three characters who might be a good fit.", route: .matchmaker)
                }

                Button { nav.open(.marketplace) } label: {
                    Label("Marketplace", systemImage: "storefront")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KadeCardButtonStyle())
                .labelStyle(KadeRowLabelStyle(tint: .orange, caption: "Meet every character"))
                .accessibilityLabel("The Marketplace")
                .accessibilityHint("Browse every published character by category, hear who's who, start talking to anyone — and publish your own creations.")
            }
            .padding()
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Play")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func kadeTile(_ title: String, caption: String, spoken: String, icon: String, tint: Color, hint: String, route: HomeRoute) -> some View {
        KadeTabTile(title: title, caption: caption, spoken: spoken, icon: icon, tint: tint, hint: hint) { nav.open(route) }
    }
}

/// One two-up tile (session 25 grid, B1 caption). The VISIBLE title is short;
/// the SPOKEN label is pinned to the phrase the old Home used.
struct KadeTabTile: View {
    let title: String
    let caption: String
    let spoken: String
    let icon: String
    let tint: Color
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(KadeCardButtonStyle())
        .labelStyle(KadeCaptionedTileLabelStyle(tint: tint, caption: caption))
        .accessibilityLabel(spoken)
        .accessibilityHint(hint)
    }
}

// MARK: - More

struct MoreHomeView: View {
    let user: KadeUser
    let apiClient: KadeAPIClient
    @Environment(\.kadeNavigation) private var nav
    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var unread = KadeUnread.shared
    @ObservedObject private var updates = KadeUpdateCheck.shared
    /// Part 278: what "Check for updates" found, shown as its caption and
    /// spoken, so the answer is visible as well as heard.
    @State private var updateCheckNote: String?
    @State private var showingWeb = false
    @State private var webLoadFailed = false
    @State private var showWebLoadAlert = false
    @State private var showingFeedback = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // The old Home's status line, now at the top of More: one
                // combined element (text only, no controls inside).
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.indigo)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in as \(user.displayName)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(user.email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .combine)

                // Part 278: only while this copy is behind.
                if let offer = updates.available {
                    row("Update Kade-AI", icon: "arrow.down.app.fill", tint: .green, caption: "A newer version is ready in \(offer.storeName)",
                        spoken: "Update Kade-AI", hint: "Opens \(offer.storeName) so you can install the newest version.") { updates.openUpdate(offer) }
                }

                row("Search everything", icon: "magnifyingglass", tint: .blue, caption: "Places, characters, chats, the Library",
                    spoken: "Search everything", hint: "Finds places in the app, characters, your chats and the Library.") { nav.open(.search) }

                heading("Updates")
                row("Alerts", icon: "bell", tint: .orange, caption: "Reminders and check-ins", badge: unread.count(.alerts),
                    spoken: unread.spoken("Alerts", .alerts), hint: "Your recent reminders and check-ins, and how they reach you.") { nav.open(.alerts) }
                row("Announcements", icon: "megaphone", tint: .purple, caption: "News about the app from Kade", badge: unread.count(.announcements),
                    spoken: unread.spoken("Announcements", .announcements), hint: "What's New announcements from Kade-AI, full text, newest first.") { nav.open(.announcements) }
                row("Agent work", icon: "checklist", tint: .indigo, caption: "Replies saved after a dropped connection", badge: unread.count(.agentWork),
                    spoken: unread.spoken("Agent work", .agentWork), hint: "Check recent requests and find saved replies after a connection drops.") { nav.open(.agentWork) }

                heading("Your things")
                row("Bookmarks", icon: "bookmark.fill", tint: .red, caption: "Conversations you tagged",
                    spoken: "Bookmarks", hint: "Your tagged conversations, gathered by bookmark — tag any conversation from the conversation list.") { nav.open(.bookmarks) }

                heading("Settings and help")
                row("Settings", icon: "gearshape", tint: .gray, caption: "Voices, ringtone, text and sound",
                    spoken: "Settings", hint: "Speech, accessibility, notifications, your app icon, and the pronunciation dictionary.") { nav.open(.settings) }
                row("Help", icon: "questionmark.circle", tint: .mint, caption: "Where things are, how they work",
                    spoken: "Help", hint: "Where everything is and how it works, section by section.") { nav.open(.help) }
                row("Tell Kade how it's going", icon: "exclamationmark.bubble", tint: .pink, caption: "A problem, or an idea",
                    spoken: "Tell Kade how it's going", hint: "Opens a short form that goes straight to Kade with your name on it.") { showingFeedback = true }
                row("Open Kade-AI web", icon: "safari", tint: .blue, caption: "The full website, inside the app",
                    spoken: "Open Kade-AI web", hint: "Opens the full Kade-AI web app in a browser inside this app.") { showingWeb = true }
                row("Check for updates", icon: "arrow.triangle.2.circlepath", tint: .green,
                    caption: updateCheckNote ?? "You have version \(updates.installedDescription)",
                    spoken: "Check for updates",
                    hint: "Checks whether a newer Kade-AI is ready. You have version \(updates.installedDescription).") {
                    Task { await checkForUpdates() }
                }

                // Session 24: server-gated; rendered only for an ADMIN account,
                // so nobody else ever hears a section they can't use.
                if user.role == "ADMIN" {
                    heading("Admin")
                    row("Admin dashboard", icon: "chart.bar.doc.horizontal", tint: .red, caption: nil,
                        spoken: "Admin dashboard", hint: "Usage and spending, feedback reports, and activity logs. Only admin accounts see this.") { nav.open(.admin) }
                }

                Button(role: .destructive, action: auth.signOut) {
                    Text("Sign out").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
                .accessibilityHint("Signs you out and clears your saved session on this device.")
            }
            .padding()
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .task { await unread.refresh(client: apiClient) }
        .refreshable { await unread.refresh(client: apiClient, force: true) }
        .sheet(isPresented: $showingFeedback) {
            FeedbackReportView(apiClient: apiClient, entry: "how-its-going")
        }
        .sheet(isPresented: $showingWeb) {
            SafariView(url: URL(string: "https://kademurdock.com")!, loadFailed: $webLoadFailed)
                .ignoresSafeArea()
        }
        .onChange(of: webLoadFailed) { _, failed in
            // Same reasoning as the old Home: a real alert (always announced)
            // instead of Safari's own error page, a beat after the sheet goes.
            guard failed else { return }
            showingWeb = false
            webLoadFailed = false
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                showWebLoadAlert = true
            }
        }
        .alert("Couldn't load Kade-AI web", isPresented: $showWebLoadAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
    }

    /// Part 278: a check on demand. Behind: the app-wide "Update Kade-AI?"
    /// alert answers. Otherwise the answer becomes this row's caption and is
    /// spoken.
    private func checkForUpdates() async {
        let words: String?
        switch await updates.check(client: apiClient, force: true) {
        case .behind:
            words = nil
        case .upToDate:
            words = "You have the newest version, \(updates.installedDescription)."
        case .unknown:
            words = "Couldn't check for updates right now. Try again in a minute."
        case .notChecked:
            words = "This copy of Kade-AI can't check for updates."
        }
        updateCheckNote = words
        if let words {
            UIAccessibility.post(notification: .announcement, argument: words)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ title: String, icon: String, tint: Color, caption: String?, badge: Int = 0,
                     spoken: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(KadeCardButtonStyle())
        .labelStyle(KadeRowLabelStyle(tint: tint, caption: caption, badge: badge))
        .accessibilityLabel(spoken)
        .accessibilityHint(hint)
    }
}
