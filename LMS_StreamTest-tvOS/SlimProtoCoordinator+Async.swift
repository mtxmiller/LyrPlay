import Foundation

extension SlimProtoCoordinator {
    /// async/await wrapper over `sendJSONRPCCommandDirect`.
    ///
    /// The underlying callback is guaranteed-once, so the continuation is
    /// safe. Lets the tvOS LibraryView fetch sequence read as linear
    /// `await` steps instead of a 4-deep callback nest (plan-eng-review 1.A).
    func sendJSONRPCCommand(_ jsonRPC: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            sendJSONRPCCommandDirect(jsonRPC) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
