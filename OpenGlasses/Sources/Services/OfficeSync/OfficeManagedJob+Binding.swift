import Foundation

extension OfficeManagedJob.Trust {
    /// The production boundary takes the application's trust only from a freshly rechecked
    /// vendor-rooted administrator binding. The transport message cannot choose this key.
    init(binding: OfficePeerBinding.Verified) {
        let p = binding.payload
        self.init(organizationID: p.organizationID, enrolmentID: p.enrolmentID,
                  officeID: p.officeID, generation: p.generation,
                  officeTransportID: p.officeTransportID, phoneTransportID: p.phoneTransportID,
                  officeApplicationKey: Data(base64Encoded: p.officeApplicationKey) ?? Data())
    }
}
