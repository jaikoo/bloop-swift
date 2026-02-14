import XCTest
@testable import BloopClient

final class TracingTests: XCTestCase {

    // MARK: - SpanType & SpanStatus & TraceStatus Enums

    func testSpanTypeRawValues() {
        XCTAssertEqual(SpanType.generation.rawValue, "generation")
        XCTAssertEqual(SpanType.tool.rawValue, "tool")
        XCTAssertEqual(SpanType.retrieval.rawValue, "retrieval")
        XCTAssertEqual(SpanType.custom.rawValue, "custom")
    }

    func testSpanStatusRawValues() {
        XCTAssertEqual(SpanStatus.ok.rawValue, "ok")
        XCTAssertEqual(SpanStatus.error.rawValue, "error")
    }

    func testTraceStatusRawValues() {
        XCTAssertEqual(TraceStatus.running.rawValue, "running")
        XCTAssertEqual(TraceStatus.completed.rawValue, "completed")
        XCTAssertEqual(TraceStatus.error.rawValue, "error")
    }

    // MARK: - LLMSpan Init

    func testSpanInitSetsFields() {
        let span = LLMSpan(
            spanType: .generation,
            name: "chat-completion",
            model: "gpt-4",
            provider: "openai",
            input: "Hello",
            metadata: ["key": "val"],
            parentSpanId: "parent-123"
        )

        XCTAssertFalse(span.id.isEmpty)
        XCTAssertEqual(span.spanType, .generation)
        XCTAssertEqual(span.name, "chat-completion")
        XCTAssertEqual(span.model, "gpt-4")
        XCTAssertEqual(span.provider, "openai")
        XCTAssertEqual(span.input, "Hello")
        XCTAssertEqual(span.parentSpanId, "parent-123")
        XCTAssertNotNil(span.metadata)
        XCTAssertTrue(span.startedAt > 0)

        // Not yet ended
        XCTAssertNil(span.status)
        XCTAssertNil(span.latencyMs)
        XCTAssertNil(span.inputTokens)
        XCTAssertNil(span.outputTokens)
        XCTAssertNil(span.cost)
        XCTAssertNil(span.output)
        XCTAssertNil(span.errorMessage)
        XCTAssertNil(span.timeToFirstTokenMs)
    }

    func testSpanInitDefaults() {
        let span = LLMSpan(spanType: .tool)

        XCTAssertEqual(span.name, "")
        XCTAssertNil(span.model)
        XCTAssertNil(span.provider)
        XCTAssertNil(span.input)
        XCTAssertNil(span.metadata)
        XCTAssertNil(span.parentSpanId)
    }

    func testSpanIdIsLowercaseUUID() {
        let span = LLMSpan(spanType: .custom)
        // UUID().uuidString.lowercased() produces lowercase hex with hyphens
        XCTAssertEqual(span.id, span.id.lowercased())
        XCTAssertEqual(span.id.count, 36) // UUID format: 8-4-4-4-12
    }

    // MARK: - LLMSpan.end()

    func testSpanEndSetsFields() {
        let span = LLMSpan(spanType: .generation, name: "test")

        // Small delay so latency > 0 is plausible (but don't rely on it being >0 in fast tests)
        span.end(
            inputTokens: 100,
            outputTokens: 50,
            cost: 0.003,
            status: .ok,
            errorMessage: nil,
            output: "response text",
            timeToFirstTokenMs: 200
        )

        XCTAssertEqual(span.status, .ok)
        XCTAssertEqual(span.inputTokens, 100)
        XCTAssertEqual(span.outputTokens, 50)
        XCTAssertEqual(span.cost, 0.003)
        XCTAssertEqual(span.output, "response text")
        XCTAssertEqual(span.timeToFirstTokenMs, 200)
        XCTAssertNil(span.errorMessage)
        XCTAssertNotNil(span.latencyMs)
        XCTAssertTrue(span.latencyMs! >= 0)
    }

    func testSpanEndWithError() {
        let span = LLMSpan(spanType: .generation, name: "fail-test")
        span.end(status: .error, errorMessage: "rate limit exceeded")

        XCTAssertEqual(span.status, .error)
        XCTAssertEqual(span.errorMessage, "rate limit exceeded")
    }

    func testSpanEndDefaultsToOk() {
        let span = LLMSpan(spanType: .generation, name: "default-status")
        span.end()

        XCTAssertEqual(span.status, .ok)
    }

    // MARK: - LLMSpan.setUsage()

    func testSetUsagePartial() {
        let span = LLMSpan(spanType: .generation)
        span.setUsage(inputTokens: 42)

        XCTAssertEqual(span.inputTokens, 42)
        XCTAssertNil(span.outputTokens)
        XCTAssertNil(span.cost)
    }

    func testSetUsageFull() {
        let span = LLMSpan(spanType: .generation)
        span.setUsage(inputTokens: 10, outputTokens: 20, cost: 0.001)

        XCTAssertEqual(span.inputTokens, 10)
        XCTAssertEqual(span.outputTokens, 20)
        XCTAssertEqual(span.cost, 0.001)
    }

    func testSetUsageOverwrites() {
        let span = LLMSpan(spanType: .generation)
        span.setUsage(inputTokens: 10)
        span.setUsage(inputTokens: 99)

        XCTAssertEqual(span.inputTokens, 99)
    }

    func testSetUsageNilDoesNotOverwrite() {
        let span = LLMSpan(spanType: .generation)
        span.setUsage(inputTokens: 10)
        span.setUsage() // all nil

        XCTAssertEqual(span.inputTokens, 10)
    }

    // MARK: - LLMSpan.toDictionary()

    func testSpanToDictionaryMinimal() {
        let span = LLMSpan(spanType: .tool, name: "search")
        let d = span.toDictionary()

        XCTAssertEqual(d["id"] as? String, span.id)
        XCTAssertEqual(d["span_type"] as? String, "tool")
        XCTAssertEqual(d["name"] as? String, "search")
        XCTAssertEqual(d["started_at"] as? Int64, span.startedAt)
        XCTAssertEqual(d["status"] as? String, "ok") // default when status is nil -> .ok

        // Optional fields should be absent
        XCTAssertNil(d["parent_span_id"])
        XCTAssertNil(d["model"])
        XCTAssertNil(d["provider"])
        XCTAssertNil(d["input_tokens"])
        XCTAssertNil(d["output_tokens"])
        XCTAssertNil(d["cost"])
        XCTAssertNil(d["latency_ms"])
        XCTAssertNil(d["time_to_first_token_ms"])
        XCTAssertNil(d["error_message"])
        XCTAssertNil(d["input"])
        XCTAssertNil(d["output"])
        XCTAssertNil(d["metadata"])
    }

    func testSpanToDictionaryFull() {
        let span = LLMSpan(
            spanType: .generation, name: "completion",
            model: "gpt-4", provider: "openai",
            input: "prompt", metadata: ["env": "test"],
            parentSpanId: "p1"
        )
        span.end(
            inputTokens: 100, outputTokens: 50, cost: 0.01,
            status: .error, errorMessage: "timeout",
            output: "partial", timeToFirstTokenMs: 150
        )

        let d = span.toDictionary()

        XCTAssertEqual(d["parent_span_id"] as? String, "p1")
        XCTAssertEqual(d["model"] as? String, "gpt-4")
        XCTAssertEqual(d["provider"] as? String, "openai")
        XCTAssertEqual(d["input_tokens"] as? Int, 100)
        XCTAssertEqual(d["output_tokens"] as? Int, 50)
        XCTAssertEqual(d["cost"] as? Double, 0.01)
        XCTAssertNotNil(d["latency_ms"])
        XCTAssertEqual(d["time_to_first_token_ms"] as? Int, 150)
        XCTAssertEqual(d["status"] as? String, "error")
        XCTAssertEqual(d["error_message"] as? String, "timeout")
        XCTAssertEqual(d["input"] as? String, "prompt")
        XCTAssertEqual(d["output"] as? String, "partial")
        XCTAssertNotNil(d["metadata"])
    }

    // MARK: - LLMTrace Init

    func testTraceInitSetsFields() {
        let client = BloopClient(
            endpoint: "https://example.com",
            secret: "test-secret",
            environment: "test",
            release: "1.0"
        )

        let trace = client.startTrace(
            name: "chat-flow",
            sessionId: "sess-1",
            userId: "user-42",
            input: "hello",
            metadata: ["source": "ios"],
            promptName: "greet",
            promptVersion: "v2"
        )

        XCTAssertFalse(trace.id.isEmpty)
        XCTAssertEqual(trace.id, trace.id.lowercased())
        XCTAssertEqual(trace.name, "chat-flow")
        XCTAssertEqual(trace.sessionId, "sess-1")
        XCTAssertEqual(trace.userId, "user-42")
        XCTAssertEqual(trace.input, "hello")
        XCTAssertEqual(trace.promptName, "greet")
        XCTAssertEqual(trace.promptVersion, "v2")
        XCTAssertTrue(trace.startedAt > 0)
        XCTAssertEqual(trace.status, .running)
        XCTAssertNil(trace.output)
        XCTAssertNil(trace.endedAt)
        XCTAssertTrue(trace.spans.isEmpty)
    }

    // MARK: - LLMTrace.startSpan()

    func testTraceStartSpanAddsToSpans() {
        let client = BloopClient(
            endpoint: "https://example.com",
            secret: "test-secret",
            environment: "test",
            release: "1.0"
        )
        let trace = client.startTrace(name: "flow")

        let span1 = trace.startSpan(spanType: .generation, name: "llm-call", model: "gpt-4")
        let span2 = trace.startSpan(spanType: .tool, name: "search", parentSpanId: span1.id)

        XCTAssertEqual(trace.spans.count, 2)
        XCTAssertEqual(trace.spans[0].id, span1.id)
        XCTAssertEqual(trace.spans[1].id, span2.id)
        XCTAssertEqual(span2.parentSpanId, span1.id)
    }

    // MARK: - LLMTrace.end()

    func testTraceEndSetsStatusAndOutput() {
        let client = BloopClient(
            endpoint: "https://example.com",
            secret: "test-secret",
            environment: "test",
            release: "1.0"
        )
        let trace = client.startTrace(name: "flow")

        trace.end(status: .completed, output: "done")

        XCTAssertEqual(trace.status, .completed)
        XCTAssertEqual(trace.output, "done")
        XCTAssertNotNil(trace.endedAt)
        XCTAssertTrue(trace.endedAt! >= trace.startedAt)
    }

    func testTraceEndDefaultsToCompleted() {
        let client = BloopClient(
            endpoint: "https://example.com",
            secret: "test-secret",
            environment: "test",
            release: "1.0"
        )
        let trace = client.startTrace(name: "flow")
        trace.end()

        XCTAssertEqual(trace.status, .completed)
    }

    // MARK: - LLMTrace.toDictionary()

    func testTraceToDictionaryMinimal() {
        let client = BloopClient(
            endpoint: "https://example.com",
            secret: "test-secret",
            environment: "test",
            release: "1.0"
        )
        let trace = client.startTrace(name: "simple")
        let d = trace.toDictionary()

        XCTAssertEqual(d["id"] as? String, trace.id)
        XCTAssertEqual(d["name"] as? String, "simple")
        XCTAssertEqual(d["status"] as? String, "running")
        XCTAssertEqual(d["started_at"] as? Int64, trace.startedAt)
        XCTAssertNotNil(d["spans"] as? [[String: Any]])
        XCTAssertTrue((d["spans"] as! [[String: Any]]).isEmpty)

        XCTAssertNil(d["session_id"])
        XCTAssertNil(d["user_id"])
        XCTAssertNil(d["input"])
        XCTAssertNil(d["output"])
        XCTAssertNil(d["metadata"])
        XCTAssertNil(d["prompt_name"])
        XCTAssertNil(d["prompt_version"])
        XCTAssertNil(d["ended_at"])
    }

    func testTraceToDictionaryFull() {
        let client = BloopClient(
            endpoint: "https://example.com",
            secret: "test-secret",
            environment: "test",
            release: "1.0"
        )
        let trace = client.startTrace(
            name: "full", sessionId: "s1", userId: "u1",
            input: "in", metadata: ["k": "v"],
            promptName: "pn", promptVersion: "pv"
        )
        let span = trace.startSpan(spanType: .generation, name: "llm")
        span.end(inputTokens: 10)
        trace.end(status: .completed, output: "out")

        let d = trace.toDictionary()

        XCTAssertEqual(d["session_id"] as? String, "s1")
        XCTAssertEqual(d["user_id"] as? String, "u1")
        XCTAssertEqual(d["input"] as? String, "in")
        XCTAssertEqual(d["output"] as? String, "out")
        XCTAssertEqual(d["prompt_name"] as? String, "pn")
        XCTAssertEqual(d["prompt_version"] as? String, "pv")
        XCTAssertNotNil(d["ended_at"])
        XCTAssertEqual(d["status"] as? String, "completed")

        let spans = d["spans"] as! [[String: Any]]
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0]["name"] as? String, "llm")
    }

    // MARK: - Trace serializes to valid JSON

    func testTraceToDictionaryIsJSONSerializable() {
        let client = BloopClient(
            endpoint: "https://example.com",
            secret: "test-secret",
            environment: "test",
            release: "1.0"
        )
        let trace = client.startTrace(name: "json-test", input: "hi")
        let span = trace.startSpan(spanType: .generation, name: "gen", model: "gpt-4")
        span.end(inputTokens: 5, outputTokens: 10, cost: 0.001)
        trace.end(output: "bye")

        let dict = trace.toDictionary()
        let payload: [String: Any] = ["traces": [dict]]

        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        let data = try! JSONSerialization.data(withJSONObject: payload)
        XCTAssertTrue(data.count > 0)
    }

    // MARK: - BloopClient.startTrace() returns LLMTrace

    func testClientStartTraceReturnsTrace() {
        let client = BloopClient(
            endpoint: "https://example.com",
            secret: "test-secret",
            environment: "test",
            release: "1.0"
        )
        let trace = client.startTrace(name: "test-trace")
        XCTAssertTrue(trace is LLMTrace)
        XCTAssertEqual(trace.name, "test-trace")
    }

    // MARK: - enqueueTrace (internal) adds to buffer

    func testEnqueueTraceAddsToBuffer() {
        let client = BloopClient(
            endpoint: "https://example.com",
            secret: "test-secret",
            environment: "test",
            release: "1.0",
            maxBufferSize: 100 // high threshold so no auto-flush
        )
        let trace = client.startTrace(name: "buffered")
        trace.end()

        // After trace.end(), enqueueTrace is called internally.
        // We can verify by calling flushSync() and checking it doesn't crash.
        // (Full network verification would need a mock, but structural test is valid.)
        client.flushSync()
    }

    // MARK: - End-to-end: trace -> span -> end -> flush

    func testEndToEndTraceFlowDoesNotCrash() {
        let client = BloopClient(
            endpoint: "https://example.com",
            secret: "test-secret",
            environment: "test",
            release: "1.0"
        )

        let trace = client.startTrace(
            name: "e2e-trace",
            sessionId: "sess",
            userId: "user"
        )

        let span1 = trace.startSpan(
            spanType: .generation, name: "llm-call",
            model: "claude-3", provider: "anthropic",
            input: "What is 2+2?"
        )
        span1.end(
            inputTokens: 10, outputTokens: 5, cost: 0.0001,
            status: .ok, output: "4"
        )

        let span2 = trace.startSpan(
            spanType: .tool, name: "calculator",
            parentSpanId: span1.id
        )
        span2.end(status: .ok, output: "4")

        trace.end(status: .completed, output: "The answer is 4")

        // Verify serialization is complete
        let d = trace.toDictionary()
        XCTAssertEqual((d["spans"] as! [[String: Any]]).count, 2)

        // Flush should not crash
        client.flush()
        client.close()
    }

    // MARK: - Span metadata toDictionary with nested metadata

    func testSpanMetadataSerializesToDictionary() {
        let span = LLMSpan(
            spanType: .retrieval,
            name: "vector-search",
            metadata: ["query": "test", "top_k": 5]
        )
        let d = span.toDictionary()
        let meta = d["metadata"] as! [String: Any]
        XCTAssertEqual(meta["query"] as? String, "test")
        XCTAssertEqual(meta["top_k"] as? Int, 5)
    }
}
