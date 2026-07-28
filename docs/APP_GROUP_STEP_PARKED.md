# Kade Keys phase 2 -- the parked App Group signing step (July 28 2026, session 34)

Phase 2's Swift is SHIPPED and dormant (KadeKeysSharedStore + the
PromptsView mirror + the keyboard's shared-prompt reader, all fail-soft
to v1 behavior). What's parked is ONLY the signing half, because Apple's
official App Store Connect API refuses App Group assignment -- live
receipt from build 6a69270e:

    HTTP 409 ENTITY_ERROR.ATTRIBUTE.TYPE: "'APP_GROUP_IDS' is not a valid
    value for the attribute 'settings/0/key'. Expected one of:
    'ICLOUD_VERSION', 'DATA_PROTECTION_PERMISSION_LEVEL',
    'APPLE_ID_AUTH_APP_CONSENT'"

So there is no API path with the team's ASC key (fastlane manages groups
only through its cookie-auth PRIVATE API). The one-time human step:

1. developer.apple.com > Account > Identifiers > App Groups > register
   `group.com.kademurdock.kadeai`.
2. Identifiers > App IDs: enable App Groups and assign that group on BOTH
   `com.kademurdock.kadeai` and `com.kademurdock.kadeai.keyboard`.
3. In project.yml: uncomment BOTH application-groups blocks and flip the
   keyboard's RequestsOpenAccess to true (comments mark all three spots).
4. Build. fetch-signing-files --create replaces the invalidated profiles
   with ones carrying the group. Done -- the keyboard starts typing the
   real Prompt Library for anyone with Allow Full Access on.

Two CI lessons already paid for, so the next ASC-API script keeps them:
- APP_STORE_CONNECT_PRIVATE_KEY arrives as `@file:/...` -- a POINTER at
  the .p8 on the build machine, not key material. Read the file it names.
- The .p8 may carry literal backslash-n framing; normalize before PyJWT.

The full working step (JWT mint + bundle-id lookup + capability POST,
minus Apple's cooperation) as it last ran:

```yaml
      - name: Assign the App Group to both bundle ids (ASC API)
        script: |
          set -e
          # KADE KEYS phase 2 (July 28 2026): the shared-container
          # entitlement (group.com.kademurdock.kadeai, in project.yml for
          # BOTH targets) only signs if BOTH App IDs carry the App Groups
          # capability with that group assigned in the developer portal.
          # There is no official /v1/appGroups endpoint (checked July 28),
          # but POST /v1/bundleIdCapabilities accepts the group identifier
          # string as the APP_GROUP_IDS option key (the shape third-party
          # ASC tooling ships today) -- same move as fetch-signing-files
          # --create minting the keyboard bundle id: try the API first,
          # fall back to hands only if Apple says no. Runs BEFORE signing
          # so a capability change invalidates old profiles and the
          # fetch-signing-files calls below mint fresh ones WITH the
          # group. Idempotent: reruns see the capability and skip.
          # IF THIS STEP IS WHAT A RED BUILD POINTS AT: register the group
          # by hand (developer portal > Identifiers > App Groups > + >
          # "group.com.kademurdock.kadeai"), tick App Groups + assign it
          # on BOTH ids (com.kademurdock.kadeai and .keyboard), then rerun.
          pip3 install --quiet PyJWT cryptography
          python3 << 'PY'
          import json, os, time, urllib.request, urllib.error
          import jwt

          ISSUER = os.environ["APP_STORE_CONNECT_ISSUER_ID"]
          KEY_ID = os.environ["APP_STORE_CONNECT_KEY_IDENTIFIER"]
          # First run's lesson (build 6a692603..., MalformedFraming): the
          # integration delivers the .p8 with literal backslash-n escapes,
          # not real newlines -- Codemagic's own CLI normalizes internally,
          # PyJWT does not. Normalize here; base64 fallback just in case a
          # future integration format changes shape again.
          _raw = os.environ["APP_STORE_CONNECT_PRIVATE_KEY"].strip()
          # Second run's lesson: the integration sets the env var to an
          # @file: POINTER at the .p8 on the build machine (their CLI
          # resolves it; we do the same), not to the key material itself.
          if _raw.startswith("@file:"):
              _raw = open(_raw[len("@file:"):]).read()
          _raw = _raw.replace("\\n", "\n").replace("\r\n", "\n").replace("\r", "\n")
          if "BEGIN" not in _raw:
              import base64 as _b64
              try:
                  _raw = _b64.b64decode(_raw).decode()
              except Exception:
                  pass
          PRIVATE_KEY = _raw.strip() + "\n"
          print("ASC key header:", PRIVATE_KEY.splitlines()[0])
          GROUP = "group.com.kademurdock.kadeai"
          BUNDLES = ["com.kademurdock.kadeai", "com.kademurdock.kadeai.keyboard"]
          API = "https://api.appstoreconnect.apple.com"

          token = jwt.encode(
              {"iss": ISSUER, "iat": int(time.time()) - 30,
               "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"},
              PRIVATE_KEY, algorithm="ES256", headers={"kid": KEY_ID},
          )

          def call(method, path, body=None):
              req = urllib.request.Request(
                  API + path, method=method,
                  headers={"Authorization": "Bearer " + token,
                           "Content-Type": "application/json"},
                  data=json.dumps(body).encode() if body is not None else None,
              )
              try:
                  with urllib.request.urlopen(req) as r:
                      raw = r.read()
                      return r.status, json.loads(raw) if raw else {}
              except urllib.error.HTTPError as e:
                  raw = e.read().decode(errors="replace")
                  try:
                      return e.code, json.loads(raw)
                  except Exception:
                      return e.code, {"raw": raw}

          failures = []
          for ident in BUNDLES:
              st, out = call("GET", "/v1/bundleIds?filter[identifier]=" + ident + "&limit=200")
              rid = None
              for item in out.get("data", []):
                  if item.get("attributes", {}).get("identifier") == ident:
                      rid = item["id"]
                      break
              if not rid:
                  failures.append(ident + ": bundle id not found via ASC API (HTTP %s)" % st)
                  continue
              st, caps = call("GET", "/v1/bundleIds/" + rid + "/bundleIdCapabilities?limit=200")
              existing = None
              for cap in caps.get("data", []):
                  if cap.get("attributes", {}).get("capabilityType") == "APP_GROUPS":
                      existing = cap
                      break
              settings = [{"key": "APP_GROUP_IDS",
                           "options": [{"key": GROUP, "enabled": True}]}]
              if existing:
                  have = json.dumps(existing.get("attributes", {}).get("settings") or [])
                  if GROUP in have:
                      print(ident + ": App Groups capability already carries " + GROUP + " -- skipping.")
                      continue
                  st, out = call("PATCH", "/v1/bundleIdCapabilities/" + existing["id"],
                                 {"data": {"type": "bundleIdCapabilities",
                                           "id": existing["id"],
                                           "attributes": {"capabilityType": "APP_GROUPS",
                                                          "settings": settings}}})
                  verb = "PATCH"
              else:
                  st, out = call("POST", "/v1/bundleIdCapabilities",
                                 {"data": {"type": "bundleIdCapabilities",
                                           "attributes": {"capabilityType": "APP_GROUPS",
                                                          "settings": settings},
                                           "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": rid}}}}})
                  verb = "POST"
              if 200 <= st < 300:
                  print(ident + ": App Groups capability " + verb + " OK (HTTP %s), group %s assigned." % (st, GROUP))
              else:
                  failures.append(ident + ": " + verb + " bundleIdCapabilities HTTP %s -> %s" % (st, json.dumps(out)[:600]))

          if failures:
              print("APP GROUP ASSIGNMENT FAILED -- the ASC API would not take it.")
              for f in failures:
                  print("  " + f)
              print("Manual path: developer portal > Identifiers > App Groups > register")
              print("  group.com.kademurdock.kadeai, then enable App Groups + assign it on")
              print("  BOTH App IDs (com.kademurdock.kadeai and com.kademurdock.kadeai.keyboard),")
              print("  then rerun this build. Failing loudly now beats a codesign mystery later.")
              raise SystemExit(1)
          PY
```
