import Foundation
import SwiftUI
import AppDiagLog

struct LoggingView: View {
    @State private var sessionTag = "checkout-crash-repro"
    @State private var actionLog = [LogEntry("Ready for manual logging.")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Send realistic manual events and tag the current session for easier triage.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                VStack(spacing: 12) {
                    actionButton(title: "Debug: Cache Hit", systemImage: "ladybug", tint: .teal) {
                        AppDiagLog.debug(
                            "cache_lookup_debug",
                            ["cache": "user_profile", "result": "hit", "source": "ios_uikit_sample"]
                        )
                        appendAction("Logged debug cache lookup event.")
                    }

                    actionButton(title: "Info: Checkout Started", systemImage: "cart", tint: .blue) {
                        AppDiagLog.info(
                            "checkout_started",
                            ["step": "shipping", "flow": "guest", "source": "ios_uikit_sample"]
                        )
                        appendAction("Logged info checkout start event.")
                    }

                    actionButton(title: "Warning: Slow Render", systemImage: "exclamationmark.triangle", tint: .orange) {
                        AppDiagLog.warning(
                            "slow_render_warning",
                            ["screen": "ProductList", "frame_ms": "42", "source": "ios_uikit_sample"]
                        )
                        appendAction("Logged warning slow render event.")
                    }

                    actionButton(title: "Error: Payment Failure", systemImage: "xmark.octagon", tint: .red) {
                        AppDiagLog.error(
                            "payment_authorization_failed",
                            ["status": "500", "provider": "sandbox", "source": "ios_uikit_sample"]
                        )
                        appendAction("Logged error payment failure event.")
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Session Tagging")
                        .font(.headline)

                    TextField("Describe the repro", text: $sessionTag)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    Button {
                        let trimmed = sessionTag.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        AppDiagLog.tagSession(trimmed)
                        appendAction("Tagged current session as “\(trimmed)”.")
                    } label: {
                        Label("Tag Session", systemImage: "tag")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sessionTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent Actions")
                        .font(.headline)

                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(actionLog) {
                            Text($0.message)
                                .font(.footnote.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }

    private func appendAction(_ message: String) {
        actionLog.append(message, maxEntries: 20)
    }
}
