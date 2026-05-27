# DiagLogSwiftUISample

Pure SwiftUI sample app sources for the AppDiagLog iOS SDK.

## What this sample demonstrates

- manual `debug`, `info`, `warning`, and `error` logging
- session tagging and current-screen tracking
- SwiftUI auto-tracking via `.trackIdentifier()` and `.trackDeepLinks()`
- URLSession traffic for API-call tracking
- encrypted export via share sheet, HTTP upload, and MCP
- SDK status/config inspection from a settings tab

## Folder layout

```text
sample/ios-swiftui/
├── README.md
└── DiagLogSwiftUISample/
    ├── DiagLogSwiftUISampleApp.swift
    ├── ContentView.swift
    ├── Views/
    ├── Helpers/
    └── Assets.xcassets/
```

## Run the sample

- Replace `REPLACE_WITH_YOUR_BASE64_PUBLIC_KEY` in `DiagLogSwiftUISampleApp.swift` with a real public key.
- The sample defaults to `.rsaOaep3072(...)` so it can run on iOS 16+ without an extra PQC provider.
- If you want PQC in the sample, switch to `.mlKem768(...)` or `.mlKem512(...)` and provide a compatible provider/runtime.
- Update the upload URL/token defaults in `SampleConfiguration` if you want to send exports to the backend.
- MCP client/server options are available in the Settings tab. Toggle one mode
  and fill in its additional settings. MCP client bearer tokens are kept only in
  memory for the current app run. MCP server Start applies the current settings
  immediately.

## Notes

- No Xcode project file is committed here on purpose.
- `Force New Session` seals the current session by calling `AppDiagLog.shutdown()` and leaves a marker so a relaunch starts fresh.
- `ExportHelper` uses `UIActivityViewController`, which is the only UIKit bridge in the sample.
