import Foundation

/// 読み取りから画面反映までを直列化する。reset 後の小さい revision も順に反映する。
@MainActor public final class StateOperationQueue {
    private var tail: _Concurrency.Task<Void, Never>?

    public init() {}

    @discardableResult public func enqueue(_ operation: @escaping @MainActor @Sendable () async -> Void) -> _Concurrency.Task<Void, Never> {
        let previous = tail
        let task = _Concurrency.Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }
}
