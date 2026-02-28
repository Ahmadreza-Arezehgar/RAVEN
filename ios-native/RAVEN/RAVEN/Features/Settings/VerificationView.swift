import SwiftUI
import PhotosUI

// MARK: - Verification Status Enum

enum VerificationStatus: String, Codable {
    case notVerified = "not_verified"
    case pending = "pending"
    case needsMoreInfo = "needs_more_info"
    case rejected = "rejected"
    case verified = "verified"
    case revoked = "revoked"
}

// MARK: - Verification Status Response

struct VerificationStatusResponse: Codable {
    let status: String
    let submittedAt: String?
    let reviewedAt: String?
    let reason: String?
    let category: String?
    let badgeType: String?
    let canReapply: Bool?
    let reapplyAfter: String?
    
    // ✅ Bug 4 fix: Removed explicit snake_case raw values — NetworkService.decoder
    // uses .convertFromSnakeCase which auto-converts them.
    enum CodingKeys: String, CodingKey {
        case status
        case submittedAt
        case reviewedAt
        case reason
        case category
        case badgeType
        case canReapply
        case reapplyAfter
    }
}

// MARK: - Doc Upload Response

struct DocUploadResponse: Codable {
    let docUrl: String
    let filename: String
    let size: Int
    let mimeType: String?
    
    enum CodingKeys: String, CodingKey {
        case docUrl
        case filename
        case size
        case mimeType
    }
}

// MARK: - Verification View

struct VerificationView: View {
    @State private var currentStatus: VerificationStatus = .notVerified
    @State private var statusResponse: VerificationStatusResponse?
    @State private var isLoading = true
    @State private var error: String?
    
    // Wizard state
    @State private var wizardStep = 0  // 0=info, 1=docs, 2=review
    @State private var showWizard = false
    
    // Step 1: Personal info
    @State private var legalFirstName = ""
    @State private var legalLastName = ""
    @State private var country = ""
    @State private var category = "person"
    
    // Step 2: Documents
    @State private var docType = "passport"
    @State private var docFrontImage: UIImage?
    @State private var docBackImage: UIImage?
    @State private var selfieImage: UIImage?
    @State private var docFrontUrl: String?
    @State private var docBackUrl: String?
    @State private var selfieUrl: String?
    
    // Photo pickers
    @State private var showFrontPicker = false
    @State private var showBackPicker = false
    @State private var showSelfiePicker = false
    @State private var selectedFrontItem: PhotosPickerItem?
    @State private var selectedBackItem: PhotosPickerItem?
    @State private var selectedSelfieItem: PhotosPickerItem?
    
    // Submission
    @State private var isSubmitting = false
    @State private var submitSuccess = false
    
    let categories = [
        ("person", "Person", "person.fill"),
        ("brand", "Brand", "building.2.fill"),
        ("org", "Organization", "person.3.fill")
    ]
    
    let docTypes = [
        ("passport", "Passport", "airplane"),
        ("national_id", "National ID", "creditcard.fill"),
        ("drivers_license", "Driver's License", "car.fill")
    ]
    
    let countries = [
        "Afghanistan", "Albania", "Algeria", "Argentina", "Australia", "Austria",
        "Belgium", "Brazil", "Canada", "China", "Colombia", "Denmark", "Egypt",
        "Finland", "France", "Germany", "Greece", "India", "Indonesia", "Iran",
        "Iraq", "Ireland", "Israel", "Italy", "Japan", "Jordan", "Kenya",
        "Lebanon", "Malaysia", "Mexico", "Morocco", "Netherlands", "New Zealand",
        "Nigeria", "Norway", "Pakistan", "Philippines", "Poland", "Portugal",
        "Qatar", "Romania", "Russia", "Saudi Arabia", "South Africa", "South Korea",
        "Spain", "Sweden", "Switzerland", "Thailand", "Turkey", "UAE",
        "United Kingdom", "United States", "Vietnam"
    ]
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if isLoading {
                    ProgressView()
                        .padding(.top, 60)
                } else if showWizard {
                    wizardView
                } else {
                    statusView
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
        }
        .navigationTitle("Verification")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await fetchStatus()
        }
    }
    
    // MARK: - Status View (shows current state)
    
    @ViewBuilder
    var statusView: some View {
        switch currentStatus {
        case .notVerified:
            notVerifiedView
        case .pending:
            pendingView
        case .needsMoreInfo:
            needsMoreInfoView
        case .rejected:
            rejectedView
        case .verified:
            verifiedView
        case .revoked:
            revokedView
        }
    }
    
    // MARK: - Not Verified
    
    var notVerifiedView: some View {
        VStack(spacing: 20) {
            // Hero icon
            ZStack {
                Circle()
                    .fill(.blue.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.blue.opacity(0.6))
            }
            .padding(.top, 20)
            
            Text("Get Verified")
                .font(.system(size: 28, weight: .bold))
            
            Text("Verify your identity to earn a badge that shows others you're authentic. The badge appears next to your name across RAVEN.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            
            // Requirements
            VStack(alignment: .leading, spacing: 12) {
                requirementRow(icon: "person.text.rectangle", text: "Government-issued ID")
                requirementRow(icon: "camera.fill", text: "A selfie for identity match")
                requirementRow(icon: "clock", text: "Review takes 1-3 business days")
            }
            .padding(20)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            
            Button {
                withAnimation(.spring(response: 0.4)) {
                    showWizard = true
                    wizardStep = 0
                }
            } label: {
                Text("Start Verification")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(colors: [.blue, .blue.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.top, 8)
        }
    }
    
    // MARK: - Pending
    
    var pendingView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.orange.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.orange)
            }
            .padding(.top, 20)
            
            Text("Under Review")
                .font(.system(size: 28, weight: .bold))
            
            Text("Your verification request is being reviewed. This usually takes 1-3 business days.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            if let submitted = statusResponse?.submittedAt {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                    Text("Submitted: \(formatDate(submitted))")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }
            
            Button(role: .destructive) {
                Task { await cancelRequest() }
            } label: {
                Text("Cancel Request")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.red)
            }
            .padding(.top, 8)
        }
    }
    
    // MARK: - Needs More Info
    
    var needsMoreInfoView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.yellow.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.yellow)
            }
            .padding(.top, 20)
            
            Text("More Info Needed")
                .font(.system(size: 28, weight: .bold))
            
            if let reason = statusResponse?.reason {
                Text(reason)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            
            Button {
                withAnimation(.spring(response: 0.4)) {
                    showWizard = true
                    wizardStep = 0
                }
            } label: {
                Text("Resubmit")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
    
    // MARK: - Rejected
    
    var rejectedView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.red.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "xmark.seal")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.red)
            }
            .padding(.top, 20)
            
            Text("Request Declined")
                .font(.system(size: 28, weight: .bold))
            
            if let reason = statusResponse?.reason {
                Text(reason)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            
            if statusResponse?.canReapply == true {
                Button {
                    withAnimation(.spring(response: 0.4)) {
                        showWizard = true
                        wizardStep = 0
                    }
                } label: {
                    Text("Re-apply")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            } else if let reapplyAfter = statusResponse?.reapplyAfter {
                Text("You can reapply after \(formatDate(reapplyAfter))")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }
        }
    }
    
    // MARK: - Verified
    
    var verifiedView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.blue.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 50, weight: .medium))
                    .foregroundStyle(.blue)
                    .shadow(color: .blue.opacity(0.3), radius: 8)
            }
            .padding(.top, 20)
            
            Text("Verified")
                .font(.system(size: 28, weight: .bold))
            
            Text("Your identity has been verified. Your badge is visible across RAVEN.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            if let reviewed = statusResponse?.reviewedAt {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Verified on \(formatDate(reviewed))")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }
        }
    }
    
    // MARK: - Revoked
    
    var revokedView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.gray.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "xmark.seal")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.gray)
            }
            .padding(.top, 20)
            
            Text("Verification Revoked")
                .font(.system(size: 28, weight: .bold))
            
            if let reason = statusResponse?.reason {
                Text(reason)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button {
                withAnimation(.spring(response: 0.4)) {
                    showWizard = true
                    wizardStep = 0
                }
            } label: {
                Text("Re-apply")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
    
    // MARK: - Wizard View
    
    var wizardView: some View {
        VStack(spacing: 24) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(0..<3) { step in
                    Capsule()
                        .fill(step <= wizardStep ? Color.blue : Color.gray.opacity(0.3))
                        .frame(height: 4)
                        .animation(.easeInOut, value: wizardStep)
                }
            }
            .padding(.horizontal, 4)
            
            switch wizardStep {
            case 0:
                wizardStep1
            case 1:
                wizardStep2
            case 2:
                wizardStep3
            default:
                EmptyView()
            }
        }
    }
    
    // MARK: - Step 1: Personal Info
    
    var wizardStep1: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Personal Information")
                .font(.system(size: 24, weight: .bold))
            
            Text("Provide your legal name as it appears on your ID.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            
            // Category picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Category")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 10) {
                    ForEach(categories, id: \.0) { cat in
                        Button {
                            category = cat.0
                            Haptics.light()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: cat.2)
                                    .font(.system(size: 20))
                                Text(cat.1)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(category == cat.0 ? Color.blue.opacity(0.15) : Color(.systemGray6))
                            .foregroundStyle(category == cat.0 ? .blue : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(category == cat.0 ? Color.blue : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            // Name fields
            glassTextField(label: "Legal First Name", text: $legalFirstName, placeholder: "As shown on ID")
            glassTextField(label: "Legal Last Name", text: $legalLastName, placeholder: "As shown on ID")
            
            // Country picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Country")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                
                Menu {
                    ForEach(countries, id: \.self) { c in
                        Button(c) { country = c }
                    }
                } label: {
                    HStack {
                        Text(country.isEmpty ? "Select country" : country)
                            .foregroundStyle(country.isEmpty ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            
            // Next button
            Button {
                withAnimation(.spring(response: 0.3)) {
                    wizardStep = 1
                }
                Haptics.light()
            } label: {
                Text("Continue")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(step1Valid ? Color.blue : Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(!step1Valid)
        }
    }
    
    // MARK: - Step 2: Document Upload
    
    var wizardStep2: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Identity Document")
                .font(.system(size: 24, weight: .bold))
            
            Text("Upload a clear photo of your government-issued ID.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            
            // Doc type picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Document Type")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 10) {
                    ForEach(docTypes, id: \.0) { dt in
                        Button {
                            docType = dt.0
                            Haptics.light()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: dt.2)
                                    .font(.system(size: 18))
                                Text(dt.1)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(docType == dt.0 ? Color.blue.opacity(0.15) : Color(.systemGray6))
                            .foregroundStyle(docType == dt.0 ? .blue : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(docType == dt.0 ? Color.blue : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            // Document front
            docUploadCard(
                title: "Front of Document",
                image: docFrontImage,
                uploaded: docFrontUrl != nil
            ) {
                showFrontPicker = true
            }
            
            // Document back
            docUploadCard(
                title: "Back of Document",
                image: docBackImage,
                uploaded: docBackUrl != nil
            ) {
                showBackPicker = true
            }
            
            // Selfie
            docUploadCard(
                title: "Selfie",
                image: selfieImage,
                uploaded: selfieUrl != nil
            ) {
                showSelfiePicker = true
            }
            
            // Navigation
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        wizardStep = 0
                    }
                } label: {
                    Text("Back")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        wizardStep = 2
                    }
                    Haptics.light()
                } label: {
                    Text("Continue")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(step2Valid ? Color.blue : Color.gray)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!step2Valid)
            }
        }
        .photosPicker(isPresented: $showFrontPicker, selection: $selectedFrontItem, matching: .images)
        .photosPicker(isPresented: $showBackPicker, selection: $selectedBackItem, matching: .images)
        .photosPicker(isPresented: $showSelfiePicker, selection: $selectedSelfieItem, matching: .images)
        .onChange(of: selectedFrontItem) { _, item in
            Task { await loadAndUpload(item: item, target: .front) }
        }
        .onChange(of: selectedBackItem) { _, item in
            Task { await loadAndUpload(item: item, target: .back) }
        }
        .onChange(of: selectedSelfieItem) { _, item in
            Task { await loadAndUpload(item: item, target: .selfie) }
        }
    }
    
    // MARK: - Step 3: Review & Submit
    
    var wizardStep3: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Review & Submit")
                .font(.system(size: 24, weight: .bold))
            
            Text("Please confirm your information before submitting.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            
            // Summary card
            VStack(alignment: .leading, spacing: 14) {
                summaryRow(label: "Name", value: "\(legalFirstName) \(legalLastName)")
                Divider()
                summaryRow(label: "Category", value: category.capitalized)
                Divider()
                summaryRow(label: "Country", value: country)
                Divider()
                summaryRow(label: "Document", value: docTypes.first(where: { $0.0 == docType })?.1 ?? docType)
                Divider()
                summaryRow(label: "Front", value: docFrontUrl != nil ? "✓ Uploaded" : "✗ Missing")
                summaryRow(label: "Back", value: docBackUrl != nil ? "✓ Uploaded" : "✗ Missing")
                summaryRow(label: "Selfie", value: selfieUrl != nil ? "✓ Uploaded" : "✗ Missing")
            }
            .padding(16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            
            // Privacy note
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
                Text("Your documents are encrypted and stored securely. They are only accessed during the review process and deleted afterward.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.green.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            
            // Navigation
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        wizardStep = 1
                    }
                } label: {
                    Text("Back")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                
                Button {
                    Task { await submitRequest() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        Text("Submit Request")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .disabled(isSubmitting)
            }
            
            if let error = error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }
    
    // MARK: - Helper Views
    
    func requirementRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 15))
        }
    }
    
    func glassTextField(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(14)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
    
    func docUploadCard(title: String, image: UIImage?, uploaded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.systemGray5))
                        .frame(width: 60, height: 42)
                        .overlay(
                            Image(systemName: "camera.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                        )
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                    Text(uploaded ? "Uploaded ✓" : "Tap to upload")
                        .font(.system(size: 13))
                        .foregroundStyle(uploaded ? .green : .secondary)
                }
                
                Spacer()
                
                Image(systemName: uploaded ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(uploaded ? .green : .blue)
            }
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
    
    func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
        }
    }
    
    // MARK: - Validation
    
    var step1Valid: Bool {
        !legalFirstName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !legalLastName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !country.isEmpty
    }
    
    var step2Valid: Bool {
        docFrontUrl != nil && selfieUrl != nil
    }
    
    // MARK: - Document Upload Target
    
    enum DocTarget {
        case front, back, selfie
    }
    
    // MARK: - Network Functions
    
    func fetchStatus() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let response: VerificationStatusResponse = try await NetworkService.shared.get(
                path: "/api/verification/status"
            )
            statusResponse = response
            currentStatus = VerificationStatus(rawValue: response.status) ?? .notVerified
        } catch {
            currentStatus = .notVerified
        }
    }
    
    func cancelRequest() async {
        do {
            let _: [String: String] = try await NetworkService.shared.post(
                path: "/api/verification/cancel",
                body: EmptyBody()
            )
            await fetchStatus()
        } catch {
            self.error = "Failed to cancel request."
        }
    }
    
    func loadAndUpload(item: PhotosPickerItem?, target: DocTarget) async {
        guard let item = item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        guard let uiImage = UIImage(data: data) else { return }
        
        // Set preview image
        await MainActor.run {
            switch target {
            case .front: docFrontImage = uiImage
            case .back: docBackImage = uiImage
            case .selfie: selfieImage = uiImage
            }
        }
        
        // Upload to server
        do {
            let response = try await uploadDocument(imageData: data)
            await MainActor.run {
                switch target {
                case .front: docFrontUrl = response.docUrl
                case .back: docBackUrl = response.docUrl
                case .selfie: selfieUrl = response.docUrl
                }
            }
        } catch {
            await MainActor.run {
                self.error = "Failed to upload document."
            }
        }
    }
    
    func uploadDocument(imageData: Data) async throws -> DocUploadResponse {
        // Upload as multipart form data
        let boundary = UUID().uuidString
        guard let url = AppConfig.apiURL(path: "/api/verification/upload-doc") else {
            throw NSError(domain: "VerificationView", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"document.jpg\"\r\n")
        body.appendString("Content-Type: image/jpeg\r\n\r\n")
        body.append(imageData)
        body.appendString("\r\n--\(boundary)--\r\n")
        
        request.httpBody = body
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        return try decoder.decode(DocUploadResponse.self, from: data)
    }
    
    func submitRequest() async {
        isSubmitting = true
        error = nil
        
        do {
            struct SubmitBody: Encodable {
                let legalFirstName: String
                let legalLastName: String
                let country: String
                let category: String
                let docType: String
                let docFrontUrl: String?
                let docBackUrl: String?
                let selfieUrl: String?
                
                enum CodingKeys: String, CodingKey {
                    case legalFirstName = "legal_first_name"
                    case legalLastName = "legal_last_name"
                    case country
                    case category
                    case docType = "doc_type"
                    case docFrontUrl = "doc_front_url"
                    case docBackUrl = "doc_back_url"
                    case selfieUrl = "selfie_url"
                }
            }
            
            let _: [String: String] = try await NetworkService.shared.post(
                path: "/api/verification/request",
                body: SubmitBody(
                    legalFirstName: legalFirstName,
                    legalLastName: legalLastName,
                    country: country,
                    category: category,
                    docType: docType,
                    docFrontUrl: docFrontUrl,
                    docBackUrl: docBackUrl,
                    selfieUrl: selfieUrl
                )
            )
            
            await MainActor.run {
                showWizard = false
                submitSuccess = true
                Haptics.heavy()
            }
            
            await fetchStatus()
        } catch {
            await MainActor.run {
                self.error = "Failed to submit request. Please try again."
                isSubmitting = false
            }
        }
    }
    
    func formatDate(_ isoString: String) -> String {
        if let date = PerformanceConstants.iso8601.date(from: isoString)
                    ?? PerformanceConstants.iso8601Fractional.date(from: isoString) {
            let display = DateFormatter()
            display.dateStyle = .medium
            return display.string(from: date)
        }
        return isoString
    }
}

// Empty body for POST requests with no body
private struct EmptyBody: Encodable {}
