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

        func checkInPending() async throws -> String {
            try await OfficeTransportIdentity.shared.managedCheckInPending()
        }

        func checkInPayload(challengeID: String, leaseRenewBy: Int64, appVersion: String,
                            appBuild: String) async throws -> String {
            try await OfficeTransportIdentity.shared.managedCheckInPayload(
                challengeID: challengeID, leaseRenewBy: leaseRenewBy, appVersion: appVersion, appBuild: appBuild)
        }

        func publishCheckIn(challengeID: String, signatureBase64: String) async throws -> String {
            try await OfficeTransportIdentity.shared.publishManagedCheckIn(
                challengeID: challengeID, signatureBase64: signatureBase64)
        }

        func removalReceiptPayload(removalID: String, actedAt: Int64) async throws -> String {
            try await OfficeTransportIdentity.shared.managedRemovalReceiptPayload(
                removalID: removalID, actedAt: actedAt)
        }

        func publishRemovalReceipt(removalID: String, signatureBase64: String) async throws -> String {
            try await OfficeTransportIdentity.shared.publishManagedRemovalReceipt(
                removalID: removalID, signatureBase64: signatureBase64)
        }

        func publishReport(payloadBase64: String, signatureBase64: String, recordBase64: String,
                           manifestBase64: String) async throws -> String {
            try await OfficeTransportIdentity.shared.publishManagedReport(
                payloadBase64: payloadBase64, signatureBase64: signatureBase64,
                recordBase64: recordBase64, manifestBase64: manifestBase64)
        }

        func publishReportAttachment(sha256: String, path: String) async throws {
            try await OfficeTransportIdentity.shared.publishManagedReportAttachment(sha256: sha256, path: path)
        }

        func reportReceipts() async throws -> String {
            try await OfficeTransportIdentity.shared.managedReportReceipts()
        }

        func withdrawReport(reportID: String) async throws {
            try await OfficeTransportIdentity.shared.withdrawManagedReport(reportID: reportID)
        }

        func bulkPending() async throws -> String {
            try await OfficeTransportIdentity.shared.managedBulkPending()
        }

        func setBulkWanted(_ wantedJSON: String) async throws {
            try await OfficeTransportIdentity.shared.setManagedBulkWanted(wantedJSON)
        }

        func bulkStatus() async throws -> String {
            try await OfficeTransportIdentity.shared.managedBulkStatus()
        }

        func bulkFile(sha256: String) async throws -> String {
            try await OfficeTransportIdentity.shared.managedBulkFile(sha256: sha256)
        }

        func setBulkPaused(_ paused: Bool) async throws {
            try await OfficeTransportIdentity.shared.setManagedBulkPaused(paused)
        }

        func assignmentReceiptPayload(assignmentID: String, outcome: String, at: Int64) async throws -> String {
            try await OfficeTransportIdentity.shared.managedAssignmentReceiptPayload(
                assignmentID: assignmentID, outcome: outcome, at: at)
        }

        func publishAssignmentReceipt(assignmentID: String, outcome: String,
                                      signatureBase64: String) async throws -> String {
            try await OfficeTransportIdentity.shared.publishManagedAssignmentReceipt(
                assignmentID: assignmentID, outcome: outcome, signatureBase64: signatureBase64)
        }

        func stop() async {
            await OfficeTransportIdentity.shared.stop()
        }
    }
    #endif
}
