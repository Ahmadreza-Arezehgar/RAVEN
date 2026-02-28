import SwiftUI
import QuickLook

// MARK: - Document Preview Controller (QuickLook Wrapper)
struct DocumentPreviewController: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.previewController = controller
        
        let nav = UINavigationController(rootViewController: controller)
        nav.navigationBar.prefersLargeTitles = false
        return nav
    }
    
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
    
    func makeCoordinator() -> Coordinator { Coordinator(url: url, dismiss: dismiss) }
    
    class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let url: URL
        let dismiss: DismissAction
        weak var previewController: QLPreviewController?
        
        init(url: URL, dismiss: DismissAction) {
            self.url = url
            self.dismiss = dismiss
            super.init()
        }
        
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
        func previewControllerDidDismiss(_ controller: QLPreviewController) { dismiss() }
    }
}

// MARK: - Universal Document Preview Loading View
struct DocumentPreviewView: View {
    let url: URL
    let fileName: String?
    
    init(url: URL, fileName: String? = nil) {
        self.url = url
        self.fileName = fileName
    }
    
    @State private var isLoading = true
    @State private var localURL: URL?
    @State private var error: Error?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Group {
            if let localURL = localURL {
                DocumentPreviewController(url: localURL)
                    .ignoresSafeArea()
            } else if error != nil {
                NavigationStack {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.badge.exclamationmark")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Failed to load document")
                            .foregroundStyle(.secondary)
                        Button("Retry") { Task { await loadDocument() } }
                            .buttonStyle(.bordered)
                    }
                    .navigationTitle(fileName ?? "Document")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { dismiss() }
                        }
                    }
                }
            } else {
                NavigationStack {
                    VStack(spacing: 16) {
                        ProgressView().scaleEffect(1.5)
                        Text("Loading Document...").foregroundStyle(.secondary)
                    }
                    .navigationTitle(fileName ?? "Document")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { dismiss() }
                        }
                    }
                }
            }
        }
        .task { await loadDocument() }
        .onDisappear {
            // Clean up temp file to avoid filling device storage
            if let localURL = localURL, localURL.path.contains(FileManager.default.temporaryDirectory.path) {
                try? FileManager.default.removeItem(at: localURL)
            }
        }
    }
    
    private func loadDocument() async {
        isLoading = true
        error = nil
        
        // 1. If local file, use directly
        if url.isFileURL {
            await MainActor.run { self.localURL = url; self.isLoading = false }
            return
        }
        
        // 2. Download from remote securely
        do {
            var request = URLRequest(url: url)
            if let (token, _) = await KeychainService.shared.getToken() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }
            
            // Reattach original file extension so QuickLook knows how to render it properly
            var safeName = fileName ?? url.lastPathComponent
            if !safeName.contains(".") {
                let ext = url.pathExtension.isEmpty ? "pdf" : url.pathExtension
                safeName = "\(safeName).\(ext)"
            }
            let destURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)_\(safeName)")
            
            if FileManager.default.fileExists(atPath: destURL.path) { try? FileManager.default.removeItem(at: destURL) }
            try FileManager.default.moveItem(at: tempURL, to: destURL)
            
            await MainActor.run { self.localURL = destURL; self.isLoading = false }
        } catch {
            await MainActor.run { self.error = error; self.isLoading = false }
        }
    }
}

// MARK: - Legacy Alias (keeps old references compiling)
typealias PDFPreviewView = DocumentPreviewView
