//
//  EchoComposerView.swift
//  RAVEN
//
//  Sheet for composing a new Echo broadcast.
//  Simple form: text + TTL + optional location sharing.
//

import SwiftUI

// MARK: - Echo Composer View

struct EchoComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = EchoStore.shared
    
    @State private var content = ""
    @State private var ttlOption: TTLOption = .sixHours
    @State private var shareLocation = false
    @State private var isSending = false
    @State private var showSuccess = false
    
    enum TTLOption: String, CaseIterable {
        case oneHour = "1 hour"
        case sixHours = "6 hours"
        case twentyFourHours = "24 hours"
        
        var minutes: Int {
            switch self {
            case .oneHour: return 60
            case .sixHours: return 360
            case .twentyFourHours: return 1440
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header illustration
                VStack(spacing: 8) {
                    Image(systemName: "megaphone.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(
                            LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    
                    Text("Send Anonymous Broadcast")
                        .font(.headline)
                    
                    Text("Everyone in your mesh network will see it and respond with emoji")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)
                
                // Text input
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $content)
                        .frame(minHeight: 100, maxHeight: 150)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.white.opacity(0.1), lineWidth: 1)
                        )
                        .overlay(alignment: .topLeading) {
                            if content.isEmpty {
                                Text("Write your question…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 16)
                                    .padding(.top, 20)
                                    .allowsHitTesting(false)
                            }
                        }
                    
                    HStack {
                        Text("\(content.count)/200")
                            .font(.caption2)
                            .foregroundStyle(content.count > 200 ? .red : .secondary)
                        
                        Spacer()
                    }
                }
                
                // TTL Picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Display Duration")
                        .font(.subheadline.weight(.medium))
                    
                    Picker("TTL", selection: $ttlOption) {
                        ForEach(TTLOption.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                // Location toggle
                Toggle(isOn: $shareLocation) {
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text("Share Location (city level)")
                                .font(.subheadline)
                            Text("H3 cell resolution 5 only (~8km)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.purple)
                
                Spacer()
                
                // Send button
                Button {
                    Task { await sendEcho() }
                } label: {
                    HStack {
                        if isSending {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "paperplane.fill")
                            Text("Broadcast to Mesh")
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: canSend ? [.purple, .indigo] : [.gray.opacity(0.4)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }
                .disabled(!canSend || isSending)
            }
            .padding(20)
            .navigationTitle("New Echo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if showSuccess {
                    successOverlay
                }
            }
            .overlay {
                if let error = store.errorMessage {
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
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { store.errorMessage = nil }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Computed
    
    private var canSend: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 200
    }
    
    // MARK: - Actions
    
    private func sendEcho() async {
        isSending = true
        
        let success = await store.createEcho(
            content: content,
            ttlMinutes: ttlOption.minutes,
            shareLocation: shareLocation
        )
        
        isSending = false
        
        if success {
            withAnimation(.spring(response: 0.4)) {
                showSuccess = true
            }
            // Auto-dismiss after toast animation; cancellation just dismisses early.
            try? await Task.sleep(for: .seconds(2.0))
            dismiss()
        } else {
            // Show error inline
            store.errorMessage = store.errorMessage ?? "Failed to send Echo. Try again."
        }
    }
    
    // MARK: - Success Overlay
    
    private var successOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: showSuccess)
            
            Text("Sent!")
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .transition(.opacity)
    }
}

#Preview {
    EchoComposerView()
}
