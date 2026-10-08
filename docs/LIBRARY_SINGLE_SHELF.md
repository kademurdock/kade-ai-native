# Single native catalog list

The Library home now embeds the existing authorized catalog's `/browse`
endpoint. One item list supports search, Type, Decade, Format and Order.
Source-aware newspaper, newsletter and yearbook types use the server's facet
IDs, while each row uses its saved `typeLabel` and returned decade. Continue
and Family history retain their existing players and account gates. The old
folders, My uploads, pending uploads, saved history and collections remain in
a closed Other library views group. Add and the librarian remain reachable.

Requests use `q`, `scope`, `kind`, `type`, `decade`, `sort`, optional `path`,
and the opaque `after` cursor. No page offset or client-generated cursor is
used. Literal plus signs are escaped for HTTP query parsing. A new exact
query or refresh invalidates old results and cursors, including responses
from a previous visit to the same filters. More requests capture both query
and generation, deduplicate IDs and move to the first actual new item.
Empty pages and repeated cursors cannot create an endless More loop. A
canceled load is quiet; retries are explicit. Move/delete action receipts
refresh the catalog. Returning from the existing player preserves the list.

Items continue through `LibraryItemRow`, `LibraryRowActions` and the existing
item route. No playback, narration, saved-place, upload or casting system is
replaced. The client does not create account grants or broaden family access;
the API applies the same owner, child, test-seat and feature-pack policy.

The Home List owns the sole catalog task and its controller. The two catalog
Sections carry no request lifecycle modifiers. The controller guards duplicate
in-flight loads; leaving invalidates that guard before a quick return, cancels
More, and leaves previously completed results intact. The page generation
still rejects any old completion. More reserves its request identity
synchronously; cancellation invalidates it independently of the cached list.
An old canceled page's cleanup cannot release a newer page's busy state after
a quick return.

Foundation fixtures check wire decoding, source-type labels, exact query
fields, reserved characters, opaque cursors, deduplication, stale-query and
same-query-generation isolation, scope isolation and page bounds. Both CI
lanes run the new gate before compiling the app. Windows and the available
Linux devbox have no Swift compiler, so local source, script, YAML and
existing audio checks do not establish app compilation. Physical VoiceOver,
picker navigation, player return and load-more focus remain device checks.

The shared `/browse` API must be deployed and its existing regular, owner,
child and family/test access checks verified before this candidate is built
or delivered. The separately delivered 2.2.6 build 327 remains available
regardless of this candidate's outcome.
