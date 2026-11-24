# Changelog

All notable changes to Courier are listed here. Each release on GitHub uses the matching section below.

## [1.0.2]

### Fixed
- Choosing an action from the **⋯** button on a collection, folder or request in the sidebar (Duplicate, Delete, Rename, Add request and so on) now works. Before, only the right-click menu applied the action.

## [1.0.1]

### New
- **Website and documentation** at https://ranefattesingh.github.io/courier/, with install instructions for every platform and a full user guide.

### Fixed
- The **Bulk Edit** button in the Params, Headers, form body and variable tables no longer wraps onto several lines. It now sits just above the table and stays in the same place when you switch to bulk editing and back.
- With the response shown **side by side**, the Test Results and Request tabs are no longer pushed out of view. In narrow panes the status, time and size move to their own line.
- Dropdowns, the Pretty/Raw switch and menus now use the same font as the rest of the app.
- Fixed a rare error when two saves happened at the same moment, for example when closing the app just as it saved automatically.

## [1.0.0]

First public release of **Courier**, a free, open-source desktop API client for Windows, macOS and Linux.
No account, no sign-in, no cloud sync. Your collections, environments and history stay on your computer.

### Protocols
- **HTTP / REST**: all methods, query params kept in sync with the URL, every body type (form-data with files, URL-encoded, raw, binary, GraphQL), cookies, redirects, timeouts.
- **GraphQL**: queries and variables, a schema explorer, and subscriptions over WebSocket.
- **gRPC**: all four call types, using server reflection or your own `.proto` files. No code generation needed.
- **WebSocket**, **Socket.IO**, **MQTT** and **Server-Sent Events**, each with a live message log.
- **SOAP**: 1.1 and 1.2, WSDL import with generated envelopes, WS-Security UsernameToken.
- **Kafka**: produce and consume directly from the app, with SASL (PLAIN, SCRAM) and TLS. No Java needed.

### Authentication
API Key, Bearer, Basic, Digest, OAuth 1.0, OAuth 2.0 (all common grant types, including PKCE), Hawk, AWS Signature v4, NTLM, Akamai EdgeGrid and JWT. Set auth once on a collection or folder and the requests inside inherit it.

### Organise and automate
- Collections with nested folders, drag-and-drop, tabs and history.
- Multiple environments, plus global and collection variables, with `{{variable}}` highlighting and dynamic values like `{{$guid}}`.
- Tests and variable capture to chain requests together, and a Collection Runner to run a whole collection.
- Code snippets in 9 languages, a console, and a cookie manager.

### Import and export
- Import from **Postman** (collections v1, v2.0, v2.1, environments and full data dumps), **Insomnia** (v4 and v5), Courier JSON and cURL commands.
- Export collections as Courier JSON or Postman Collection v2.1.

### Interface
- Dark and light themes with a saffron accent.
- Show the response below the request or beside it.
- Subtle animations, which you can turn off in Settings. They also follow your system's reduce-motion setting.
- Keyboard shortcuts for sending, saving and managing tabs.

### Downloads
| Platform | File |
|---|---|
| Windows 10/11 | `Courier-Setup-1.0.0-x64.exe` (installer) or `courier-windows-x64-portable.zip` |
| macOS 12+ (Apple Silicon and Intel) | `courier-macos-universal.zip`, or `brew install --cask ranefattesingh/tap/courier` |
| Debian / Ubuntu | `courier-api_1.0.0_amd64.deb`, or the apt repository (see the README) |
| Fedora / RHEL | `courier-api-1.0.0-1.x86_64.rpm`, or the dnf repository (see the README) |
| Other Linux | `courier-linux-x64.tar.gz` |

Check your download against `SHA256SUMS.txt`.

### Known issues
- The Windows installer isn't code-signed yet, so SmartScreen may warn you. Click **More info → Run anyway**.
- The macOS app isn't notarized yet. On first launch, go to **System Settings → Privacy & Security → Open Anyway**.
- On Linux, the package and command are named `courier-api`, because `courier` is already taken by a mail server in Debian and Fedora.
- Kafka messages compressed with snappy, lz4 or zstd are listed but not decoded. Gzip messages are decoded.

Courier is not affiliated with Postman, Inc., Kong Inc. (Insomnia) or courier.com.
