# Courier — desktop API client

A local-first API testing tool for **Windows, macOS (Apple Silicon + Intel) and Linux**, built with Flutter.
Classic API-client workflow: collections → folders → requests, tabs, environments, history.
No accounts, no sign-in, no cloud sync. Everything stays on your machine.

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
- Import: Postman Collection v2.0/v2.1, Postman Environment, Courier export, cURL. Export: Courier JSON and Postman v2.1.
- Settings: SSL verification, redirects, timeouts, proxy (system/custom with auth), custom CA certificate, client certificate (mTLS), theme (dark/light), editor font size.

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

**CI**: `.github/workflows/build.yml` tests the project, then builds Linux, Windows and macOS artifacts on every push.
Pushing a `v*` tag publishes them to a GitHub Release.

## Where data is stored
Everything is saved automatically as JSON in the app-support directory, in a `courier/` subfolder:
- Linux: `~/.local/share/dev.courier.courier/courier/`
- Windows: `%APPDATA%\dev.courier\courier\courier\`
- macOS: `~/Library/Application Support/dev.courier.courier/courier/`

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
