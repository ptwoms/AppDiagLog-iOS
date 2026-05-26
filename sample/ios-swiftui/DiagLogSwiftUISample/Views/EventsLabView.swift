import SwiftUI
import AppDiagLog

struct EventsLabView: View {
    @State private var eventsFired = 0
    @State private var batchSize = 50
    @State private var actionLog = [LogEntry("Ready to fire events.")]

    var body: some View {
        NavigationStack {
            List {
                Section("Domain Event Scenarios") {
                    Text("Tap any scenario to emit a realistic event with meaningful props. Inspect the decrypted session to verify the payload structure.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    eventButton("User Login", icon: "person.fill.checkmark", tint: .blue) {
                        AppDiagLog.info("user_login", ["method": "email", "duration_ms": "120", "source": "events_lab"])
                        appendAction("INFO user_login method=email")
                    }
                    eventButton("Cart Add Item", icon: "cart.badge.plus", tint: .green) {
                        AppDiagLog.info("cart_add_item", ["sku": "ITEM-42", "qty": "1", "price": "29.99", "currency": "USD"])
                        appendAction("INFO cart_add_item sku=ITEM-42")
                    }
                    eventButton("Feature Flag Check", icon: "flag", tint: .teal) {
                        AppDiagLog.debug("feature_flag_check", ["flag": "new_checkout_flow", "result": "enabled", "source": "events_lab"])
                        appendAction("DEBUG feature_flag_check flag=new_checkout_flow")
                    }
                    eventButton("Search Performed", icon: "magnifyingglass", tint: .purple) {
                        AppDiagLog.info("search_performed", ["query_hash": "abc123", "result_count": "42"])
                        appendAction("INFO search_performed results=42")
                    }
                    eventButton("Push Notification Tapped", icon: "bell.badge", tint: .indigo) {
                        AppDiagLog.info("push_notification_tapped", ["type": "promo", "campaign": "spring_sale"])
                        appendAction("INFO push_notification_tapped campaign=spring_sale")
                    }
                    eventButton("API Retry Warning", icon: "arrow.clockwise.circle", tint: .orange) {
                        AppDiagLog.warning("api_retry", ["endpoint": "/api/cart", "attempt": "2", "reason": "timeout"])
                        appendAction("WARNING api_retry attempt=2 reason=timeout")
                    }
                    eventButton("IAP Purchase Attempted", icon: "dollarsign.circle", tint: .orange) {
                        AppDiagLog.warning("iap_purchase_attempt", ["product_id": "premium_monthly", "source": "onboarding"])
                        appendAction("WARNING iap_purchase_attempt product=premium_monthly")
                    }
                    eventButton("Checkout Payment Failed", icon: "xmark.circle", tint: .red) {
                        AppDiagLog.error("checkout_payment_failed", ["step": "payment", "provider": "stripe_sandbox", "code": "insufficient_funds"])
                        appendAction("ERROR checkout_payment_failed code=insufficient_funds")
                    }
                }

                Section("Batch Logging") {
                    Text("Fire N debug events in rapid succession to observe the in-memory buffer, flush coalescing, and the periodic \(SampleConfiguration.flushIntervalMillis / 1_000)-second flush.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Stepper("Batch size: \(batchSize)", value: $batchSize, in: 1...500)

                    Button {
                        for i in 0..<batchSize {
                            AppDiagLog.debug("batch_event", ["index": "\(i)", "batch_size": "\(batchSize)"])
                        }
                        eventsFired += batchSize
                        appendAction("Fired \(batchSize) batch_event events.")
                    } label: {
                        Label("Fire Batch", systemImage: "bolt.fill")
                    }

                    Text("Total events fired this tab: \(eventsFired)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Rate Limiter Demo") {
                    Text("Fire 200 events immediately. The SDK allows max \(SampleConfiguration.maxEventsPerSecond) events/s — events beyond the cap are silently dropped so the host app is never starved.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        for i in 0..<200 {
                            AppDiagLog.info("rate_limiter_probe", ["index": "\(i)"])
                        }
                        eventsFired += 200
                        appendAction("Fired 200 rate_limiter_probe events (≤\(SampleConfiguration.maxEventsPerSecond)/s accepted).")
                    } label: {
                        Label("Fire 200 Events", systemImage: "gauge.with.needle")
                    }
                }

                Section("Recent Actions") {
                    ForEach(actionLog) { action in
                        Text(action.message)
                            .font(.footnote.monospaced())
                    }
                }
            }
            .navigationTitle("Events Lab")
        }
        .trackScreen("EventsLabView")
    }

    @ViewBuilder
    private func eventButton(
        _ title: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .tint(tint)
    }

    private func appendAction(_ message: String) {
        actionLog.append(message, maxEntries: 20)
    }
}
