import PDFKit
import QuickLook
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MyManualsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var library = PersonalManualLibrary.shared
    @ObservedObject private var capture = PersonalManualCapture.shared
    @ObservedObject private var store = StoreKitService.shared
    @ObservedObject private var gate = AdminGate.shared
    @StateObject private var links = VaultLinkService(personalLibrary: true)
    @State private var files = false
    @State private var showingPurchase = false
    @State private var pendingAction: LibraryAction?
    private enum LibraryAction { case upload, photograph, receive }
    @State private var receive = false
    @State private var pendingUpload: ManualFileUpload.Prepared?
    @State private var preparingUpload = false
    @State private var uploadPreparation: Task<ManualFileUpload.Prepared, Error>?
    @State private var originalManual: PersonalManualLibrary.Manual?
    @State private var title = ""
    @State private var selectedManual: PersonalManualLibrary.Manual?
    @State private var deleting: PersonalManualLibrary.Manual?
    @State private var message: String?
    @AppStorage("myManualsEnabled") private var answersEnabled = true
    private struct FileInfo: Sendable { let pages: Int?; let bytes: Int64 }
    @State private var fileInfo: [String: FileInfo] = [:]

    private var page: MyManualsPagePolicy {
        .init(restricted: gate.isRestricted, medical: Config.hipaaMode,
              ownsManuals: FieldAssistEntitlement.shared.has(.personalManuals))
    }

    var body: some View {
        Form {
            if gate.isRestricted {
                Text("Your organisation manages the manuals available on this phone.")
            } else {
                subscription
                Section("Your manuals · \(library.manuals.count + Set(library.unfinishedCaptures.map { $0.metadata.captureID }).count)") {
                    if page.showsUpload {
                        Menu {
                            Button("Choose PDF, Word or Markdown") { perform(.upload) }
                            Button("Use a publisher link or code") { request(.receive) }
                        } label: { Label("Upload manual", systemImage: "square.and.arrow.up") }
                            .disabled(library.isIndexing || preparingUpload)
                        Text("PDF, Word (DOC/DOCX), or Markdown. Saved on this phone.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { request(.photograph) } label: { Label("Photograph pages", systemImage: "doc.viewfinder") }
                            .disabled(library.isIndexing || preparingUpload)
                    }
                    if preparingUpload { ProgressView("Preparing manual…") }
                    if library.manuals.isEmpty { Text("Upload your first manual, then ask a question by voice.").foregroundStyle(.secondary) }
                    ForEach(library.manuals) { manual in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(manual.document.title).font(.headline)
                            Text(manual.document.personalCapture == true ? "Photographed pages" : (manual.manifest.id == "my-manuals" ? "\(manual.document.file.split(separator: ".").last?.uppercased() ?? "FILE") file" : "Received manual"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(library.isIndexed(manual) ? "Ready · page-cited answers" : "Saved · needs indexing").font(.caption)
                            if library.isIndexed(manual), let id = manual.entry?.documentId {
                                ManualLanguageLine(diagnostic: appState.documentStore.languageDiagnostic(documentId: id))
                            }
                            if manual.document.personalReadingCopy == true {
                                Text("Citations refer to the text reading copy. Original file retained.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let info = fileInfo[manual.id] {
                                Text("\(info.pages.map { "\($0) pages · " } ?? "")\(ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                if PersonalManualLibrary.canManage {
                                    HStack {
                                        Button(manual.document.personalReadingCopy == true ? "Read copy" : "Read") { selectedManual = manual }
                                        if manual.document.personalReadingCopy == true { Button("Read original") { originalManual = manual } }
                                    }
                                }
                                HStack {
                                    if PersonalManualLibrary.canManage {
                                        Button("Retry indexing") { Task { await library.index(manual) } }.disabled(library.isIndexing)
                                    }
                                    Button("Delete", role: .destructive) { deleting = manual }
                                }
                            }.buttonStyle(.borderless)
                        }.accessibilityElement(children: .contain)
                            .swipeActions {
                                Button("Delete", role: .destructive) { deleting = manual }
                            }
                    }
                    ForEach(library.unfinishedCaptures, id: \.metadata.key) { draft in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(draft.metadata.title).font(.headline)
                            Text("Unfinished photograph capture · holds one manual slot").font(.caption)
                            Button("Remove unfinished manual", role: .destructive) {
                                library.discardUnfinishedCapture(draft.metadata.captureID)
                            }.buttonStyle(.borderless)
                        }
                    }
                    if !fileInfo.isEmpty {
                        Text("Source files: \(ByteCountFormatter.string(fromByteCount: fileInfo.values.reduce(0) { $0 + $1.bytes }, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if library.isIndexing { ProgressView(library.status) }
                else if !library.status.isEmpty { Text(library.status).font(.caption) }
                if !capture.status.isEmpty { Text(capture.status).font(.caption) }
                if let message { Text(message).font(.caption) }
                Section("What the assistant can read") {
                    Toggle("Use my manuals in answers", isOn: $answersEnabled)
                        // The search models for the phone's languages, fetched ahead (Plan JY P1).
                        .onChange(of: answersEnabled) { _, on in
                            if on { ScriptModelAssets.shared.prepareForManualsIfInUse() }
                        }
                    Text(MyManualsPaywallCopy.disclosure).font(.footnote)
                }
            }
        }
        .navigationTitle("My Manuals")
        .task { if store.myManualsProducts.isEmpty { await store.loadProducts() } }
        // A plan that has just started, or a model missing since launch (Plan JY P1). A no-op when
        // the models are here or on their way.
        .task(id: store.myManualsSubscription == nil) { ScriptModelAssets.shared.prepareForManualsIfInUse() }
        .sheet(isPresented: $showingPurchase, onDismiss: resumePendingAction) {
            MyManualsPurchaseView(store: store, dismissOnAccess: pendingAction != nil)
        }
        .task(id: library.revision) {
            library.documents = appState.documentStore
            let files = library.manuals.map { ($0.id, $0.pdf, $0.document.personalReadingCopy == true ? $0.original : nil) }
            fileInfo = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: files.map { id, url, original in
                    let pdfBytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    let originalBytes = original.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
                    return (id, FileInfo(pages: try? ManualLibraryAdmission.pageCount(url), bytes: pdfBytes + originalBytes))
                })
            }.value
        }
        .fileImporter(isPresented: $files,
                      allowedContentTypes: ManualFileUpload.extensions.sorted().compactMap { UTType(filenameExtension: $0) },
                      allowsMultipleSelection: false) { result in
            switch result {
            case .failure(let error): message = error.localizedDescription
            case .success(let urls):
                guard let url = urls.first, !preparingUpload else { return }
                preparingUpload = true
                Task {
                    defer { preparingUpload = false; uploadPreparation = nil }
                    do {
                        let maxPages = FieldAssistEntitlement.shared.manualLimits()?.pagesPerManual ?? ManualLimits.personal.pagesPerManual ?? 10_000
                        let preparation = Task.detached(priority: .utility) {
                            try ManualFileUpload.prepare(url, maximumPages: maxPages)
                        }
                        uploadPreparation = preparation
                        let prepared = try await preparation.value
                        guard !preparation.isCancelled else { prepared.discard(); return }
                        title = prepared.suggestedTitle
                        pendingUpload = prepared
                    } catch is CancellationError { }
                    catch { message = error.localizedDescription }
                }
            }
        }
        .sheet(item: Binding(get: { pendingUpload }, set: { value in
            if value == nil { pendingUpload?.discard() }
            pendingUpload = value
        })) { upload in
            NavigationStack {
                Form {
                    TextField("Manual title", text: $title)
                    Text(upload.converted ? "\(upload.pages) pages in the reading copy" : "\(upload.pages) pages")
                    Text(ByteCountFormatter.string(fromByteCount: upload.bytes, countStyle: .file))
                    if upload.converted { Text(ManualFileUpload.conversionNotice).font(.footnote) }
                    Text("The manual is saved on this phone before indexing. You can retry interrupted indexing.").font(.footnote)
                    if PersonalManualLibrary.canManage {
                        if let notice = ManualAdditionAllowance.uploadNotice(ManualLibraryAdmission.allowanceStatus()) {
                            Text(notice).font(.footnote)
                        }
                        Button("Upload manual") {
                            pendingUpload = nil
                            Task { await library.addPrepared(upload, title: title) }
                        }
                    } else {
                        Text("Choose a Personal plan to save and index this manual.").font(.footnote)
                        MyManualsPlanButtons(store: store)
                        Button("Restore purchases") { Task { await store.restorePurchases() } }.disabled(store.isRestoring)
                        if let notice = store.purchaseError ?? store.restoreMessage { Text(notice).font(.caption) }
                    }
                }.navigationTitle("Upload manual")
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { upload.discard(); pendingUpload = nil }
                    } }
            }
        }
        .onDisappear { uploadPreparation?.cancel(); pendingUpload?.discard(); pendingUpload = nil }
        .sheet(isPresented: $receive) {
            VaultLinkSheet(service: links, onInstalled: {
                Task { for manifest in VaultImporter.installedManifests() where manifest.isPersonalLibrary { await library.index(manifest) } }
            })
        }
        .sheet(item: $selectedManual) { manual in
            NavigationStack {
                PersonalManualPDFView(url: PersonalManualLibrary.canManage ? manual.pdf : nil)
                    .navigationTitle(manual.document.title)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedManual = nil } } }
            }
        }
        .sheet(item: $originalManual) { manual in
            NavigationStack {
                ManualOriginalPreview(url: PersonalManualLibrary.canManage ? manual.original : nil)
                    .navigationTitle(manual.document.title)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { originalManual = nil } } }
            }
        }
        .confirmationDialog("Delete this manual and its search index from this phone?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete manual", role: .destructive) {
                guard let manual = deleting else { return }; deleting = nil
                Task { await library.remove(manual) }
            }
        }
    }

    private func request(_ action: LibraryAction) {
        guard page.showsUpload else { return }
        if page.requiresPurchase {
            pendingAction = action
            showingPurchase = true
        } else { perform(action) }
    }

    private func resumePendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        guard PersonalManualLibrary.canManage else { return }
        perform(action)
    }

    private func perform(_ action: LibraryAction) {
        switch action {
        case .upload: files = true
        case .photograph: Task { message = await capture.start() }
        case .receive: links.dismiss(); receive = true
        }
    }

    private var subscription: some View {
        Section("My Manuals") {
            Text(MyManualsPaywallCopy.summary)
            if let info = store.myManualsSubscription {
                Text("Personal · \(info.planName)").font(.headline)
                if let expiry = info.expirationDate {
                    let expiryDate = expiry.formatted(date: .abbreviated, time: .omitted)
                    Text(info.willAutoRenew ? "Renews \(expiryDate)" : "Access ends \(expiryDate)").font(.caption)
                }
                Button("View in-app plans") { showingPurchase = true }
            } else {
                MyManualsPlanButtons(store: store)
            }
            Button("Restore purchases") { Task { await store.restorePurchases() } }.disabled(store.isRestoring)
            if let text = store.restoreMessage ?? store.purchaseError { Text(text).font(.caption) }
        }
    }

}

struct PersonalManualPDFView: UIViewRepresentable {
    let url: URL?
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; return view }
    func updateUIView(_ view: PDFView, context: Context) { view.document = url.flatMap(PDFDocument.init(url:)) }
}

/// System preview for the retained uploaded original; the PDF reading copy owns page citations.
struct ManualOriginalPreview: UIViewControllerRepresentable {
    let url: URL?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let view = QLPreviewController()
        context.coordinator.url = url
        view.dataSource = context.coordinator
        return view
    }
    func updateUIViewController(_ view: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; view.reloadData() }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL?
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { url == nil ? 0 : 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { (url ?? URL(fileURLWithPath: "/")) as NSURL }
    }
}

/// Upload is discoverable before purchase; a verified entitlement still gates saving/answering.
struct MyManualsPagePolicy: Equatable {
    let restricted: Bool
    let medical: Bool
    let ownsManuals: Bool
    var showsUpload: Bool { !restricted && !medical }
    var requiresPurchase: Bool { showsUpload && !ownsManuals }
}

private struct MyManualsPlanButtons: View {
    @ObservedObject var store: StoreKitService
    var onPurchased: (() -> Void)? = nil
    var body: some View {
        if store.isLoadingProducts { ProgressView("Loading in-app plans…") }
        ForEach(store.myManualsProducts, id: \.id) { product in
            Button {
                Task {
                    await store.purchase(product)
                    if PersonalManualLibrary.canManage { onPurchased?() }
                }
            } label: {
                Text(product.id == StoreKitService.myManualsAnnualId
                     ? "Subscribe annually · \(product.displayPrice)"
                     : "Subscribe monthly · \(product.displayPrice)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isPurchasing || store.isRestoring)
        }
        if let error = store.myManualsCatalogError { Text(error).font(.caption).foregroundStyle(.secondary) }
        if !store.isLoadingProducts, store.myManualsProducts.count < StoreKitService.myManualsCatalogProductIds.count {
            Button("Retry loading in-app plans") { Task { await store.loadProducts() } }
        }
        // Shared by every purchase entry point, including the upload preview sheet.
        Text("Subscriptions renew automatically at the displayed price unless cancelled in your Apple Account subscription settings. Any introductory offer applies only to eligible subscribers.")
            .font(.footnote)
        Link("Privacy Policy", destination: PublicSite.privacy)
        Link("Terms of Use", destination: PublicSite.termsOfUse)
    }
}

private struct MyManualsPurchaseView: View {
    @ObservedObject var store: StoreKitService
    let dismissOnAccess: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(MyManualsPaywallCopy.summary)
                    MyManualsPlanButtons(store: store) { if dismissOnAccess { dismiss() } }
                    Button("Restore purchases") { Task {
                        await store.restorePurchases()
                        if dismissOnAccess, PersonalManualLibrary.canManage { dismiss() }
                    } }.disabled(store.isRestoring)
                    if let notice = store.purchaseError ?? store.restoreMessage { Text(notice).font(.caption) }
                }
                Section {
                    DisclosureGroup("Plan limits") { Text(MyManualsPaywallCopy.pageLimits).font(.footnote) }
                    Text(MyManualsPaywallCopy.disclosure).font(.footnote)
                }
            }
            .navigationTitle("My Manuals plans")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { if store.myManualsProducts.isEmpty { await store.loadProducts() } }
        }
    }
}
