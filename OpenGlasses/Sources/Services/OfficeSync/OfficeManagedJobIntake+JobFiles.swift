import Foundation

/// The app's wiring of the intake: the existing job-file import and its review, and a file for
/// the record.
extension OfficeManagedJobIntake.Seams {
    /// A job from the office goes through `JobFileService` exactly as a file opened from Mail
    /// does: the same validation, the same signature rule, the same review, the same one tap.
    @MainActor
    static func app(transport: any OfficeManagedFolderTransport, jobFiles: JobFileService,
                    ledgerFile: URL? = OfficeManagedJobIntake.defaultLedgerFile()) -> Self {
        var seams = Self(
            transport: transport,
            refusal: { jobFiles.refusal(for: $0) },
            raise: { data, fileName in
                // Never over something the technician is already looking at.
                guard jobFiles.stage == .idle else { return .busy }
                jobFiles.handle(data: data, fileName: fileName)
                switch jobFiles.stage {
                case .review:
                    return .raised
                case .refused(let message):
                    return .refused(message)
                case .idle, .added:
                    return .busy
                }
            })
        if let ledgerFile {
            seams.load = { OfficeManagedJobIntake.readLedger(ledgerFile) }
            seams.save = { try OfficeManagedJobIntake.writeLedger($0, to: ledgerFile) }
        }
        return seams
    }
}

extension OfficeManagedJobIntake {
    nonisolated static func defaultLedgerFile() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return support.appendingPathComponent("AvenkinOffice", isDirectory: true)
            .appendingPathComponent("managed-jobs.json")
    }

    /// A missing or unreadable record reads as empty: the transport's own record still decides
    /// what is pending, and a job offered twice is better than one never offered.
    nonisolated static func readLedger(_ file: URL) -> Ledger {
        guard let data = try? Data(contentsOf: file),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data),
              ledger.version == 1 else { return Ledger() }
        return ledger
    }

    nonisolated static func writeLedger(_ ledger: Ledger, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(
            to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Follows the job review's stage, so the intake knows when a review it raised has ended:
    /// answered, put aside, or replaced by another file.
    func reviewStageChanged(_ stage: JobFileService.Stage) {
        var showing: String?
        if case .review(let review) = stage { showing = review.proposed.provenance?.digest }
        if let ended = reviewShowing, ended != showing { reviewEnded(jobSHA256: ended) }
        reviewShowing = showing
    }
}
