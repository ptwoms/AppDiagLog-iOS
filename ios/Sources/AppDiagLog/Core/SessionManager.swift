import Foundation

/// Owns session lifecycle, eviction triggering, and crash recovery.
///
/// Actor-isolated — all mutations serialize. Public reads (currentSessionId) are exposed
/// via an async method; the [LogPipeline] caches the id in a lock-protected holder for
/// zero-hop reads on the hot path.
actor SessionManager {
    private let config: AppDiagLogConfig
    private let pqcProvider: PQCProvider
    private let indexStore: SessionIndexStore
    private let fileWriter: SessionFileWriter
    private let eviction: EvictionPolicy
    private let deviceMetadata: @Sendable () async -> [String: String]
    private let sessionIdHolder: SessionIdHolder

    private var index: SessionIndex
    private var current: State?

    struct State {
        let id: String
        let createdAt: String
        let crypto: SessionCryptoMaterial
        var sessionTag: String?
        var backgroundedAt: Date?
    }

    init(
        config: AppDiagLogConfig,
        pqcProvider: PQCProvider,
        indexStore: SessionIndexStore,
        fileWriter: SessionFileWriter,
        eviction: EvictionPolicy,
        deviceMetadata: @escaping @Sendable () async -> [String: String],
        sessionIdHolder: SessionIdHolder
    ) {
        self.config = config
        self.pqcProvider = pqcProvider
        self.indexStore = indexStore
        self.fileWriter = fileWriter
        self.eviction = eviction
        self.deviceMetadata = deviceMetadata
        self.sessionIdHolder = sessionIdHolder
        self.index = SessionIndex(maxSessions: config.maxSessions)
    }

    func bootstrap() async {
        index = await indexStore.load()
        let recovered = sealUnsealedSessions()
        if recovered > 0 {
            SdkLog.debug("recovered \(recovered) unsealed session(s) from prior run")
            await indexStore.persist(index)
        }
    }

    func ensureSession() async -> State? {
        if let c = current { return c }
        return await startNewSession()
    }

    func markBackgrounded(with pending: [EventEnvelope]) async {
        guard var s = current else { return }
        s.backgroundedAt = Date()
        current = s
        if !pending.isEmpty {
            await persistCurrent(pending: pending, sealing: false)
        }
    }

    /// Returns (state, rotated) — rotated==true means a new session id was assigned.
    func maybeResumeOrRotate() async -> (State, Bool)? {
        if var s = current {
            if let bg = s.backgroundedAt {
                let elapsed = Date().timeIntervalSince(bg)
                if elapsed > Double(config.sessionTimeoutMinutes) * 60 {
                    await sealSession(state: s, pending: [])
                    guard let next = await startNewSession() else { return nil }
                    return (next, true)
                }
            }
            s.backgroundedAt = nil
            current = s
            return (s, false)
        }
        guard let next = await startNewSession() else { return nil }
        return (next, true)
    }

    func sealCurrent(pending: [EventEnvelope]) async {
        guard let s = current else { return }
        await sealSession(state: s, pending: pending)
    }

    func tagSession(_ label: String) async {
        guard var s = current else { return }
        s.sessionTag = label
        current = s
        index.update(id: s.id) { $0.sessionTag = label }
        await indexStore.persist(index)
    }

    func persistCurrent(pending: [EventEnvelope], sealing: Bool = false) async {
        guard let s = current else { return }
        await persistToDisk(state: s, events: pending, sealing: sealing)
    }

    // MARK: - internal

    private func startNewSession() async -> State? {
        let id = UUID().uuidString
        let createdAt = self.nowIso
        do {
            let crypto = try SessionCryptoMaterial.generate(
                key: config.keyWrap,
                symmetric: config.symmetric,
                pqcProvider: pqcProvider
            )
            let state = State(id: id, createdAt: createdAt, crypto: crypto, sessionTag: nil, backgroundedAt: nil)
            let size = (try? await fileWriter.write(.init(
                sessionId: id,
                createdAt: createdAt,
                sealedAt: nil,
                sessionTag: nil,
                deviceMetadata: deviceMetadata(),
                crypto: crypto,
                events: []
            ))) ?? 0
            index.sessions.append(SessionIndex.Entry(
                id: id,
                createdAt: createdAt,
                sealed: false,
                fileSizeBytes: size
            ))
            eviction.apply(&index)
            await indexStore.persist(index)
            current = state
            sessionIdHolder.set(id)
            return state
        } catch {
            SdkLog.error("failed to start session", error: error)
            return nil
        }
    }

    private func sealSession(state: State, pending: [EventEnvelope]) async {
        await persistToDisk(state: state, events: pending, sealing: true)
        index.update(id: state.id) { entry in
            entry.sealed = true
            entry.sealedAt = self.nowIso
        }
        state.crypto.wipe()
        current = nil
        sessionIdHolder.set(nil)
        await indexStore.persist(index)
    }

    private func persistToDisk(state: State, events: [EventEnvelope], sealing: Bool) async {
        do {
            let size = try await fileWriter.write(.init(
                sessionId: state.id,
                createdAt: state.createdAt,
                sealedAt: sealing ? self.nowIso : nil,
                sessionTag: state.sessionTag,
                deviceMetadata: deviceMetadata(),
                crypto: state.crypto,
                events: events
            ))
            index.update(id: state.id) { entry in
                entry.fileSizeBytes = size
                entry.eventCount = events.count
            }
            await indexStore.persist(index)
        } catch {
            SdkLog.error("persist failed for session \(state.id)", error: error)
        }
    }

    private func sealUnsealedSessions() -> Int {
        let now = self.nowIso
        var count = 0
        for i in index.sessions.indices where !index.sessions[i].sealed {
            index.sessions[i].sealed = true
            index.sessions[i].sealedAt = now
            count += 1
        }
        return count
    }
    
    private lazy var nowDateFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private var nowIso: String {
        return nowDateFormatter.string(from: Date())
    }
}

/// Cheap lock-guarded holder for current session id. Exposed so the logging hot path
/// can read without hopping into the SessionManager actor.
final class SessionIdHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ v: String?) { lock.lock(); value = v; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
