// Linux stand-in for the parts of Apple's `os` module vphone-cli uses:
// OSAllocatedUnfairLock (CustomFirmwareArm64eX1's shared decodability cache).
import Foundation

public final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    public init(initialState: State) {
        state = initialState
    }

    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
