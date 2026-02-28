import SwiftUI
import PhotosUI

// MARK: - Group Settings View (Liquid Glass)

/// Premium group profile & settings — Liquid Glass + Capsule design
struct GroupSettingsView: View {
    let groupId: String
    let initialGroupName: String
    let initialGroupAvatarUrl: String?
    let initialMembers: [GroupMember]
    var onLeave: (() -> Void)? = nil
    
    @Environment(\.dismiss) private var dismiss
    
    // Mutable display state (initialized from init params in .task)
    @State private var displayName: String = ""
    @State private var displayAvatarUrl: String?
    @State private var displayMembers: [GroupMember] = []
    
    // Existing state
    @State private var editedName: String = ""
    @State private var showNameEditor = false
    @State private var showMemberNickname: GroupMember?
    @State private var nicknames: [String: String] = [:]
    
    // Avatar change
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false
    
    // 6-feature state
    @State private var muteSettings: MuteSettings = .unmuted
    @State private var inviteLink: InviteLinkResponse?
    @State private var isLoadingLink = false
    @State private var groupVisibility: String = "public"
    @State private var linkJoinEnabled: Bool = true
    @State private var showLeaveConfirm = false
    @State private var showResetLinkConfirm = false
    @State private var isLeaving = false
    @State private var memberToKick: GroupMember?
    @State private var actionError: String?
    @State private var showMuteSheet = false
    @State private var appeared = false
    
    private var currentUserId: String { AuthService.shared.currentUser?.id ?? "" }
    private var isAdmin: Bool { displayMembers.first(where: { $0.userId == currentUserId })?.isAdmin ?? false }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Deep dark background
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: DS.space16) {
                        // ── Hero Header ──
                        heroHeader
                            .padding(.top, DS.space8)
                        
                        // ── Customize ──
                        customizeCard
                        
                        // ── Notifications ──
                        notificationsCard
                        
                        // ── Members ──
                        membersCard
                        
                        // ── Invite + Privacy (admin) ──
                        if isAdmin {
                            invitePrivacyCard
                        }
                        
                        // ── Danger Zone ──
                        dangerCard
                        
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, DS.space16)
                    .padding(.bottom, DS.space32)
                }
            }
            .navigationTitle("Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.primary)
                }
            }
            // MARK: - Sheets
            .sheet(isPresented: $showNameEditor) {
                EditGroupNameSheet(
                    groupId: groupId,
                    currentName: editedName,
                    onSave: { newName in
                        Task {
                            do {
                                try await GroupService.shared.updateGroup(
                                    groupId: groupId,
                                    request: UpdateGroupRequest(name: newName)
                                )
                                await MainActor.run {
                                    displayName = newName
                                    editedName = newName
                                }
                                await ConversationStore.shared.loadFromDB()
                            } catch {
                                await MainActor.run {
                                    actionError = "Failed to rename: \(error.localizedDescription)"
                                }
                            }
                        }
                        showNameEditor = false
                    }
                )
                .presentationDetents([.height(200)])
            }

            .sheet(item: $showMemberNickname) { member in
                EditMemberNicknameSheet(
                    groupId: groupId,
                    member: member,
                    currentNickname: nicknames[member.userId],
                    onSave: { nickname in
                        if let nickname, !nickname.isEmpty {
                            nicknames[member.userId] = nickname
                        } else {
                            nicknames.removeValue(forKey: member.userId)
                        }
                        Task { await saveNickname(for: member.userId, nickname: nickname) }
                        showMemberNickname = nil
                    }
                )
                .presentationDetents([.height(220)])
            }
            .sheet(isPresented: $showMuteSheet) {
                muteBottomSheet
                    .presentationDetents([.height(320)])
                    .presentationDragIndicator(.visible)
            }
            // MARK: - Confirmations
            .confirmationDialog("Remove Member", isPresented: .init(
                get: { memberToKick != nil },
                set: { if !$0 { memberToKick = nil } }
            )) {
                if let member = memberToKick {
                    Button("Remove \(member.displayName)", role: .destructive) {
                        Task { await kickMember(member) }
                    }
                }
                Button("Cancel", role: .cancel) { memberToKick = nil }
            } message: {
                Text("This member will be removed from the group.")
            }
            .confirmationDialog("Leave Group", isPresented: $showLeaveConfirm) {
                Button("Leave Group", role: .destructive) {
                    Task { await performLeave() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll no longer receive messages from this group.")
            }
            .confirmationDialog("Reset Invite Link", isPresented: $showResetLinkConfirm) {
                Button("Reset Link", role: .destructive) {
                    Task { await performResetLink() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The current link will stop working.")
            }
            .alert("Error", isPresented: .init(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
        }
        .task {
            // Initialize mutable state from init params
            if displayName.isEmpty {
                displayName = initialGroupName
                displayAvatarUrl = initialGroupAvatarUrl
                displayMembers = initialMembers
            }
            await loadNicknames()
            muteSettings = await GroupService.shared.getMuteSettings(groupId: groupId)
            withAnimation(.easeOut(duration: 0.3)) { appeared = true }
        }
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Hero Header
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var heroHeader: some View {
        VStack(spacing: DS.space16) {
            // Avatar (tappable for admin to change photo)
            if isAdmin {
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    ZStack(alignment: .bottomTrailing) {
                        GlassAvatar(
                            name: displayName,
                            path: displayAvatarUrl,
                            size: 88
                        )
                        
                        if isUploadingAvatar {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 88, height: 88)
                                .overlay(ProgressView().tint(.white))
                        }
                        
                        Image(systemName: "camera.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .background(Circle().fill(.blue).frame(width: 28, height: 28))
                    }
                }
                .disabled(isUploadingAvatar)
                .onChange(of: selectedPhotoItem) { _, newItem in
                    guard let newItem else { return }
                    Task { await uploadGroupAvatar(item: newItem) }
                }
            } else {
                GlassAvatar(
                    name: displayName,
                    path: displayAvatarUrl,
                    size: 88
                )
            }
            
            // Name (tappable for admin)
            Button {
                if isAdmin {
                    editedName = displayName
                    showNameEditor = true
                }
            } label: {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                    
                    if isAdmin {
                        Image(systemName: "pencil.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            
            // Info row: member count + badges
            HStack(spacing: DS.space8) {
                Label("\(displayMembers.count) members", systemImage: "person.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                GlassChip(label: isAdmin ? "Admin" : "Member")
                
                if muteSettings.isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if groupVisibility == "private" {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.space24)
        .ravenCard()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .animation(.easeOut(duration: 0.35), value: appeared)
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Customize Card
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    @ViewBuilder
    private var customizeCard: some View {
        if isAdmin {
            VStack(spacing: 0) {
                sectionLabel("Customize")
                
                VStack(spacing: 1) {
                    settingsRow(icon: "pencil", label: "Change Group Name") {
                        editedName = displayName
                        showNameEditor = true
                    }
                    
                    if displayAvatarUrl != nil {
                        settingsRow(icon: "xmark.circle", label: "Remove Group Photo", tint: .red) {
                            Task { await removeGroupAvatar() }
                        }
                    }
                }
                .ravenCard(padding: 0)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .animation(.easeOut(duration: 0.35).delay(0.05), value: appeared)
        }
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Notifications Card
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var notificationsCard: some View {
        VStack(spacing: 0) {
            sectionLabel("Notifications")
            
            VStack(spacing: DS.space12) {
                // Mute row → taps open bottom sheet
                settingsRow(
                    icon: muteSettings.isMuted ? "bell.slash.fill" : "bell.fill",
                    label: "Mute",
                    trailingText: muteDisplayText
                ) {
                    showMuteSheet = true
                }
                
                glassRowDivider
                
                // Mentions only toggle
                HStack {
                    Image(systemName: "at")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    
                    Text("Mentions Only")
                        .font(.body)
                        .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    Toggle("", isOn: $muteSettings.mentionsOnly)
                        .labelsHidden()
                        .onChange(of: muteSettings.mentionsOnly) { _, _ in
                            Task {
                                await GroupService.shared.setMuteSettings(
                                    groupId: groupId, settings: muteSettings
                                )
                            }
                        }
                }
                .padding(.horizontal, DS.space16)
                .padding(.vertical, DS.space12)
            }
            .ravenCard(padding: 0)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .animation(.easeOut(duration: 0.35).delay(0.1), value: appeared)
    }
    
    private var muteDisplayText: String {
        guard let until = muteSettings.muteUntil else { return "Off" }
        if until == .distantFuture { return "Always" }
        let remaining = until.timeIntervalSinceNow
        if remaining <= 0 { return "Off" }
        if remaining <= 3600 { return "1 hour" }
        if remaining <= 28800 { return "8 hours" }
        if remaining <= 86400 { return "24 hours" }
        return "1 week"
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Members Card
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var membersCard: some View {
        VStack(spacing: 0) {
            sectionLabel("Members · \(displayMembers.count)")
            
            VStack(spacing: 0) {
                ForEach(Array(displayMembers.enumerated()), id: \.element.userId) { index, member in
                    let isSelf = member.userId == currentUserId
                    
                    memberRow(member: member, isSelf: isSelf)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if isAdmin && !isSelf {
                                Button(role: .destructive) {
                                    memberToKick = member
                                } label: {
                                    Label("Remove", systemImage: "person.fill.xmark")
                                }
                            }
                        }
                    
                    if index < displayMembers.count - 1 {
                        glassRowDivider
                    }
                }
            }
            .ravenCard(padding: 0)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .animation(.easeOut(duration: 0.35).delay(0.15), value: appeared)
    }
    
    private func memberRow(member: GroupMember, isSelf: Bool) -> some View {
        HStack(spacing: DS.space12) {
            GlassAvatar(
                name: nicknames[member.userId] ?? member.displayName,
                path: member.avatarUrl,
                size: 36,
                showGlow: false
            )
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(nicknames[member.userId] ?? member.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    if isSelf {
                        Text("You")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if nicknames[member.userId] != nil {
                    Text(member.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            if member.isAdmin {
                GlassChip(label: "Admin")
            }
            
            if nicknames[member.userId] != nil {
                Image(systemName: "tag.fill")
                    .font(.caption2)
                    .foregroundStyle(.purple.opacity(0.7))
            }
        }
        .padding(.horizontal, DS.space16)
        .padding(.vertical, DS.space12)
        .contentShape(Rectangle())
        .onTapGesture {
            showMemberNickname = member
        }
        .contextMenu {
            Button {
                showMemberNickname = member
            } label: {
                Label("Set Nickname", systemImage: "tag")
            }
            
            if isAdmin && !isSelf {
                Divider()
                
                if member.isAdmin {
                    Button {
                        Task { await demoteMember(member) }
                    } label: {
                        Label("Remove Admin", systemImage: "arrow.down.circle")
                    }
                } else {
                    Button {
                        Task { await promoteMember(member) }
                    } label: {
                        Label("Make Admin", systemImage: "arrow.up.circle")
                    }
                }
                
                Button(role: .destructive) {
                    memberToKick = member
                } label: {
                    Label("Remove from Group", systemImage: "person.fill.xmark")
                }
            }
        }
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Invite + Privacy Card
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var invitePrivacyCard: some View {
        VStack(spacing: 0) {
            sectionLabel("Invite & Privacy")
            
            VStack(spacing: DS.space12) {
                // Invite link
                if isLoadingLink {
                    HStack(spacing: DS.space8) {
                        ProgressView()
                            .tint(.secondary)
                        Text("Loading link...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(DS.space16)
                } else if let link = inviteLink {
                    VStack(alignment: .leading, spacing: DS.space12) {
                        // Link display
                        Text(inviteURL(link.inviteCode))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                            .padding(.horizontal, DS.space16)
                            .padding(.top, DS.space16)
                        
                        Text("\(link.useCount) joins")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, DS.space16)
                        
                        // Action buttons row
                        HStack(spacing: DS.space8) {
                            capsuleActionButton(
                                icon: "doc.on.doc",
                                label: "Copy"
                            ) {
                                UIPasteboard.general.string = inviteURL(link.inviteCode)
                                Haptics.light()
                            }
                            
                            capsuleActionButton(
                                icon: "square.and.arrow.up",
                                label: "Share"
                            ) {
                                let url = inviteURL(link.inviteCode)
                                let av = UIActivityViewController(
                                    activityItems: [url],
                                    applicationActivities: nil
                                )
                                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                   let root = scene.windows.first?.rootViewController {
                                    // iPad requires popover source configuration
                                    if let popover = av.popoverPresentationController {
                                        popover.sourceView = root.view
                                        popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
                                        popover.permittedArrowDirections = []
                                    }
                                    root.present(av, animated: true)
                                }
                            }
                            
                            capsuleActionButton(
                                icon: "arrow.counterclockwise",
                                label: "Reset",
                                tint: .orange
                            ) {
                                showResetLinkConfirm = true
                            }
                        }
                        .padding(.horizontal, DS.space16)
                    }
                } else {
                    Button {
                        Task { await loadInviteLink() }
                    } label: {
                        HStack(spacing: DS.space8) {
                            Image(systemName: "link.badge.plus")
                            Text("Generate Invite Link")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.space12)
                    }
                    .padding(.horizontal, DS.space16)
                }
                
                glassRowDivider
                
                // Privacy: Visibility
                HStack {
                    Image(systemName: "eye")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    
                    Text("Visibility")
                        .font(.body)
                        .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    Picker("", selection: $groupVisibility) {
                        Text("Public").tag("public")
                        Text("Private").tag("private")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .onChange(of: groupVisibility) { _, newValue in
                        Task {
                            try? await GroupService.shared.updateGroup(
                                groupId: groupId,
                                request: UpdateGroupRequest(visibility: newValue)
                            )
                        }
                    }
                }
                .padding(.horizontal, DS.space16)
                .padding(.vertical, DS.space8)
                
                // Link join toggle (private only)
                if groupVisibility == "private" {
                    glassRowDivider
                    
                    HStack {
                        Image(systemName: "link")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        
                        Text("Allow Join via Link")
                            .font(.body)
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        Toggle("", isOn: $linkJoinEnabled)
                            .labelsHidden()
                            .onChange(of: linkJoinEnabled) { _, newValue in
                                Task {
                                    try? await GroupService.shared.updateGroup(
                                        groupId: groupId,
                                        request: UpdateGroupRequest(linkJoinEnabled: newValue)
                                    )
                                }
                            }
                    }
                    .padding(.horizontal, DS.space16)
                    .padding(.vertical, DS.space8)
                }
            }
            .padding(.bottom, DS.space12)
            .ravenCard(padding: 0)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .animation(.easeOut(duration: 0.35).delay(0.2), value: appeared)
        .task {
            await loadInviteLink()
        }
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Danger Card
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var dangerCard: some View {
        VStack(spacing: DS.space12) {
            // Request Verification (channels only, admin only)
            if isAdmin {
                Button {
                    if let url = URL(string: "mailto:support@raven.app?subject=Channel%20Verification%20Request&body=Channel%20ID:%20\(groupId)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(spacing: DS.space8) {
                        Image(systemName: "checkmark.seal")
                        Text("Request Verification")
                    }
                    .font(.body.weight(.medium))
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(.blue.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .stroke(.blue.opacity(0.2), lineWidth: 0.6)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
            
            // Leave
            Button {
                showLeaveConfirm = true
            } label: {
                HStack(spacing: DS.space8) {
                    if isLeaving {
                        ProgressView()
                            .tint(.red)
                    } else {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Leave Group")
                    }
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(.red.opacity(0.12))
                        .overlay(
                            Capsule()
                                .stroke(.red.opacity(0.2), lineWidth: 0.6)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(isLeaving)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .animation(.easeOut(duration: 0.35).delay(0.25), value: appeared)
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Mute Bottom Sheet
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var muteBottomSheet: some View {
        VStack(spacing: DS.space24) {
            Text("Mute Group")
                .font(.headline)
                .foregroundStyle(.primary)
            
            VStack(spacing: DS.space8) {
                muteCapsuleOption(label: "Off", value: nil)
                muteCapsuleOption(label: "1 hour", value: Calendar.current.date(byAdding: .hour, value: 1, to: Date()))
                muteCapsuleOption(label: "8 hours", value: Calendar.current.date(byAdding: .hour, value: 8, to: Date()))
                muteCapsuleOption(label: "1 week", value: Calendar.current.date(byAdding: .day, value: 7, to: Date()))
                muteCapsuleOption(label: "Always", value: .distantFuture)
            }
            
            Spacer()
        }
        .padding(.top, DS.space24)
        .padding(.horizontal, DS.space16)
    }
    
    private func muteCapsuleOption(label: String, value: Date?) -> some View {
        let isSelected: Bool = {
            if value == nil && muteSettings.muteUntil == nil { return true }
            if let v = value, v == .distantFuture, muteSettings.muteUntil == .distantFuture { return true }
            return false
        }()
        
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                muteSettings.muteUntil = value
            }
            Task {
                await GroupService.shared.setMuteSettings(groupId: groupId, settings: muteSettings)
            }
            Haptics.light()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showMuteSheet = false
            }
        } label: {
            Text(label)
                .font(.body.weight(.medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(isSelected ? DS.accentBlue : Color.primary.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(isSelected ? 0 : 0.08), lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Reusable Components
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private func sectionLabel(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
            Spacer()
        }
        .padding(.horizontal, DS.space4)
        .padding(.bottom, DS.space4)
    }
    
    private func settingsRow(
        icon: String,
        label: String,
        trailingText: String? = nil,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.space12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(tint ?? .secondary)
                    .frame(width: 28)
                
                Text(label)
                    .font(.body)
                    .foregroundStyle(tint ?? .primary)
                
                Spacer()
                
                if let trailing = trailingText {
                    Text(trailing)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.space16)
            .padding(.vertical, DS.space12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private var glassRowDivider: some View {
        Rectangle()
            .fill(.primary.opacity(0.05))
            .frame(height: 0.5)
            .padding(.leading, 56)
    }
    
    private func capsuleActionButton(
        icon: String,
        label: String,
        tint: Color = .blue,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, DS.space12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
                    .overlay(
                        Capsule()
                            .stroke(tint.opacity(0.2), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Actions
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private func kickMember(_ member: GroupMember) async {
        do {
            let updatedGroup = try await GroupService.shared.kickMember(groupId: groupId, userId: member.userId)
            await MainActor.run {
                displayMembers = updatedGroup.members ?? displayMembers.filter { $0.userId != member.userId }
            }
            Haptics.success()
        } catch {
            actionError = "Failed to remove: \(error.localizedDescription)"
        }
    }
    
    private func promoteMember(_ member: GroupMember) async {
        do {
            try await GroupService.shared.promoteMember(groupId: groupId, userId: member.userId)
            Haptics.success()
        } catch {
            actionError = "Failed to promote: \(error.localizedDescription)"
        }
    }
    
    private func demoteMember(_ member: GroupMember) async {
        do {
            try await GroupService.shared.demoteMember(groupId: groupId, userId: member.userId)
            Haptics.success()
        } catch {
            actionError = "Failed to demote: \(error.localizedDescription)"
        }
    }
    
    private func performLeave() async {
        isLeaving = true
        do {
            try await GroupService.shared.leaveGroup(groupId: groupId)
            Haptics.success()
            // Refresh inbox to reflect removal
            await ConversationStore.shared.loadFromDB()
            await MainActor.run {
                dismiss()
                onLeave?()
            }
        } catch {
            isLeaving = false
            actionError = "Failed to leave: \(error.localizedDescription)"
        }
    }
    
    private func loadInviteLink() async {
        isLoadingLink = true
        do {
            inviteLink = try await GroupService.shared.getOrCreateInviteLink(groupId: groupId)
        } catch {
            #if DEBUG
            print("⚠️ [GroupSettings] Invite link load failed: \(error)")
            #endif
        }
        isLoadingLink = false
    }
    
    private func performResetLink() async {
        do {
            inviteLink = try await GroupService.shared.resetInviteLink(groupId: groupId)
            Haptics.success()
        } catch {
            actionError = "Failed to reset link: \(error.localizedDescription)"
        }
    }
    
    private func inviteURL(_ code: String) -> String {
        "https://raven.app/invite/\(code)"
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Avatar Upload / Remove
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private func uploadGroupAvatar(item: PhotosPickerItem) async {
        isUploadingAvatar = true
        defer { isUploadingAvatar = false }
        
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                actionError = "Could not load selected photo"
                return
            }
            
            // Compress to JPEG
            guard let uiImage = UIImage(data: data),
                  let jpegData = uiImage.jpegData(compressionQuality: 0.8) else {
                actionError = "Could not process image"
                return
            }
            
            struct AvatarUploadResponse: Decodable {
                let imageUrl: String
            }
            
            let response: AvatarUploadResponse = try await NetworkService.shared.uploadMultipart(
                path: "/api/uploads/image",
                fileData: jpegData,
                fileName: "group_avatar.jpg",
                mimeType: "image/jpeg"
            )
            
            try await GroupService.shared.updateGroup(
                groupId: groupId,
                request: UpdateGroupRequest(avatarUrl: response.imageUrl)
            )
            
            await MainActor.run {
                displayAvatarUrl = response.imageUrl
            }
            await ConversationStore.shared.loadFromDB()
            Haptics.success()
            #if DEBUG
            print("✅ [GroupSettings] Avatar uploaded: \(response.imageUrl)")
            #endif
        } catch {
            actionError = "Failed to upload photo: \(error.localizedDescription)"
        }
    }
    
    private func removeGroupAvatar() async {
        do {
            try await GroupService.shared.updateGroup(
                groupId: groupId,
                request: UpdateGroupRequest(avatarUrl: "")
            )
            await MainActor.run {
                displayAvatarUrl = nil
            }
            await ConversationStore.shared.loadFromDB()
            Haptics.success()
        } catch {
            actionError = "Failed to remove photo: \(error.localizedDescription)"
        }
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Data Loading / Saving
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private func loadNicknames() async {
        do {
            let db = DatabaseService.shared
            let sql = "SELECT member_id, nickname FROM group_nicknames WHERE group_id = ?"
            let rows = try await db.query(sql, params: [groupId])
            
            var loaded: [String: String] = [:]
            for row in rows {
                if let memberId = row["member_id"] as? String,
                   let nickname = row["nickname"] as? String {
                    loaded[memberId] = nickname
                }
            }
            await MainActor.run { nicknames = loaded }
        } catch {
            #if DEBUG
            print("❌ [GroupSettings] Failed to load nicknames: \(error)")
            #endif
        }
    }
    
    private func saveNickname(for memberId: String, nickname: String?) async {
        do {
            let db = DatabaseService.shared
            let id = "\(groupId)_\(memberId)"
            
            if let nickname, !nickname.isEmpty {
                let sql = """
                    INSERT INTO group_nicknames (id, group_id, member_id, nickname, updated_at)
                    VALUES (?, ?, ?, ?, datetime('now'))
                    ON CONFLICT(group_id, member_id) DO UPDATE SET
                        nickname = excluded.nickname,
                        updated_at = excluded.updated_at
                """
                try await db.execute(sql, params: [id, groupId, memberId, nickname])
            } else {
                let sql = "DELETE FROM group_nicknames WHERE group_id = ? AND member_id = ?"
                try await db.execute(sql, params: [groupId, memberId])
            }
        } catch {
            #if DEBUG
            print("❌ [GroupSettings] Failed to save nickname: \(error)")
            #endif
        }
    }
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Edit Group Name Sheet
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct EditGroupNameSheet: View {
    let groupId: String
    @State var currentName: String
    let onSave: (String) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Group Name", text: $currentName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .padding(.horizontal)
                
                Text("2-40 characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("Edit Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(currentName)
                    }
                    .disabled(currentName.count < 2 || currentName.count > 40)
                }
            }
        }
        .onAppear { isFocused = true }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Edit Member Nickname Sheet
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct EditMemberNicknameSheet: View {
    let groupId: String
    let member: GroupMember
    let currentNickname: String?
    let onSave: (String?) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var nickname: String = ""
    @FocusState private var isFocused: Bool
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    GlassAvatar(name: member.displayName, path: member.avatarUrl, size: 44)
                    
                    VStack(alignment: .leading) {
                        Text(member.displayName)
                            .font(.headline)
                        Text("Set a nickname only you will see")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                
                TextField("Nickname (optional)", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .padding(.horizontal)
                
                Spacer()
            }
            .padding(.top, 16)
            .navigationTitle("Set Nickname")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(nickname.isEmpty ? nil : nickname)
                    }
                }
            }
        }
        .onAppear {
            nickname = currentNickname ?? ""
            isFocused = true
        }
    }
}



// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Preview
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

#Preview {
    GroupSettingsView(
        groupId: "test",
        initialGroupName: "Raven Team",
        initialGroupAvatarUrl: nil,
        initialMembers: [
            GroupMember(userId: "1", username: "admin_user", avatarUrl: nil, role: "admin", joinedAt: .now),
            GroupMember(userId: "2", username: "member_a", avatarUrl: nil, role: "member", joinedAt: .now),
            GroupMember(userId: "3", username: "member_b", avatarUrl: nil, role: "member", joinedAt: .now)
        ]
    )
    .preferredColorScheme(.dark)
}
