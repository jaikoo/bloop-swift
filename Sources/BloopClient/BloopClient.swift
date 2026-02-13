import Foundation
import CommonCrypto

/// Lightweight bloop error reporting client for iOS/macOS.
/// Zero external dependencies.
public final class BloopClient {
    public static var shared: BloopClient?

    private let endpoint: URL
    private let secret: String
    private let projectKey: String?
    private let source: String
    private let environment: String
    private let release: String
    private let appVersion: String?
    private let buildNumber: String?

    private let session = URLSession(configuration: {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return config
    }())

    private var buffer: [ErrorEvent] = []
    private let bufferLock = NSLock()
    private let maxBufferSize: Int
    private let flushInterval: TimeInterval
    private var flushTimer: Timer?

    // MARK: - Init

    public init(
        endpoint: String,
        secret: String,
        projectKey: String? = nil,
        source: String = "ios",
        environment: String,
        release: String,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        maxBufferSize: Int = 20,
        flushInterval: TimeInterval = 5.0
    ) {
        self.endpoint = URL(string: endpoint)!
        self.secret = secret
        self.projectKey = projectKey
        self.source = source
        self.environment = environment
        self.release = release
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.maxBufferSize = maxBufferSize
        self.flushInterval = flushInterval

        startFlushTimer()
    }

    /// Configure the shared instance. Call once at app startup.
    public static func configure(
        endpoint: String,
        secret: String,
        projectKey: String? = nil,
        environment: String,
        release: String,
        appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        buildNumber: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    ) {
        shared = BloopClient(
            endpoint: endpoint,
            secret: secret,
            projectKey: projectKey,
            environment: environment,
            release: release,
            appVersion: appVersion,
            buildNumber: buildNumber
        )
    }

    // MARK: - Capture

    /// Capture an error with optional context.
    public func capture(
        _ error: Error,
        errorType: String? = nil,
        route: String? = nil,
        screen: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        let event = ErrorEvent(
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            source: source,
            environment: environment,
            release: release,
            appVersion: appVersion,
            buildNumber: buildNumber,
            routeOrProcedure: route,
            screen: screen,
            errorType: errorType ?? String(describing: type(of: error)),
            message: error.localizedDescription,
            stack: Thread.callStackSymbols.joined(separator: "\n"),
            metadata: metadata
        )
        enqueue(event)
    }

    /// Capture a raw error message.
    public func capture(
        message: String,
        errorType: String,
        route: String? = nil,
        screen: String? = nil,
        stack: String? = nil,
        httpStatus: Int? = nil,
        requestId: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        let event = ErrorEvent(
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            source: source,
            environment: environment,
            release: release,
            appVersion: appVersion,
            buildNumber: buildNumber,
            routeOrProcedure: route,
            screen: screen,
            errorType: errorType,
            message: message,
            stack: stack ?? Thread.callStackSymbols.joined(separator: "\n"),
            httpStatus: httpStatus,
            requestId: requestId,
            metadata: metadata
        )
        enqueue(event)
    }

    /// Flush buffered events immediately.
    public func flush() {
        let events: [ErrorEvent]
        bufferLock.lock()
        events = buffer
        buffer.removeAll()
        bufferLock.unlock()

        guard !events.isEmpty else { return }
        sendBatch(events)
    }

    // MARK: - Private

    private func enqueue(_ event: ErrorEvent) {
        bufferLock.lock()
        buffer.append(event)
        let shouldFlush = buffer.count >= maxBufferSize
        bufferLock.unlock()

        if shouldFlush {
            flush()
        }
    }

    private func startFlushTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: self.flushInterval, repeats: true) { [weak self] _ in
                self?.flush()
            }
        }
    }

    private func sendBatch(_ events: [ErrorEvent]) {
        let payload: [String: Any] = [
            "events": events.map { $0.toDictionary() }
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let signature = hmacSHA256(data: body, key: secret)

        var request = URLRequest(url: endpoint.appendingPathComponent("/v1/ingest/batch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
        if let projectKey {
            request.setValue(projectKey, forHTTPHeaderField: "X-Project-Key")
        }
        request.httpBody = body

        session.dataTask(with: request) { _, response, error in
            if let error {
                // Silently fail - error reporting shouldn't crash the app
                #if DEBUG
                print("[bloop] send failed: \(error.localizedDescription)")
                #endif
            }
        }.resume()
    }

    private func hmacSHA256(data: Data, key: String) -> String {
        let keyData = key.data(using: .utf8)!
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

        keyData.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBytes.baseAddress, keyData.count,
                    dataBytes.baseAddress, data.count,
                    &digest
                )
            }
        }

        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Event Type

private struct ErrorEvent {
    let timestamp: Int64
    let source: String
    let environment: String
    let release: String
    let appVersion: String?
    let buildNumber: String?
    let routeOrProcedure: String?
    let screen: String?
    let errorType: String
    let message: String
    let stack: String?
    let httpStatus: Int?
    let requestId: String?
    let metadata: [String: Any]?

    init(
        timestamp: Int64, source: String, environment: String, release: String,
        appVersion: String?, buildNumber: String?, routeOrProcedure: String?,
        screen: String?, errorType: String, message: String, stack: String? = nil,
        httpStatus: Int? = nil, requestId: String? = nil, metadata: [String: Any]? = nil
    ) {
        self.timestamp = timestamp
        self.source = source
        self.environment = environment
        self.release = release
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.routeOrProcedure = routeOrProcedure
        self.screen = screen
        self.errorType = errorType
        self.message = message
        self.stack = stack
        self.httpStatus = httpStatus
        self.requestId = requestId
        self.metadata = metadata
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "timestamp": timestamp,
            "source": source,
            "environment": environment,
            "release": release,
            "error_type": errorType,
            "message": message,
        ]
        if let v = appVersion { dict["app_version"] = v }
        if let v = buildNumber { dict["build_number"] = v }
        if let v = routeOrProcedure { dict["route_or_procedure"] = v }
        if let v = screen { dict["screen"] = v }
        if let v = stack { dict["stack"] = String(v.prefix(8192)) }
        if let v = httpStatus { dict["http_status"] = v }
        if let v = requestId { dict["request_id"] = v }
        if let v = metadata { dict["metadata"] = v }
        return dict
    }
}
