//
//  VaultListView.swift
//  RAVEN
//
//  Displays nearby vault-locked content with unlock buttons.
//

import SwiftUI

// MARK: - Vault Content List View

struct VaultListView: View {
    @StateObject private var service = VaultService.shared
    @State private var showCreateSheet = false
    @State private var selectedContent: VaultedContent?
    @State private var unlockResult: String?
    @State private var unlockFailed = false
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if service.nearbyContent.isEmpty {
                    emptyState
                } else {
                    ForEach(service.nearbyContent) { content in
                        VaultContentCard(
                            content: content,
                            unlockedText: service.unlockedContent[content.id],
                            onUnlock: {
                                Task { await attemptUnlock(content) }
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, DS.bottomTabClearance + 20)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                showCreateSheet = true
            } label: {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(
                        LinearGradient(
                            colors: [.teal, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Circle())
                    .shadow(color: .teal.opacity(0.4), radius: 12, y: 4)
            }
            .padding(.trailing, 20)
            .padding(.bottom, DS.bottomTabClearance + 16)
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateVaultContentView()
        }
        .alert("🔓 Content Unlocked!", isPresented: Binding(
            get: { unlockResult != nil },
            set: { if !$0 { unlockResult = nil } }
        )) {
            Button("Close") { unlockResult = nil }
        } message: {
            Text(unlockResult ?? "")
        }
        .alert("🔒 Still Locked", isPresented: $unlockFailed) {
            Button("OK") {}
        } message: {
            Text("Get closer to the target location to unlock the content")
        }
        .task {
            await service.loadNearbyContent()
        }
    }
    
    private func attemptUnlock(_ content: VaultedContent) async {
        if let text = await service.tryUnlock(contentId: content.id) {
            unlockResult = text
        } else {
            unlockFailed = true
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Vault content nearby")
                .font(.title3.weight(.medium))
            Text("Create location-locked content that can only\nbe unlocked at a specific place!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
    }
}

// MARK: - Vault Content Card

struct VaultContentCard: View {
    let content: VaultedContent
    let unlockedText: String?
    let onUnlock: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: content.isUnlocked ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(content.isUnlocked ? .green : .orange)
                
                Text(content.title)
                    .font(.headline)
                
                Spacer()
                
                Text(content.timeRemaining)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            
            // Unlocked content
            if let text = unlockedText {
                Text(text)
                    .font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                // Locked state
                HStack {
                    Image(systemName: "location.fill")
                        .font(.caption)
                    Text("~\(content.unlockDistance)m to unlock")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                
                Button(action: onUnlock) {
                    HStack {
                        Image(systemName: "location.viewfinder")
                        Text("Try to Unlock")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(colors: [.teal, .blue], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    content.isUnlocked ?
                        AnyShapeStyle(.green.opacity(0.3)) :
                        AnyShapeStyle(.white.opacity(0.08)),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Create Vault Content View

struct CreateVaultContentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""
    @State private var ttlHours = 24
    @State private var isSending = false
    @State private var showSuccess = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    Section("Title (visible before unlock)") {
                        TextField("e.g. Hidden message at the café", text: $title)
                        Text("\(title.count)/60")
                            .font(.caption2)
                            .foregroundStyle(title.count > 60 ? .red : .secondary)
                    }
                    
                    Section("Content (visible only after unlock)") {
                        TextEditor(text: $content)
                            .frame(minHeight: 100)
                    }
                    
                    Section("Duration") {
                        Picker("Duration", selection: $ttlHours) {
                            Text("6 hours").tag(6)
                            Text("24 hours").tag(24)
                            Text("7 days").tag(168)
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.teal)
                            Text("Content is encrypted with a key derived from your current location. Only someone physically near this place can unlock it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .opacity(showSuccess ? 0.3 : 1)
                
                // Error banner
                if let error = errorMessage {
                    VStack {
                        Spacer()
                        Text(error)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.red.gradient, in: Capsule())
                            .padding(.bottom, 8)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                // Success overlay
                if showSuccess {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(
                                LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .symbolEffect(.bounce, value: showSuccess)
                        
                        Text("Vault Created!")
                            .font(.title3.weight(.bold))
                        
                        Text("Content encrypted and broadcasting via mesh.\nAnyone near this location can try to unlock it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .navigationTitle("New Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .opacity(showSuccess ? 0 : 1)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Text("Encrypt & Send")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canCreate || isSending || showSuccess)
                }
            }
        }
    }
    
    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        title.count <= 60
    }
    
    private func create() async {
        errorMessage = nil
        
        guard let loc = LocationPrivacyService.shared.currentLocation else {
            withAnimation {
                errorMessage = "Location not available. Enable Location Services and try again."
            }
            try? await Task.sleep(for: .seconds(3.0))
            withAnimation { errorMessage = nil }
            return
        }
        
        isSending = true
        
        let _ = await VaultService.shared.createContent(
            plaintext: content,
            title: title,
            targetLat: loc.latitude,
            targetLng: loc.longitude,
            ttlHours: ttlHours
        )
        
        isSending = false
        
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            showSuccess = true
        }
        
        Haptics.medium()
        
        // Auto-dismiss after showing success
        try? await Task.sleep(for: .seconds(2.5))
        dismiss()
    }
}

#Preview {
    CreateVaultContentView()
}
