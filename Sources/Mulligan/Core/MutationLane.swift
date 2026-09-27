/// One target mutation at a time (§6.16): an insert and an erase never overlap, and each
/// waits for the previous one's settle (a paste's `pasteCompletionDelay`) before touching the
/// target. The caller gets its result as soon as its body returns; only the next mutation
/// waits for the settle, so a paste still costs the user no extra latency.
@MainActor
enum MutationLane {
    private static var tail: Task<Void, Never>?

    static func run<T: Sendable>(_ body: @escaping @MainActor () async -> (T, Task<Void, Never>?)) async -> T {
        let previous = tail
        let work = Task { @MainActor () -> (T, Task<Void, Never>?) in
            await previous?.value
            return await body()
        }
        tail = Task { @MainActor in
            let (_, settle) = await work.value
            await settle?.value
        }
        return await work.value.0
    }
}
