import SwiftUI

// MARK: - Storage Settings View
struct StorageSettingsView: View {
    @State private var cacheSize: String = "Calculating..."
    @State private var isClearingCache = false
    @AppStorage("autoDownloadMedia") private var autoDownloadMedia = true
    @AppStorage("keepMediaDays") private var keepMediaDays = 30
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Cache
                SettingsSection(title: "Cache") {
                    HStack(spacing: 14) {
                        Circle()
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.orange)
                            )
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cache Size")
                                .font(.system(size: 16, weight: .medium))
                            
                            Text(cacheSize)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Button {
                            clearCache()
                        } label: {
                            if isClearingCache {
                                ProgressView()
                            } else {
                                Text("Clear")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.red)
                            }
                        }
                        .disabled(isClearingCache)
                    }
                    .padding(14)
                }
                
                // Media Settings
                SettingsSection(title: "Media") {
                    SettingsToggleRow(
                        title: "Auto-Download Media",
                        subtitle: "Automatically download photos and videos",
                        icon: "arrow.down.circle.fill",
                        iconColor: .blue,
                        isOn: $autoDownloadMedia
                    )
                    
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            Circle()
                                .fill(Color.purple.opacity(0.15))
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Image(systemName: "clock.fill")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(.purple)
                                )
                            
                            Text("Keep Media")
                                .font(.system(size: 16, weight: .medium))
                            
                            Spacer()
                        }
                        .padding(14)
                        
                        Picker("Keep Media", selection: $keepMediaDays) {
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                            Text("Forever").tag(0)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                    }
                }
                
                // Storage Usage
                SettingsSection(title: "Usage") {
                    StorageBarView()
                }
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            calculateCacheSize()
        }
    }
    
    private func calculateCacheSize() {
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let cacheURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            var size: Int64 = 0
            
            if let cacheURL = cacheURL {
                size = Self.directorySizeSync(at: cacheURL)
            }
            
            let formatted = Self.formatBytesStatic(size)
            await MainActor.run {
                cacheSize = formatted
            }
        }
    }
    
    /// nonisolated static helper so it can run off the main thread
    nonisolated private static func directorySizeSync(at url: URL) -> Int64 {
        let fm = FileManager.default
        var size: Int64 = 0
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(resourceKeys)) {
            for case let fileURL as URL in enumerator {
                if let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                   let fileSize = values.fileSize,
                   values.isDirectory == false {
                    size += Int64(fileSize)
                }
            }
        }
        return size
    }
    
    nonisolated private static func formatBytesStatic(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func clearCache() {
        isClearingCache = true
        Haptics.light()
        
        Task {
            let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            
            let safeURL = cacheURL
            await Task.detached(priority: .background) {
                if let safeURL = safeURL,
                   let contents = try? FileManager.default.contentsOfDirectory(at: safeURL, includingPropertiesForKeys: nil) {
                    for item in contents {
                        try? FileManager.default.removeItem(at: item)
                    }
                }
            }.value
            
            await MainActor.run {
                isClearingCache = false
                cacheSize = "0 B"
                Haptics.success()
            }
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Storage Bar View
struct StorageBarView: View {
    @State private var documentsSize: Int64 = 0
    @State private var cacheSize: Int64 = 0
    @State private var totalUsed: Int64 = 0
    @State private var totalAvailable: Int64 = 0
    @State private var isLoading = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Storage Used")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Text("\(formatBytes(totalUsed)) / \(formatBytes(totalAvailable))")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))
                        .frame(height: 8)
                    
                    // Stacked bar: Documents (blue) + Cache (purple)
                    HStack(spacing: 0) {
                        if documentsSize > 0 {
                            Capsule()
                                .fill(Color.blue)
                                .frame(width: max(2, geo.size.width * progressForSize(documentsSize)), height: 8)
                        }
                        if cacheSize > 0 {
                            Capsule()
                                .fill(Color.purple)
                                .frame(width: max(2, geo.size.width * progressForSize(cacheSize)), height: 8)
                        }
                    }
                }
            }
            .frame(height: 8)
            
            HStack(spacing: 16) {
                LegendItem(color: .blue, label: "Messages (\(formatBytes(documentsSize)))")
                LegendItem(color: .purple, label: "Cache (\(formatBytes(cacheSize)))")
            }
        }
        .padding(14)
        .onAppear {
            calculateStorageUsage()
        }
    }
    
    private func progressForSize(_ size: Int64) -> CGFloat {
        guard totalAvailable > 0 else { return 0 }
        return CGFloat(size) / CGFloat(totalAvailable)
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func calculateStorageUsage() {
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            
            // Calculate Documents folder size (messages DB, media, etc)
            var docSize: Int64 = 0
            if let docURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                docSize = Self.directorySize(at: docURL)
            }
            
            // Calculate Cache folder size
            var cSize: Int64 = 0
            if let cacheURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
                cSize = Self.directorySize(at: cacheURL)
            }
            
            // Get device storage info
            var totalSpace: Int64 = 0
            if let attributes = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()),
               let space = attributes[.systemSize] as? Int64 {
                totalSpace = space
            }
            
            let finalDocSize = docSize
            let finalCSize = cSize
            let finalTotalSpace = totalSpace
            
            await MainActor.run {
                documentsSize = finalDocSize
                cacheSize = finalCSize
                totalUsed = finalDocSize + finalCSize
                totalAvailable = finalTotalSpace > 0 ? finalTotalSpace : 64 * 1024 * 1024 * 1024 // fallback 64GB
                isLoading = false
            }
        }
    }
    
    // FIX: nonisolated so it can run off the main thread via Task.detached
    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var size: Int64 = 0
        
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(resourceKeys)) {
            for case let fileURL as URL in enumerator {
                if let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                   let fileSize = values.fileSize,
                   values.isDirectory == false {
                    size += Int64(fileSize)
                }
            }
        }
        
        return size
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        StorageSettingsView()
    }
}
