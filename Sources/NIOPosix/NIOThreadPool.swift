//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DequeModule
import Dispatch
import NIOConcurrencyHelpers
import NIOCore

/// Errors that may be thrown when executing work on a `NIOThreadPool`
public enum NIOThreadPoolError {

    /// The `NIOThreadPool` was not active.
    public struct ThreadPoolInactive: Error {
        public init() {}
    }

    /// The `NIOThreadPool` operation is unsupported (e.g. shutdown of a perpetual pool).
    public struct UnsupportedOperation: Error {
        public init() {}
    }
}

/// A thread pool that should be used if some (kernel thread) blocking work
/// needs to be performed for which no non-blocking API exists.
///
/// When using NIO it is crucial not to block any of the `EventLoop`s as that
/// leads to slow downs or stalls of arbitrary other work. Unfortunately though
/// there are tasks that applications need to achieve for which no non-blocking
/// APIs exist. In those cases `NIOThreadPool` can be used but should be
/// treated as a last resort.
///
/// - note: The prime example for missing non-blocking APIs is file IO on UNIX.
///   The OS does not provide a usable and truly non-blocking API but with
///   `NonBlockingFileIO` NIO provides a high-level API for file IO that should
///   be preferred to running blocking file IO system calls directly on
///   `NIOThreadPool`. Under the covers `NonBlockingFileIO` will use
///   `NIOThreadPool` on all currently supported platforms though.
public final class NIOThreadPool {

    /// The state of the `WorkItem`.
    public enum WorkItemState: Sendable {
        /// The `WorkItem` is active now and in process by the `NIOThreadPool`.
        case active
        /// The `WorkItem` was cancelled and will not be processed by the `NIOThreadPool`.
        case cancelled
    }

    /// The work that should be done by the `NIOThreadPool`.
    public typealias WorkItem = @Sendable (WorkItemState) -> Void
    private enum State {
        /// The `NIOThreadPool` is already stopped.
        case stopped
        /// The `NIOThreadPool` is shutting down, the array has one boolean entry for each thread indicating if it has shut down already.
        case shuttingDown([Bool])
        /// The `NIOThreadPool` is up and running, the `CircularBuffer` containing the yet unprocessed `WorkItems`.
        case running(Deque<WorkItem>)
        /// Temporary state used when mutating the .running(items). Used to avoid CoW copies.
        /// It should never be "leaked" outside of the lock block.
        case modifying
    }
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NIOLock()
    private var threads: [NIOThread]? = nil  // protected by `lock`
    private var state: State = .stopped
    public let numberOfThreads: Int
    private let canBeStopped: Bool

    /// Gracefully shutdown this `NIOThreadPool`. All tasks will be run before shutdown will take place.
    ///
    /// - parameters:
    ///     - queue: The `DispatchQueue` used to executed the callback
    ///     - callback: The function to be executed once the shutdown is complete.
    @preconcurrency
    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping @Sendable (Error?) -> Void) {
        self._shutdownGracefully(queue: queue, callback)
    }

    private func _shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        guard self.canBeStopped else {
            queue.async {
                callback(NIOThreadPoolError.UnsupportedOperation())
            }
            return
        }
        let g = DispatchGroup()
        let threadsToJoin = self.lock.withLock { () -> [NIOThread] in
            switch self.state {
            case .running(let items):
                self.state = .modifying
                queue.async {
                    items.forEach { $0(.cancelled) }
                }
                self.state = .shuttingDown(Array(repeating: true, count: numberOfThreads))
                (0..<numberOfThreads).forEach { _ in
                    self.semaphore.signal()
                }
                let threads = self.threads!
                defer {
                    self.threads = nil
                }
                return threads
            case .shuttingDown, .stopped:
                return []
            case .modifying:
                fatalError(".modifying state misuse")
            }
        }

        DispatchQueue(label: "io.swiftnio.NIOThreadPool.shutdownGracefully").async(group: g) {
            threadsToJoin.forEach { $0.join() }
        }

        g.notify(queue: queue) {
            callback(nil)
        }
    }

    /// Submit a `WorkItem` to process.
    ///
    /// - note: This is a low-level method, in most cases the `runIfActive` method should be used.
    ///
    /// - parameters:
    ///     - body: The `WorkItem` to process by the `NIOThreadPool`.
    @preconcurrency
    public func submit(_ body: @escaping WorkItem) {
        self._submit(body)
    }

    private func _submit(_ body: @escaping WorkItem) {
        let item = self.lock.withLock { () -> WorkItem? in
            switch self.state {
            case .running(var items):
                self.state = .modifying
                items.append(body)
                self.state = .running(items)
                self.semaphore.signal()
                return nil
            case .shuttingDown, .stopped:
                return body
            case .modifying:
                fatalError(".modifying state misuse")
            }
        }
        /* if item couldn't be added run it immediately indicating that it couldn't be run */
        item.map { $0(.cancelled) }
    }

    /// Initialize a `NIOThreadPool` thread pool with `numberOfThreads` threads.
    ///
    /// - parameters:
    ///   - numberOfThreads: The number of threads to use for the thread pool.
    public convenience init(numberOfThreads: Int) {
        self.init(numberOfThreads: numberOfThreads, canBeStopped: true)
    }

    /// Create a ``NIOThreadPool`` that is already started, cannot be shut down and must not be `deinit`ed.
    ///
    /// This is only useful for global singletons.
    public static func _makePerpetualStartedPool(numberOfThreads: Int, threadNamePrefix: String) -> NIOThreadPool {
        let pool = self.init(numberOfThreads: numberOfThreads, canBeStopped: false)
        pool._start(threadNamePrefix: threadNamePrefix)
        return pool
    }

    private init(numberOfThreads: Int, canBeStopped: Bool) {
        self.numberOfThreads = numberOfThreads
        self.canBeStopped = canBeStopped
    }

    private func process(identifier: Int) {
        var item: WorkItem? = nil
        repeat {
            /* wait until work has become available */
            item = nil  // ensure previous work item is not retained for duration of semaphore wait
            self.semaphore.wait()

            item = self.lock.withLock { () -> (WorkItem)? in
                switch self.state {
                case .running(var items):
                    self.state = .modifying
                    let item = items.removeFirst()
                    self.state = .running(items)
                    return item
                case .shuttingDown(var aliveStates):
                    assert(aliveStates[identifier])
                    aliveStates[identifier] = false
                    self.state = .shuttingDown(aliveStates)
                    return nil
                case .stopped:
                    return nil
                case .modifying:
                    fatalError(".modifying state misuse")
                }
            }
            /* if there was a work item popped, run it */
            item.map { $0(.active) }
        } while item != nil
    }

    /// Start the `NIOThreadPool` if not already started.
    public func start() {
        self._start(threadNamePrefix: "TP-#")
    }

    public func _start(threadNamePrefix: String) {
        let alreadyRunning: Bool = self.lock.withLock {
            switch self.state {
            case .running(_):
                return true
            case .shuttingDown(_):
                // This should never happen
                fatalError("start() called while in shuttingDown")
            case .stopped:
                self.state = .running(Deque(minimumCapacity: 16))
                return false
            case .modifying:
                fatalError(".modifying state misuse")
            }
        }

        if alreadyRunning {
            return
        }

        let group = DispatchGroup()

        self.lock.withLock {
            assert(self.threads == nil)
            self.threads = []
            self.threads?.reserveCapacity(self.numberOfThreads)
        }

        for id in 0..<self.numberOfThreads {
            group.enter()
            // We should keep thread names under 16 characters because Linux doesn't allow more.
            NIOThread.spawnAndRun(name: "\(threadNamePrefix)\(id)", detachThread: false) { thread in
                self.lock.withLock {
                    self.threads!.append(thread)
                }
                group.leave()
                self.process(identifier: id)
                return ()
            }
        }

        // *** BUG FIX ***
        // This prevents the crash with error message:
        /*
         Thread Performance Checker: Thread running at User-interactive quality-of-service class waiting on a lower QoS thread running at Default quality-of-service class. Investigate ways to avoid priority inversions
         PID: 56009, TID: 15177876
         Backtrace
         =================================================================
         3   TheApp                         0x0000000104a91308 $s8NIOPosix13NIOThreadPoolC6_start16threadNamePrefixySS_tF + 1524
         4   TheApp                         0x0000000104a91fc8 $s8NIOPosix13NIOThreadPoolC5startyyF + 60
         5   TheApp                         0x0000000104b80c7c $s5Vapor11ApplicationC4CoreV7StorageCAGycfc + 532
         6   TheApp                         0x0000000104b80a5c $s5Vapor11ApplicationC4CoreV7StorageCAGycfC + 44
         7   TheApp                         0x0000000104b81198 $s5Vapor11ApplicationC4CoreV10initializeyyF + 84
         .....
         */
        let queue = DispatchQueue(label: "com.swift-nio.myQueue", qos: .userInteractive)
        queue.async {
            group.wait()
        }
        
        assert(self.lock.withLock { self.threads?.count ?? -1 } == self.numberOfThreads)
    }

    deinit {
        assert(
            self.canBeStopped,
            "Perpetual NIOThreadPool has been deinited, you must make sure that perpetual pools don't deinit")
        switch self.state {
        case .stopped, .shuttingDown:
            ()
        default:
            assertionFailure("wrong state \(self.state)")
        }
    }
}

extension NIOThreadPool: @unchecked Sendable {}

extension NIOThreadPool {

    /// Runs the submitted closure if the thread pool is still active, otherwise fails the promise.
    /// The closure will be run on the thread pool so can do blocking work.
    ///
    /// - parameters:
    ///     - eventLoop: The `EventLoop` the returned `EventLoopFuture` will fire on.
    ///     - body: The closure which performs some blocking work to be done on the thread pool.
    /// - returns: The `EventLoopFuture` of `promise` fulfilled with the result (or error) of the passed closure.
    @preconcurrency
    public func runIfActive<T>(eventLoop: EventLoop, _ body: @escaping @Sendable () throws -> T) -> EventLoopFuture<T> {
        self._runIfActive(eventLoop: eventLoop, body)
    }

    private func _runIfActive<T>(eventLoop: EventLoop, _ body: @escaping () throws -> T) -> EventLoopFuture<T> {
        let promise = eventLoop.makePromise(of: T.self)
        self.submit { shouldRun in
            guard case shouldRun = NIOThreadPool.WorkItemState.active else {
                promise.fail(NIOThreadPoolError.ThreadPoolInactive())
                return
            }
            do {
                try promise.succeed(body())
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    /// Runs the submitted closure if the thread pool is still active, otherwise throw an error.
    /// The closure will be run on the thread pool so can do blocking work.
    ///
    /// - parameters:
    ///     - body: The closure which performs some blocking work to be done on the thread pool.
    /// - returns: result of the passed closure.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func runIfActive<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            self.submit { shouldRun in
                guard case shouldRun = NIOThreadPool.WorkItemState.active else {
                    cont.resume(throwing: NIOThreadPoolError.ThreadPoolInactive())
                    return
                }
                do {
                    try cont.resume(returning: body())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

extension NIOThreadPool {
    @preconcurrency
    public func shutdownGracefully(_ callback: @escaping @Sendable (Error?) -> Void) {
        self.shutdownGracefully(queue: .global(), callback)
    }

    /// Shuts down the thread pool gracefully.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    public func shutdownGracefully() async throws {
        return try await withCheckedThrowingContinuation { cont in
            self.shutdownGracefully { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    @available(*, noasync, message: "this can end up blocking the calling thread", renamed: "shutdownGracefully()")
    public func syncShutdownGracefully() throws {
        try self._syncShutdownGracefully()
    }

    private func _syncShutdownGracefully() throws {
        let errorStorageLock = NIOLock()
        var errorStorage: Swift.Error? = nil
        let continuation = DispatchWorkItem {}
        self.shutdownGracefully { error in
            if let error = error {
                errorStorageLock.withLock {
                    errorStorage = error
                }
            }
            continuation.perform()
        }
        continuation.wait()
        try errorStorageLock.withLock {
            if let error = errorStorage {
                throw error
            }
        }
    }
}
