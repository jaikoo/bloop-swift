# BloopClient (Swift)

Swift error tracking SDK for [Bloop](https://github.com/jaikoo/eewwror) — self-hosted error tracking.

## Install (Swift Package Manager)

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jaikoo/bloop-swift.git", from: "0.3.0")
]
```

Or in Xcode: File → Add Package Dependencies → enter `https://github.com/jaikoo/bloop-swift`.

## Usage

```swift
let client = BloopClient(
    url: URL(string: "https://errors.myapp.com")!,
    projectKey: "bloop_abc123..."
)

try await client.send(event: [
    "timestamp": Int(Date().timeIntervalSince1970),
    "source": "ios",
    "environment": "production",
    "release": "2.1.0",
    "error_type": "NetworkError",
    "message": "Request timed out",
    "screen": "HomeViewController",
])
```

## Features

- **CommonCrypto HMAC** — Signed requests via HMAC-SHA256
- **Async/await** — Modern Swift concurrency
- **Fire-and-forget** — Errors in reporting never crash your app
- **Zero dependencies** — Uses only Foundation and CommonCrypto

## License

MIT
