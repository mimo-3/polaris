import Foundation

/// 読み取りから画面反映までを直列化する。reset 後の小さい revision も順に反映する。
@MainActor public final class StateOperationQueue {
    private var tail: _Concurrency.Task<Void, Never>?
    private var pendingRefresh: _Concurrency.Task<Void, Never>?

    public init() {}

    /// 待機中の読み直しは1件にまとめる。実行中に届いた通知は次の1件で拾う。
    @discardableResult public func enqueueRefresh(_ operation: @escaping @MainActor @Sendable () async -> Void) -> _Concurrency.Task<Void, Never> {
        if let pendingRefresh { return pendingRefresh }
        let task = enqueue { [weak self] in
            self?.pendingRefresh = nil
            await operation()
        }
        pendingRefresh = task
        return task
    }

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
