import PDFKit
import SwiftUI
import VisionKit

struct ManualDocumentCamera: UIViewControllerRepresentable {
    let onSave: @MainActor (VNDocumentCameraScan) -> Void
    let onCancel: @MainActor (String) -> Void
    init(request: ManualCaptureService.Request) {
        onSave = { ManualCaptureService.shared.accept($0, request: request) }
        onCancel = { ManualCaptureService.shared.cancel(requestID: request.id, message: $0) }
    }
    init(request: PersonalManualCapture.Request) {
        onSave = { PersonalManualCapture.shared.accept($0, request: request) }
        onCancel = { PersonalManualCapture.shared.cancel(request.id, message: $0) }
    }
    /// The same camera for a caller that takes the scan itself (Plan LW: a manual for a vault of your
    /// own, a nameplate).
    init(onSave: @escaping @MainActor (VNDocumentCameraScan) -> Void, onCancel: @escaping @MainActor (String) -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
    }
    func makeCoordinator() -> Coordinator { Coordinator(onSave: onSave, onCancel: onCancel) }
    func makeUIViewController(context:Context) -> VNDocumentCameraViewController {
        let view = VNDocumentCameraViewController();view.delegate = context.coordinator;return view
    }
    func updateUIViewController(_ view:VNDocumentCameraViewController,context:Context) {}
    private final class ScanTransfer: @unchecked Sendable {
        let scan: VNDocumentCameraScan
        init(_ scan: VNDocumentCameraScan) { self.scan = scan }
    }
    final class Coordinator: NSObject,VNDocumentCameraViewControllerDelegate {
        let onSave: @MainActor (VNDocumentCameraScan) -> Void
        let onCancel: @MainActor (String) -> Void
        init(onSave: @escaping @MainActor (VNDocumentCameraScan) -> Void,
             onCancel: @escaping @MainActor (String) -> Void) { self.onSave = onSave; self.onCancel = onCancel }
        func documentCameraViewController(_ controller:VNDocumentCameraViewController,didFinishWith scan:VNDocumentCameraScan) {
            let transfer = ScanTransfer(scan)
            Task { @MainActor [onSave] in onSave(transfer.scan) }
        }
        func documentCameraViewControllerDidCancel(_ controller:VNDocumentCameraViewController) {
            Task { @MainActor [onCancel] in onCancel("Manual capture cancelled.") }
        }
        func documentCameraViewController(_ controller:VNDocumentCameraViewController,didFailWithError error:Error) {
            Task { @MainActor [onCancel] in onCancel("The document camera could not save these pages. Check camera access and try again.") }
        }
    }
}

struct PhotographedManualSection: View {
    @ObservedObject private var captures = ManualCaptureService.shared
    var body:some View {
        Section("Photographed manuals") {
            if CapturedManualCatalog.mayUse {
                Button { _ = captures.start() } label: {Label("Photograph a manual",systemImage:"doc.viewfinder")}
            }
            NavigationLink("Saved photographed manuals") {PhotographedManualsView()}
            if !captures.status.isEmpty {Text(captures.status).font(.caption).foregroundStyle(.secondary)}
            if CapturedManualCatalog.mayUse {Button("Resume recognition") {Task {await captures.resume()}}}
        }
    }
}

struct PhotographedManualsView: View {
    @ObservedObject private var captures = ManualCaptureService.shared
    @ObservedObject private var outbox = CapturedManualOutbox.shared
    @State private var manuals:[CapturedManualContract.Manifest] = []
    @State private var unfinished:[CapturedManualStore.Draft] = []
    @State private var error:String?
    @State private var deleting:String?
    @State private var selected:CapturedManualContract.Manifest?
    /// The photographed manuals with tables read from their pages (Plan JN P4), each with its
    /// pages' PDF for the check view's picture.
    @State private var withTables:Set<String> = []
    @State private var tablePDFs:[String:URL] = [:]
    var body:some View {
        List {
            if let error {Text(error).foregroundStyle(.red)}
            ForEach(manuals,id:\.documentID) { m in
                VStack(alignment:.leading,spacing:6) {
                    Text(m.title).font(.headline)
                    Text("\(m.pageCount) photographed pages · \(m.lowConfidencePages) low confidence · unreviewed · \(outbox.standing(m))").font(.caption)
                    HStack {
                        if CapturedManualCatalog.mayUse {Button("View pages") {selected = m}}
                        Button("Forget",role:.destructive) {deleting = m.captureID}
                    }
                    // Tables read from the photographed pages, each with where its check stands
                    // (Plan JN P4). The checks are this phone's own.
                    if CapturedManualCatalog.mayUse,withTables.contains(m.documentID),
                       let documents = CapturedManualCatalog.shared.documents,let hash = CapturedManualTables.checkHash(m) {
                        PicturedTablesList(vaultId:m.vaultID,documentId:m.documentID,documentHash:hash,
                                           pdfURL:tablePDFs[m.documentID],documentStore:documents,
                                           canCheck:CapturedManualCatalog.mayUse,photographed:true)
                    }
                }
            }
            ForEach(unfinished,id:\.metadata.key) { draft in
                VStack(alignment:.leading) {
                    Text(draft.metadata.title)
                    Text(draft.stagingComplete ? "Recognition incomplete" : "Page capture incomplete; photograph again").font(.caption)
                    Button("Discard incomplete capture",role:.destructive) {deleting = draft.metadata.captureID}
                }
            }
            if manuals.isEmpty && unfinished.isEmpty {Text("No photographed manuals on this phone.")}
        }
        .diagnosticScreen()
        .navigationTitle("Photographed manuals")
        .task {reload()}
        .onChange(of:captures.revision) {_,_ in reload()}
        .confirmationDialog("Forget this photographed manual and every retained revision?",isPresented:Binding(get:{deleting != nil},set:{if !$0 {deleting = nil}})) {
            Button("Forget manual",role:.destructive) {
                guard let id = deleting else {return}
                do {try captures.discard(id)} catch {self.error = String(localized: "Some protected files could not be removed. Unlock the phone and retry.")}
                deleting = nil;reload()
            }
        }
        .sheet(item:Binding(get:{selected.map(Selection.init)},set:{selected = $0?.manifest})) {selection in
            NavigationStack {CapturedManualPageView(manifest:selection.manifest)}
        }
    }
    private struct Selection:Identifiable {let manifest:CapturedManualContract.Manifest;var id:String {manifest.documentID}}
    private func reload() {
        do {
            guard let store = CapturedManualStore.shared else {throw CapturedManualStore.Failure.unavailable}
            manuals = try store.manifests().filter {$0.scope == CapturedManualCatalog.scope(vaultID:$0.vaultID)}
            unfinished = try store.pending().filter {$0.metadata.scope == CapturedManualCatalog.scope(vaultID:$0.metadata.scope.vaultID)}
            let documents = CapturedManualCatalog.shared.documents
            let tabled = manuals.filter { m in
                documents?.tables(documentId:m.documentID).contains { $0.source.isRecognised && $0.isExtracted } == true
            }
            withTables = Set(tabled.map(\.documentID))
            Task {
                let urls = await Task.detached(priority:.utility) {
                    Dictionary(tabled.compactMap { m in (try? store.file(m,name:"pages.pdf")).map { (m.documentID,$0) } },
                               uniquingKeysWith:{ first,_ in first })
                }.value
                tablePDFs = urls
            }
        } catch {self.error = String(localized: "Manual storage is unavailable while the phone is locked.")}
    }
}

private struct CapturedManualPageView:View {
    let manifest:CapturedManualContract.Manifest
    @State private var url:URL?
    @State private var textURL:URL?
    @State private var error:String?
    var body:some View {
        VStack {
            Text("Photographed manual · \(manifest.pageCount) pages").font(.headline)
            Text("Text recognised from a scan; verify figures against the photographed page.").font(.caption)
            if let error {Text(error)}
            if let url {CapturePDFView(url:url)}
        }
        .navigationTitle(manifest.title)
        .toolbar {
            if let url {ShareLink("Share photographed pages",item:url)}
            if let textURL {ShareLink("Share recognised text",item:textURL)}
        }
        .task {
            guard CapturedManualCatalog.mayUse,
                  manifest.scope == CapturedManualCatalog.scope(vaultID:manifest.vaultID),let store = CapturedManualStore.shared else {
                error = String(localized: "These photographed pages are unavailable under the current policy.");return
            }
            do {
                let files = try await Task.detached(priority:.utility) {
                    (try store.file(manifest,name:"pages.pdf"),try store.file(manifest,name:"text.md"))
                }.value
                guard CapturedManualCatalog.mayUse,manifest.scope == CapturedManualCatalog.scope(vaultID:manifest.vaultID) else {return}
                url = files.0;textURL = files.1
            }
            catch {self.error = String(localized: "These photographed pages are unavailable or have changed.")}
        }
    }
}
private struct CapturePDFView:UIViewRepresentable {
    let url:URL
    func makeUIView(context:Context) -> PDFView {let view = PDFView();view.autoScales = true;view.displayMode = .singlePageContinuous;view.document = PDFDocument(url:url);return view}
    func updateUIView(_ view:PDFView,context:Context) {}
}
