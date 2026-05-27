import Foundation

/// Lazy-initializes auto-trackers based on `AppDiagLogConfig.autoTrack`. Disabled
/// trackers never allocate, keeping steady-state memory footprint tight.
actor AutoTrackRegistry {
    private let runtime: AppDiagLogRuntime
    private var trackers: [any Tracker] = []

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        let cfg = runtime.config.autoTrack

        // Order matters: AppLifecycleTracker drives session rotation, so it must be
        // installed before any tracker that may emit events on background/foreground.
        if cfg.appLifecycle {
            await register(AppLifecycleTracker(runtime: runtime))
        }
        #if os(iOS) || os(tvOS)
        if cfg.screenViews != nil {
            await register(ScreenTracker(runtime: runtime))
        }
        if cfg.taps {
            await register(TapTracker(runtime: runtime))
        }
        #endif
        if cfg.apiCalls {
            await register(URLProtocolTracker(runtime: runtime))
        }
        if cfg.crashes {
            await register(CrashTracker(runtime: runtime))
        }
        if cfg.connectivity {
            await register(ConnectivityTracker(runtime: runtime))
        }
        if cfg.deepLinks {
            await register(DeepLinkTracker(runtime: runtime))
        }
        #if os(iOS)
        if cfg.batteryThermal {
            await register(BatteryTracker(runtime: runtime))
        }
        #endif

        #if canImport(UIKit) && !os(watchOS)
        if cfg.memoryPressure {
            await register(MemoryPressureTracker(runtime: runtime))
        }
        #endif

        #if os(iOS)
        if let permConfig = cfg.permissionChanges {
            await register(PermissionChangeTracker(runtime: runtime, config: permConfig))
        }
        if cfg.pushNotifications {
            await register(PushNotificationTracker(runtime: runtime))
        }
        #if canImport(WebKit)
        if cfg.webViews {
            await register(WebViewTracker(runtime: runtime))
        }
        #endif
        if cfg.backgroundTasks {
            await register(BackgroundTaskTracker(runtime: runtime))
        }
        #endif

        if cfg.preferenceChanges {
            await register(PreferenceChangeTracker(runtime: runtime))
        }

        if cfg.deviceSnapshot {
            // One-shot event at session start. Not a tracker.
            await emitDeviceSnapshot()
        }
    }

    func stop() async {
        for tracker in trackers {
            await tracker.stop()
        }
        trackers.removeAll()
    }

    private func register(_ tracker: any Tracker) async {
        await tracker.start()
        trackers.append(tracker)
        SdkLog.debug("tracker started: \(type(of: tracker))")
    }

    private func emitDeviceSnapshot() async {
        let snapshot = await DeviceSnapshot.capture()
        await runtime.pipeline.enqueue(
            event: EventName.deviceSnapshot,
            level: .info,
            props: snapshot
        )
    }
}
