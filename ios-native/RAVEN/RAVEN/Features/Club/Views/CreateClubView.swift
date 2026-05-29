//
//  CreateClubView.swift
//  RAVEN
//
//  Sheet/push for creating a new Club group.
//

import SwiftUI

// MARK: - Create Club View

struct CreateClubView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = ClubStore.shared
    
    @State private var name = ""
    @State private var durationHours = 6
    @State private var dropThreshold = 200
    @State private var clubDescription = ""
    @State private var contactEmail = ""
    @State private var externalLink = ""
    @State private var locationPrecision: Club.LocationPrecision = .exact
    @State private var locationSource: Club.LocationSource = .meshOnly
    @State private var isSending = false
    @State private var showSuccess = false
    @State private var createdInviteCode: String?
    @State private var errorMessage: String?
    
    private let durationOptions = [1, 3, 6, 12, 24]
    private let thresholdOptions = [50, 100, 200, 300, 500]
    
    var body: some View {
        ZStack {
            Form {
                Section("Group Name") {
                    TextField("e.g. Concert NYC", text: $name)
                        .textInputAutocapitalization(.words)
                    
                    Text("\(name.count)/40")
                        .font(.caption2)
                        .foregroundStyle(name.count > 40 ? .red : .secondary)
                }
                
                Section {
                    TextField("What's this club about?", text: $clubDescription, axis: .vertical)
                        .lineLimit(3...6)
                    
                    Text("\(clubDescription.count)/200")
                        .font(.caption2)
                        .foregroundStyle(clubDescription.count > 200 ? .red : .secondary)
                } header: {
                    Text("About")
                } footer: {
                    Text("Optional. Visible on the club profile.")
                }
                
                Section("Duration") {
                    Picker("Duration", selection: $durationHours) {
                        ForEach(durationOptions, id: \.self) { hours in
                            Text("\(hours)h").tag(hours)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section {
                    Picker("Alert Distance", selection: $dropThreshold) {
                        ForEach(thresholdOptions, id: \.self) { meters in
                            Text("\(meters)m").tag(meters)
                        }
                    }
                } header: {
                    Text("Drop Alert Distance")
                } footer: {
                    Text("You'll receive an alert if a member drifts beyond this distance")
                }
                
                // MARK: - Location Privacy (card-style)
                Section {
                    ForEach(Club.LocationPrecision.allCases, id: \.self) { precision in
                        Button {
                            withAnimation(.spring(response: 0.25)) {
                                locationPrecision = precision
                            }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: precision.icon)
                                    .font(.title3)
                                    .foregroundStyle(locationPrecision == precision ? .white : .primary)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        locationPrecision == precision
                                            ? AnyShapeStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                                            : AnyShapeStyle(Color.secondary.opacity(0.12)),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(precision.label)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(precision.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: locationPrecision == precision ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(locationPrecision == precision ? .blue : .secondary.opacity(0.4))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Location Privacy")
                } footer: {
                    Text(locationPrecision.description)
                }
                
                // MARK: - Location Source (card-style)
                Section {
                    ForEach(Club.LocationSource.allCases, id: \.self) { source in
                        Button {
                            withAnimation(.spring(response: 0.25)) {
                                locationSource = source
                            }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: source.icon)
                                    .font(.title3)
                                    .foregroundStyle(locationSource == source ? .white : .primary)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        locationSource == source
                                            ? AnyShapeStyle(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                                            : AnyShapeStyle(Color.secondary.opacity(0.12)),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.label)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(source.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: locationSource == source ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(locationSource == source ? .orange : .secondary.opacity(0.4))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Location Source")
                } footer: {
                    switch locationSource {
                    case .meshOnly:
                        Text("Uses Bluetooth mesh only. No data leaves your device. Most private.")
                    case .internetOnly:
                        Text("Uses GPS via network for best accuracy. Requires internet connection.")
                    case .hybrid:
                        Text("Uses internet when available, falls back to mesh when offline. Best balance.")
                    }
                }
                
                Section {
                    TextField("Email (optional)", text: $contactEmail)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    
                    TextField("External link (optional)", text: $externalLink)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Contact Info")
                } footer: {
                    Text("Members can reach you through these. Your name stays hidden — only the club name is shown.")
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
                successView
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .navigationTitle("New Club")
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
                        Text("Create")
                            .fontWeight(.semibold)
                    }
                }
                .disabled(!canCreate || isSending || showSuccess)
            }
        }
    }
    
    // MARK: - Success View
    
    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: showSuccess)
            
            Text("Club Created!")
                .font(.title3.weight(.bold))
            
            if let code = createdInviteCode {
                VStack(spacing: 6) {
                    Text("Invite Code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(code)
                        .font(.title.weight(.bold).monospaced())
                        .foregroundStyle(
                            LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)
                        )
                    
                    Text("Share this code with your group")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            
            Text("Broadcasting via Mesh…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
    
    // MARK: - Logic
    
    private var canCreate: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 40 && clubDescription.count <= 200
    }
    
    private func create() async {
        errorMessage = nil
        isSending = true
        
        let desc = clubDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = externalLink.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let inviteCode = await store.createClub(
            name: name,
            durationHours: durationHours,
            dropThresholdMeters: dropThreshold,
            clubDescription: desc.isEmpty ? nil : desc,
            contactEmail: email.isEmpty ? nil : email,
            externalLink: link.isEmpty ? nil : link,
            locationPrecision: locationPrecision,
            locationSource: locationSource
        )
        
        isSending = false
        
        if let code = inviteCode {
            createdInviteCode = code
            
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                showSuccess = true
            }
            
            Haptics.medium()
            
            // Auto-dismiss after showing success
            try? await Task.sleep(for: .seconds(3.0))
            dismiss()
        } else {
            errorMessage = store.errorMessage ?? "Failed to create club"
            // Auto-clear error
            try? await Task.sleep(for: .seconds(3.0))
            withAnimation { errorMessage = nil }
        }
    }
}

#Preview {
    CreateClubView()
}
