import Foundation

/// The app's `OfficeManagedFolderTransport`: the managed-folder functions of the embedded mobile
/// core, reached through the one engine `OfficeTransportIdentity` holds. Only the opt-in office
/// transport build links that core; any other build has no transport, and no folder ever opens.
enum OfficeManagedFolderMobilecoreTransport {
    static func makeIfAvailable() -> (any OfficeManagedFolderTransport)? {
        #if AVENKIN_OFFICE_TRANSPORT
        return Bridge()
        #else
        return nil
        #endif
    }

    #if AVENKIN_OFFICE_TRANSPORT
    private struct Bridge: OfficeManagedFolderTransport {
        func startFolders(bindingJSON: String, policy: String, lanHint: String) async throws {
            try await OfficeTransportIdentity.shared.startManagedOfficeFolders(
                bindingJSON: bindingJSON, policy: policy, lanHint: lanHint)
        }

        func pendingJobs() async throws -> String {
            try await OfficeTransportIdentity.shared.managedJobsPending()
        }

        func jobFile(messageID: String) async throws -> String {
            try await OfficeTransportIdentity.shared.managedJobFile(messageID: messageID)
        }

        func publishReceipt(messageID: String, signatureBase64: String) async throws {
            try await OfficeTransportIdentity.shared.publishManagedJobReceipt(
                messageID: messageID, signatureBase64: signatureBase64)
        }

        func stop() async {
            await OfficeTransportIdentity.shared.stop()
        }
    }
    #endif
}
