# Native character starters and Sound Booth

The candidate extends the clean held `codex/sol-think-20261005` source at
`fbaea66`. The October 5 read-only release check found the latest signed
Codemagic build at `f45067c`, with Apple binary 2.2.4 build 324 in VALID state.
That binary does not include the held Sound Booth Auto/Low/Medium/High writing
control and generated-song-title handling. Both held commits are retained.

Native chat now reads each accessible character's public
`conversation_starters` pool from the existing agent list. A fresh local seed
selects four opening lines for each new conversation. Rendering, typing and
returning from a sheet retain that selection. Short authored pools are
respected; old records without a field use varied general opening lines, and
explicit empty pools turn starters off. Tapping a
line fills the composer for editing, and never sends it automatically.

The character editor supports pools of up to 24 lines and the free authenticated
`POST /api/kade/builder/starters` preview. It submits only the fields already
in the editor. A response cannot overwrite character or starter edits made
while it was loading. The persona writer accepts the new optional starter
array, displays it for review and lets the user choose whether to use it.
Existing arrays and omitted response fields remain compatible. Nothing is
saved before Save in the editor. Quiz-generated pools already pass through the
existing native quiz contract. Marketing version 2.2.4 is retained; the app's
one-time What's New card uses its new title to distinguish this update, and
Help retains the earlier Sound Booth and family-history notes.

Acquaintance recognition, private relationship impressions and character
development run on the platform, rather than in the native client. Native
starter selection makes no model call and reads no private memory or
conversation. The server must deploy the ACL-aware agent-list starter
projection and free preview route before those new native features are used.

## Checks and the one-build release

Windows checks passed: all 59 art descriptions, two signed-receipt tests,
YAML parsing, Bash syntax for all 18 workflow scripts and eight run scripts,
and whitespace validation. No Swift compiler is installed here. The 31
Foundation starter checks are prepared for both Codemagic lanes and have not
been executed on Windows. No physical-device acceptance is claimed.

The user authorized one new native build. The signed `ios-native-testflight`
workflow runs Foundation gates before the archive, which compiles the app.
Its separate offline character simulator audit is opt-in with
`KADE_CHARACTER_AUDIT=1`; a successful skipped step is not simulator evidence.
This release keeps the existing value `0`, since it changes no speech or
character-animation path. Simulator and physical-device checks remain unperformed.
Use the exact approved source SHA guard, retain Xcode 26.4 and the
existing signing integration, and do not launch a separate compile job or
automatic retry. The workflow remains capped at 15 minutes on Mac mini M2.
The published rate is $0.095/minute, a $1.425 compute bound before taxes if
free minutes are unavailable: https://codemagic.io/pricing/ .

App Store screenshots remain off unless explicitly requested. The existing
owner-only build success/failure receipt email remains enabled. Automatic
TestFlight submission remains disabled. Any existing external tester group
keeps automatic notifications off. TestFlight What to Test stays exactly:
`Everything can always use testing.` No public App Store submission is part of
this build request.
