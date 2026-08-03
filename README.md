# AinkradRaven

Gmail plugin for the Ainkrad host app.

## Setup: OAuth credentials

The Accounts surface only shows a Connect button — it does not ask anyone to
paste a Google OAuth client id/secret. Those credentials are baked into the
build from a local, untracked file:

1. Copy the real credentials file into `Config/`:
   ```
   cp ~/.config/ainkrad-raven/oauth-client.json Config/oauth-client.json
   ```
   (If you don't have that file, get a Desktop OAuth client's JSON from
   Google Cloud Console — it downloads in exactly this shape. See
   `Config/oauth-client.example.json` for the shape if you're setting one up
   from scratch.)
2. Run `make generate` (or `make build` / `make sideload`, which both depend
   on it). This runs `scripts/generate-oauth-credentials.sh`, which reads
   `Config/oauth-client.json` and writes
   `Sources/RavenFeature/Generated/BakedOAuthCredentials.swift` — a Swift
   source file with the client id/secret as constants, generated fresh every
   time, before `xcodegen generate` runs (xcodegen's `sources:` list is
   captured from whatever files exist in `Sources/RavenFeature` at generate
   time, so the file has to exist before that scan).

Both `Config/oauth-client.json` and the generated Swift file are gitignored
— neither is ever committed. If `Config/oauth-client.json` is absent, the
generator still runs and bakes in no credentials; `RavenRuntime` then falls
back to the manual client id/secret fields on the Accounts surface, so a
developer without the file can still work, and the app degrades honestly
(a disabled, clearly-labeled Connect button) rather than showing a button
that can never work.

### On the embedded client secret

The baked client secret ships inside the built app and **is extractable** by
anyone with the binary — there is no way to embed a secret in a distributed
desktop app that isn't. This is accepted here because Google's "installed"
(Desktop) OAuth client type is designed around exactly that: the real
protection is PKCE (the code verifier/challenge in the authorization flow),
not secrecy of the client secret. Two practical consequences follow from
that trade-off, not from a bug:

- API quota is shared across every install of this app that uses the baked
  credentials, not per-developer.
- If the secret leaks in a way that matters (e.g. it turns up on an
  unrelated OAuth client), the fix is to rotate the Google Cloud client, not
  to try to make the embedded copy any less extractable.
