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
    private var lifecycleObservers: [NSObjectProtocol] = []

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

    // MARK: - Crash & Lifecycle Handlers

    /// Install a handler for uncaught Objective-C exceptions.
    /// Captures the exception with stack trace and performs a synchronous flush.
    public func installCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            guard let client = BloopClient.shared else { return }
            let stack = exception.callStackSymbols.joined(separator: "\n")
            client.capture(
                message: exception.reason ?? exception.name.rawValue,
                errorType: exception.name.rawValue,
                stack: stack,
                metadata: ["unhandled": true, "mechanism": "NSUncaughtExceptionHandler"]
            )
            client.flushSync()
        }
    }

    /// Install lifecycle observers that flush events on app background/termination.
    /// On iOS: flushes on didEnterBackground, flushSync on willTerminate.
    /// On macOS: flushSync on willTerminate.
    public func installLifecycleHandlers() {
        let center = NotificationCenter.default

        #if canImport(UIKit)
        if let bgName = NSNotification.Name(rawValue: "UIApplicationDidEnterBackgroundNotification") as NSNotification.Name? {
            let bgObserver = center.addObserver(forName: bgName, object: nil, queue: .main) { [weak self] _ in
                self?.flush()
            }
            lifecycleObservers.append(bgObserver)
        }
        if let termName = NSNotification.Name(rawValue: "UIApplicationWillTerminateNotification") as NSNotification.Name? {
            let termObserver = center.addObserver(forName: termName, object: nil, queue: .main) { [weak self] _ in
                self?.flushSync()
            }
            lifecycleObservers.append(termObserver)
        }
        #elseif canImport(AppKit)
        let termObserver = center.addObserver(forName: NSNotification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: .main) { [weak self] _ in
            self?.flushSync()
        }
        lifecycleObservers.append(termObserver)
        #endif
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
        let deviceMeta = Self.deviceInfo()
        var mergedMeta = deviceMeta
        if let m = metadata { mergedMeta.merge(m) { _, user in user } }

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
            metadata: mergedMeta
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
        let deviceMeta = Self.deviceInfo()
        var mergedMeta = deviceMeta
        if let m = metadata { mergedMeta.merge(m) { _, user in user } }

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
            metadata: mergedMeta
        )
        enqueue(event)
    }

    /// Flush buffered events immediately (asynchronous network send).
    public func flush() {
        let events: [ErrorEvent]
        bufferLock.lock()
        events = buffer
        buffer.removeAll()
        bufferLock.unlock()

        guard !events.isEmpty else { return }
        sendBatch(events)
    }

    /// Flush buffered events synchronously. Use in crash handlers and app termination
    /// where async network calls won't complete.
    public func flushSync() {
        let events: [ErrorEvent]
        bufferLock.lock()
        events = buffer
        buffer.removeAll()
        bufferLock.unlock()

        guard !events.isEmpty else { return }
        sendBatchSync(events)
    }

    /// Invalidate the flush timer, flush remaining events synchronously, and clean up lifecycle observers.
    public func close() {
        flushTimer?.invalidate()
        flushTimer = nil
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        flushSync()
    }

    // MARK: - Device Info

    /// Collect device model, OS name, and OS version using sysctlbyname and platform APIs.
    public static func deviceInfo() -> [String: Any] {
        var info: [String: Any] = [:]
        info["device_model"] = machineModel()

        #if canImport(UIKit)
        // UIDevice is available — use string-based class lookup to avoid direct import
        if let deviceClass = NSClassFromString("UIDevice") as? NSObject.Type,
           let device = deviceClass.value(forKeyPath: "currentDevice") as? NSObject {
            info["os_name"] = device.value(forKey: "systemName") as? String ?? "iOS"
            info["os_version"] = device.value(forKey: "systemVersion") as? String
        }
        #else
        let processInfo = ProcessInfo.processInfo
        info["os_name"] = "macOS"
        info["os_version"] = processInfo.operatingSystemVersionString
        #endif

        return info
    }

    // MARK: - Private

    private static func machineModel() -> String {
        var size: Int = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

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

    /// Synchronous network send with a 3-second timeout.
    /// Essential for crash paths where async won't complete.
    private func sendBatchSync(_ events: [ErrorEvent]) {
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

        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3.0)
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
