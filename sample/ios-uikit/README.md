# DiagLogUIKitSample

UIKit-structured sample app sources for the AppDiagLog iOS SDK.

This sample shows a common brownfield architecture: **UIKit owns app lifecycle, tabs, and push navigation; SwiftUI renders the individual screens via `UIHostingController`.**

## What this sample demonstrates

- manual `debug`, `info`, `warning`, and `error` logging
- session tagging and explicit `setCurrentScreen(_:)` calls from UIKit controllers
- UIKit push/pop navigation with a SwiftUI detail view
- URLSession traffic for API-call tracking
- deep-link logging from `SceneDelegate`
- encrypted export via share sheet, HTTP upload, and MCP
- SDK config/status inspection and shutdown controls

## Folder layout

```text
sample/ios-uikit/
├── README.md
└── DiagLogUIKitSample/
    ├── AppDelegate.swift
    ├── SceneDelegate.swift
    ├── Info.plist
    ├── Controllers/
    ├── Views/
    ├── Helpers/
    └── Assets.xcassets/
```

## Run the sample

- Replace `REPLACE_WITH_YOUR_BASE64_PUBLIC_KEY` in `AppDelegate.swift` with a real backend-registered public key.
- The sample defaults to `.rsaOaep3072(...)` so it works in a traditional UIKit app without requiring a PQC runtime.
- To try MCP client mode, set `enableMcpClient = true` and configure the sample server URL/token.
- To try MCP server mode, set `enableMcpServer = true` and optionally customize the server token/port.
- The default upload URL targets `http://localhost:8080`, which maps to the host machine when running in the iOS simulator.

## Deep-link demo

The sample plist registers the `diagloguikit://` scheme. Example:

```bash
xcrun simctl openurl booted "diagloguikit://support/export?source=simulator"
```

`SceneDelegate` logs the incoming URL so you can inspect it in the next export.

## Notes

- No Xcode project file is committed here on purpose.
- Unlike the pure SwiftUI sample, screen ownership lives in UIKit view controllers here. Each tab controller calls `AppDiagLog.setCurrentScreen(...)` in `viewDidAppear(_:)`.
- SwiftUI is still useful for view composition, forms, and lists while UIKit keeps control of navigation and lifecycle.
