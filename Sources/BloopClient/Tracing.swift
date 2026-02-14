import Foundation

// MARK: - Enums

public enum SpanType: String {
    case generation, tool, retrieval, custom
}

public enum SpanStatus: String {
    case ok, error
}

public enum TraceStatus: String {
    case running, completed, error
}

// MARK: - Span

public final class LLMSpan {
    public let id: String
    public let parentSpanId: String?
    public let spanType: SpanType
    public let name: String
    public let model: String?
    public let provider: String?
    public let startedAt: Int64
    public var input: String?
    public var metadata: [String: Any]?

    public private(set) var inputTokens: Int?
    public private(set) var outputTokens: Int?
    public private(set) var cost: Double?
    public private(set) var latencyMs: Int?
    public private(set) var timeToFirstTokenMs: Int?
    public private(set) var status: SpanStatus?
    public private(set) var errorMessage: String?
    public private(set) var output: String?

    init(spanType: SpanType, name: String = "", model: String? = nil,
         provider: String? = nil, input: String? = nil,
         metadata: [String: Any]? = nil, parentSpanId: String? = nil) {
        self.id = UUID().uuidString.lowercased()
        self.parentSpanId = parentSpanId
        self.spanType = spanType
        self.name = name
        self.model = model
        self.provider = provider
        self.input = input
        self.metadata = metadata
        self.startedAt = Int64(Date().timeIntervalSince1970 * 1000)
    }

    public func end(
        inputTokens: Int? = nil, outputTokens: Int? = nil, cost: Double? = nil,
        status: SpanStatus = .ok, errorMessage: String? = nil, output: String? = nil,
        timeToFirstTokenMs: Int? = nil
    ) {
        self.latencyMs = Int(Int64(Date().timeIntervalSince1970 * 1000) - startedAt)
        self.status = status
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cost = cost
        self.errorMessage = errorMessage
        self.output = output
        self.timeToFirstTokenMs = timeToFirstTokenMs
    }

    public func setUsage(inputTokens: Int? = nil, outputTokens: Int? = nil, cost: Double? = nil) {
        if let t = inputTokens { self.inputTokens = t }
        if let t = outputTokens { self.outputTokens = t }
        if let c = cost { self.cost = c }
    }

    func toDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "id": id, "span_type": spanType.rawValue, "name": name,
            "started_at": startedAt, "status": (status ?? .ok).rawValue,
        ]
        if let v = parentSpanId { d["parent_span_id"] = v }
        if let v = model { d["model"] = v }
        if let v = provider { d["provider"] = v }
        if let v = inputTokens { d["input_tokens"] = v }
        if let v = outputTokens { d["output_tokens"] = v }
        if let v = cost { d["cost"] = v }
        if let v = latencyMs { d["latency_ms"] = v }
        if let v = timeToFirstTokenMs { d["time_to_first_token_ms"] = v }
        if let v = errorMessage { d["error_message"] = v }
        if let v = input { d["input"] = v }
        if let v = output { d["output"] = v }
        if let v = metadata { d["metadata"] = v }
        return d
    }
}

// MARK: - Trace

public final class LLMTrace {
    public let id: String
    public let name: String
    public let sessionId: String?
    public let userId: String?
    public let startedAt: Int64
    public var input: String?
    public var metadata: [String: Any]?
    public var promptName: String?
    public var promptVersion: String?

    public private(set) var status: TraceStatus = .running
    public private(set) var output: String?
    public private(set) var endedAt: Int64?
    public private(set) var spans: [LLMSpan] = []

    private weak var client: BloopClient?

    init(client: BloopClient, name: String, sessionId: String? = nil,
         userId: String? = nil, input: String? = nil,
         metadata: [String: Any]? = nil, promptName: String? = nil,
         promptVersion: String? = nil) {
        self.id = UUID().uuidString.lowercased()
        self.client = client
        self.name = name
        self.sessionId = sessionId
        self.userId = userId
        self.input = input
        self.metadata = metadata
        self.promptName = promptName
        self.promptVersion = promptVersion
        self.startedAt = Int64(Date().timeIntervalSince1970 * 1000)
    }

    public func startSpan(
        spanType: SpanType, name: String = "", model: String? = nil,
        provider: String? = nil, input: String? = nil,
        metadata: [String: Any]? = nil, parentSpanId: String? = nil
    ) -> LLMSpan {
        let span = LLMSpan(spanType: spanType, name: name, model: model,
                           provider: provider, input: input, metadata: metadata,
                           parentSpanId: parentSpanId)
        spans.append(span)
        return span
    }

    public func end(status: TraceStatus = .completed, output: String? = nil) {
        self.endedAt = Int64(Date().timeIntervalSince1970 * 1000)
        self.status = status
        if let o = output { self.output = o }
        client?.enqueueTrace(self)
    }

    func toDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "id": id, "name": name, "status": status.rawValue,
            "started_at": startedAt,
            "spans": spans.map { $0.toDictionary() },
        ]
        if let v = sessionId { d["session_id"] = v }
        if let v = userId { d["user_id"] = v }
        if let v = input { d["input"] = v }
        if let v = output { d["output"] = v }
        if let v = metadata { d["metadata"] = v }
        if let v = promptName { d["prompt_name"] = v }
        if let v = promptVersion { d["prompt_version"] = v }
        if let v = endedAt { d["ended_at"] = v }
        return d
    }
}
