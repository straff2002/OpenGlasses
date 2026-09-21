import SwiftUI

/// The one place the app asks before taking a technician out of the job they are on.
///
/// Four taps could do it — New conversation on the dock, New chat in the Chat tab, opening another
/// thread, and the same two on CarPlay — and none of them used to say what it would do to the job.
/// The wording comes from the flow, which knows the job number; the choice is the technician's, and
/// "keep this in the job" is the safe default (it is the cancel role, so Escape and a swipe both
/// land on it).
extension View {
    func jobThreadQuestionAlert(_ question: Binding<JobThreadQuestion?>,
                                onSeparateChat: @escaping (JobThreadQuestion) -> Void) -> some View {
        alert("Keep this in the job?",
              isPresented: Binding(get: { question.wrappedValue != nil },
                                   set: { if !$0 { question.wrappedValue = nil } }),
              presenting: question.wrappedValue) { asked in
            Button("Keep in the Job", role: .cancel) { question.wrappedValue = nil }
            Button("Separate Chat") {
                question.wrappedValue = nil
                onSeparateChat(asked)
            }
        } message: { asked in
            Text(asked.spoken)
        }
    }
}
