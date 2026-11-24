# Courier — desktop API client

A local-first API testing tool for **Windows, macOS (Apple Silicon + Intel) and Linux**, built with Flutter.
Classic API-client workflow: collections → folders → requests, tabs, environments, history.
No accounts, no sign-in, no cloud sync. Everything stays on your machine.

**Website and documentation: https://ranefattesingh.github.io/courier/**

## Install

Downloads for every platform are on the [Releases page](https://github.com/ranefattesingh/courier/releases/latest).

**Windows 10/11** — download `Courier-Setup-<version>-x64.exe` and run it. No admin rights needed (it installs per-user by
default; choose "all users" in the installer if you prefer). A portable `.zip` is also available.
> The installer isn't code-signed yet, so Windows SmartScreen may say *"Windows protected your PC"*. Click **More info → Run anyway**.

**macOS 12+ (Apple Silicon and Intel)** — with [Homebrew](https://brew.sh):
```bash
brew install --cask ranefattesingh/tap/courier
```
or download `courier-macos-universal.zip`, unzip, and drag **Courier.app** to Applications.
> The app isn't notarized yet. On first launch macOS will block it: open **System Settings → Privacy & Security**, scroll down
> and click **Open Anyway** next to the Courier message. You only need to do this once.

**Debian / Ubuntu / Linux Mint / Pop!_OS** (apt):
```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://ranefattesingh.github.io/courier/courier.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/courier.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/courier.gpg] https://ranefattesingh.github.io/courier/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/courier.list
sudo apt update && sudo apt install courier-api
```
Or install the downloaded file directly: `sudo apt install ./courier-api_<version>_amd64.deb`.

**Fedora / RHEL / Rocky / Alma** (dnf):
```bash
sudo curl -fsSL -o /etc/yum.repos.d/courier.repo https://ranefattesingh.github.io/courier/rpm/courier.repo
sudo dnf install courier-api
```
Or: `sudo dnf install ./courier-api-<version>-1.x86_64.rpm`.

On Linux, launch **Courier** from your app menu or run `courier-api`. The package is named `courier-api` because
`courier` is already taken by the Courier mail-server packages in Debian and Fedora. Updates arrive through your
normal `apt upgrade` / `dnf upgrade` once the repository is added. A portable `courier-linux-x64.tar.gz` is also provided.

## Protocols

| Type | What you can do |
|---|---|
| **HTTP / REST** | All methods; params ↔ URL sync; headers; body: none, form-data (text + files), x-www-form-urlencoded, raw (JSON/XML/HTML/JS/Text), binary, GraphQL; cookies; redirects; timeouts |
| **GraphQL** | Query + variables + operation name; schema introspection explorer (generate operations from fields); **subscriptions** over WebSocket (`graphql-transport-ws` and legacy `graphql-ws`) |
| **gRPC** | Unary, server-streaming, client-streaming, bidirectional; **server reflection** (v1 / v1alpha) or **.proto import** (multi-file, nested types, maps, oneofs, enums, well-known types); metadata; TLS / plaintext; "Generate example message"; no code generation needed |
| **WebSocket** | Connect with headers/sub-protocols/auth; send text, JSON, XML or binary (Base64); message log |
| **Socket.IO** | v4 servers; namespaces, handshake path, auth payload, transport selection; emit events (with ack); captures every incoming event |
| **MQTT** | 3.1.1 over TCP, TLS, WS, WSS; username/password, client id, keep-alive, clean session, last will; subscribe to many topic filters with QoS; publish with QoS/retain |
| **Server-Sent Events** | Any method + body (works with streaming LLM APIs); parses `event` / `data` / `id` / `retry` |
| **SOAP** | 1.1 / 1.2; SOAPAction; **WSDL import** (URL or file) → operation picker with generated envelope; WS-Security UsernameToken (PasswordText / PasswordDigest) |
| **Kafka** | Native protocol client (no JVM): produce (key, value, headers, partition, acks; default murmur2 partitioner) and consume (earliest/latest/offset, per-partition, live tail, no consumer group). PLAINTEXT, SSL, SASL_PLAINTEXT, SASL_SSL with PLAIN / SCRAM-SHA-256 / SCRAM-SHA-512. Topic listing. Gzip-compressed batches are decoded; snappy/lz4/zstd batches are shown as a notice |

## Authentication
Inherit from parent, No Auth, API Key (header/query), Bearer, Basic, **Digest** (automatic challenge/response, MD5/SHA-256, -sess, qop auth/auth-int),
**OAuth 1.0** (HMAC-SHA1/256/512, PLAINTEXT; header/query/body), **OAuth 2.0** (Authorization Code, Authorization Code + PKCE, Implicit, Password, Client Credentials, Refresh Token; opens your browser and listens on the callback URL),
**Hawk**, **AWS Signature v4** (header or presigned query), **NTLM v2**, **Akamai EdgeGrid**, **JWT Bearer** (HS/RS/PS/ES 256/384/512).
Auth can be set on a collection or folder and inherited by everything inside it.

## Organisation & variables
- Collections per project or microservice, with **nested folders and sub-folders**. Drag and drop to move or reorder. Right-click or `⋯` for actions.
- **Multiple environments** (Dev / Staging / Prod…), plus Globals and collection variables. Precedence: Global < Collection < Environment.
  Secret values are masked. `{{variables}}` are highlighted green (defined) or red (undefined) everywhere.
- Dynamic variables: `{{$guid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`, `{{$randomInt}}`, `{{$randomEmail}}`, `{{$randomFullName}}`, `{{$randomPrice}}`, and more.
- **Tests tab**: assertions on status, response time, headers, body text, or JSON path (`$.data.items[0].id`, `[*]`, `..name`, `.length`).
- **Variable capture** from JSON path / header / regex / status into environment, collection or global variables. This chains requests together.
- **Collection Runner**: iterations, delay, stop on failure, pass/fail summary. Runs HTTP, GraphQL, SOAP and gRPC unary requests.
- History, Console (full request/response log), Cookie manager, Code snippets (cURL, HTTP, Python, JS fetch, Node axios, Go, C#, Java, PowerShell).
- **Import** (file upload or paste; JSON or YAML auto-detected):
  - Postman: Collection v1 (classic Chrome app), v2.0, v2.1, Environments, full data dumps (Settings → Export data, including globals)
  - Insomnia: v4 JSON export and v5 YAML/JSON collections and environment files. Covers folders, auth, all body types, GraphQL, gRPC (with proto files), WebSocket, and base/sub-environments. `{{ _.var }}`, `{% uuid %}` and `{% now %}` templates are converted, and folder headers are applied to the requests inside.
  - Courier JSON exports and cURL commands
- **Export** (top bar **Export**, sidebar ↑ icon, or a collection's `⋯` menu): one collection or all, as **Courier JSON** (every protocol, optionally with environments and globals) or **Postman Collection v2.1 JSON** (HTTP, GraphQL and SOAP requests; the dialog says how many other requests will be left out).
- **Layout**: show the response **below** the request (stacked) or **to the right** (side by side). Switch with the layout button in the tab bar, the status bar, or Settings → General. The choice is remembered.
- Settings: SSL verification, redirects, timeouts, proxy (system/custom with auth), custom CA certificate, client certificate (mTLS), theme (dark/light), request/response layout, editor font size.

Keyboard shortcuts (`⌘` on macOS): `Ctrl+Enter` send/connect, `Ctrl+S` save, `Ctrl+T` new tab, `Ctrl+W` close tab, `Ctrl+O` import, `Ctrl+Tab` next tab.

## Building

Requires Flutter **3.50+** (stable).

```bash
flutter pub get
flutter test --concurrency=1     # engine + UI tests (set KAFKA_BOOTSTRAP=host:9092 to include live Kafka test)
```

**Linux**
```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev
flutter build linux --release        # → build/linux/x64/release/bundle/courier
```

**Windows** (Visual Studio 2022 with "Desktop development with C++")
```powershell
flutter build windows --release      # → build\windows\x64\runner\Release\courier.exe
```

**macOS** (Xcode)
```bash
flutter build macos --release        # → build/macos/Build/Products/Release/Courier.app
```
The macOS release build is a universal binary (arm64 + x86_64), so the same `.app` runs natively on Apple Silicon and Intel.
Network client/server (OAuth callback) and user-selected file access are enabled in the sandbox entitlements.

**Linux packages locally**: after `flutter build linux --release`, run `packaging/linux/build-packages.sh <version>`
to produce the `.deb`, the tarball and (if `rpmbuild` is installed) the `.rpm` in `dist/`.

**Windows installer locally**: install [Inno Setup 6](https://jrsoftware.org/isinfo.php), then
`iscc /DAppVersion=<version> packaging\windows\courier.iss` → `dist\Courier-Setup-<version>-x64.exe`.

**App icon**: edit `assets/icons/courier_dark.png` / `courier_light.png` (ideally 1024×1024), then run
`python3 tool/generate_icons.py` (needs `pip install pillow`) to regenerate the macOS, Windows and Linux icons.

## Website

The website and user guide live in [`website/`](website/): plain HTML, CSS and JavaScript with no build step.
Preview it with `python3 -m http.server -d website 8000` and open http://localhost:8000.
Every push to `main` publishes it to GitHub Pages (the `website` job in the workflow), alongside the apt and dnf repositories.

The screenshots are rendered from the real app, sending real requests to local test servers:
```bash
flutter test tool/screenshots/screenshots_test.dart   # → build/screenshots/*.png
python3 tool/screenshots/optimize.py                  # → website/img/*.webp (needs Pillow)
```

## Releasing

`.github/workflows/build.yml` runs the tests and builds all platforms on every push and pull request.
To publish a release:

1. Set `version:` in `pubspec.yaml` (e.g. `1.1.0+2`), add a `## [1.1.0]` section to `CHANGELOG.md`
   (it becomes the release notes; the release fails without it), commit, and push a matching tag:
   ```bash
   git tag v1.1.0 && git push origin v1.1.0
   ```
2. CI creates a GitHub Release containing the Windows installer + portable zip, the macOS universal zip,
   the `.deb`, `.rpm`, Linux tarball, and `SHA256SUMS.txt`.

Two optional channels need a one-time setup. Until then, those CI jobs just print "skipped".

**apt + dnf repositories (GitHub Pages)**
1. Create a dedicated signing key **without a passphrase** (it only signs package indexes):
   ```bash
   gpg --batch --passphrase '' --quick-gen-key "Courier Packages <you@example.com>" rsa4096 sign never
   gpg --armor --export-secret-keys "Courier Packages" > courier-signing-key.asc
   ```
2. In the GitHub repo: **Settings → Secrets and variables → Actions → New secret** named `LINUX_REPO_GPG_KEY`
   with the contents of `courier-signing-key.asc`. Then delete the local file, and keep a backup of the key somewhere safe:
   losing it means users must re-import a new key.
3. After the first tagged release, go to **Settings → Pages**, choose **Deploy from a branch → `gh-pages` / root**.
   The repositories are served from `https://ranefattesingh.github.io/courier/`.

**Homebrew tap**
1. Create a public GitHub repo named **`homebrew-tap`** (with a README so it has a default branch).
2. Create a fine-grained personal access token with **Contents: read and write** on that repo only, and add it to
   this repo as the Actions secret `HOMEBREW_TAP_TOKEN`.
3. Each tagged release then writes `Casks/courier.rb` to the tap with the new version and checksum.

**Code signing (optional, later)**: an Apple Developer ID ($99/yr) with notarization removes the macOS
"Open Anyway" step, and a Windows code-signing certificate (or Azure Trusted Signing) removes the SmartScreen prompt.

## Where data is stored
Everything is saved automatically as JSON in the app-support directory, in a `courier/` subfolder:
- Linux: `~/.local/share/io.github.ranefattesingh.courier/courier/`
- Windows: `%APPDATA%\Fattesingh Rane\Courier\courier\`
- macOS: `~/Library/Containers/io.github.ranefattesingh.courier/Data/Library/Application Support/io.github.ranefattesingh.courier/courier/`

Files: `workspace.json` (collections, environments, globals, cookies), `settings.json`, `history.json`, `tabs.json` (open tabs, including unsaved drafts).

## Project layout
```
lib/
  models/            data model (requests, folders, environments, settings)
  core/              protocol engines (no UI): http, auth, oauth2, sessions (ws/sse/socket.io/mqtt/kafka/graphql-ws),
                     grpc/ (proto parser, wire codec, reflection), kafka/ (wire-protocol client), wsdl, importers, codegen, tests
  state/             AppState (workspace, tabs, persistence) and Executor (variables → auth → send → tests → captures)
  ui/                home, sidebar, editors per protocol, dialogs (runner, settings, environments, import/export…)
test/                engine integration tests against live local servers + full-app widget test
```

## License

[MIT](LICENSE) © 2026 Fattesingh Rane

Courier is an independent project. It is not affiliated with, endorsed by, or sponsored by Postman, Inc.,
Kong Inc. (Insomnia), or Courier (courier.com). Postman and Insomnia are trademarks of their respective owners
and are mentioned only to describe import/export compatibility.
