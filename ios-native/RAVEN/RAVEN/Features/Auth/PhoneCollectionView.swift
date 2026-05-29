import SwiftUI

// MARK: - Phone Collection View (Liquid Glass Style)
// Shown after OAuth login if user hasn't provided phone number

struct PhoneCollectionView: View {
    @State private var phoneNumber = ""
    @State private var countryCode = "+1"
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCountryPicker = false
    
    var onComplete: () -> Void
    var onSkip: (() -> Void)?
    
    // All world countries with dialing codes
    private let countryCodes = [
        ("+93", "🇦🇫", "Afghanistan"),
        ("+355", "🇦🇱", "Albania"),
        ("+213", "🇩🇿", "Algeria"),
        ("+376", "🇦🇩", "Andorra"),
        ("+244", "🇦🇴", "Angola"),
        ("+1 268", "🇦🇬", "Antigua and Barbuda"),
        ("+54", "🇦🇷", "Argentina"),
        ("+374", "🇦🇲", "Armenia"),
        ("+61", "🇦🇺", "Australia"),
        ("+43", "🇦🇹", "Austria"),
        ("+994", "🇦🇿", "Azerbaijan"),
        ("+1 242", "🇧🇸", "Bahamas"),
        ("+973", "🇧🇭", "Bahrain"),
        ("+880", "🇧🇩", "Bangladesh"),
        ("+1 246", "🇧🇧", "Barbados"),
        ("+375", "🇧🇾", "Belarus"),
        ("+32", "🇧🇪", "Belgium"),
        ("+501", "🇧🇿", "Belize"),
        ("+229", "🇧🇯", "Benin"),
        ("+975", "🇧🇹", "Bhutan"),
        ("+591", "🇧🇴", "Bolivia"),
        ("+387", "🇧🇦", "Bosnia and Herzegovina"),
        ("+267", "🇧🇼", "Botswana"),
        ("+55", "🇧🇷", "Brazil"),
        ("+673", "🇧🇳", "Brunei"),
        ("+359", "🇧🇬", "Bulgaria"),
        ("+226", "🇧🇫", "Burkina Faso"),
        ("+257", "🇧🇮", "Burundi"),
        ("+855", "🇰🇭", "Cambodia"),
        ("+237", "🇨🇲", "Cameroon"),
        ("+1", "🇨🇦", "Canada"),
        ("+238", "🇨🇻", "Cape Verde"),
        ("+236", "🇨🇫", "Central African Republic"),
        ("+235", "🇹🇩", "Chad"),
        ("+56", "🇨🇱", "Chile"),
        ("+86", "🇨🇳", "China"),
        ("+57", "🇨🇴", "Colombia"),
        ("+269", "🇰🇲", "Comoros"),
        ("+243", "🇨🇩", "Congo (DRC)"),
        ("+242", "🇨🇬", "Congo (Republic)"),
        ("+506", "🇨🇷", "Costa Rica"),
        ("+225", "🇨🇮", "Côte d'Ivoire"),
        ("+385", "🇭🇷", "Croatia"),
        ("+53", "🇨🇺", "Cuba"),
        ("+357", "🇨🇾", "Cyprus"),
        ("+420", "🇨🇿", "Czech Republic"),
        ("+45", "🇩🇰", "Denmark"),
        ("+253", "🇩🇯", "Djibouti"),
        ("+1 767", "🇩🇲", "Dominica"),
        ("+1 809", "🇩🇴", "Dominican Republic"),
        ("+593", "🇪🇨", "Ecuador"),
        ("+20", "🇪🇬", "Egypt"),
        ("+503", "🇸🇻", "El Salvador"),
        ("+240", "🇬🇶", "Equatorial Guinea"),
        ("+291", "🇪🇷", "Eritrea"),
        ("+372", "🇪🇪", "Estonia"),
        ("+268", "🇸🇿", "Eswatini"),
        ("+251", "🇪🇹", "Ethiopia"),
        ("+679", "🇫🇯", "Fiji"),
        ("+358", "🇫🇮", "Finland"),
        ("+33", "🇫🇷", "France"),
        ("+241", "🇬🇦", "Gabon"),
        ("+220", "🇬🇲", "Gambia"),
        ("+995", "🇬🇪", "Georgia"),
        ("+49", "🇩🇪", "Germany"),
        ("+233", "🇬🇭", "Ghana"),
        ("+30", "🇬🇷", "Greece"),
        ("+1 473", "🇬🇩", "Grenada"),
        ("+502", "🇬🇹", "Guatemala"),
        ("+224", "🇬🇳", "Guinea"),
        ("+245", "🇬🇼", "Guinea-Bissau"),
        ("+592", "🇬🇾", "Guyana"),
        ("+509", "🇭🇹", "Haiti"),
        ("+504", "🇭🇳", "Honduras"),
        ("+852", "🇭🇰", "Hong Kong"),
        ("+36", "🇭🇺", "Hungary"),
        ("+354", "🇮🇸", "Iceland"),
        ("+91", "🇮🇳", "India"),
        ("+62", "🇮🇩", "Indonesia"),
        ("+98", "🇮🇷", "Iran"),
        ("+964", "🇮🇶", "Iraq"),
        ("+353", "🇮🇪", "Ireland"),
        ("+39", "🇮🇹", "Italy"),
        ("+1 876", "🇯🇲", "Jamaica"),
        ("+81", "🇯🇵", "Japan"),
        ("+962", "🇯🇴", "Jordan"),
        ("+7", "🇰🇿", "Kazakhstan"),
        ("+254", "🇰🇪", "Kenya"),
        ("+686", "🇰🇮", "Kiribati"),
        ("+383", "🇽🇰", "Kosovo"),
        ("+965", "🇰🇼", "Kuwait"),
        ("+996", "🇰🇬", "Kyrgyzstan"),
        ("+856", "🇱🇦", "Laos"),
        ("+371", "🇱🇻", "Latvia"),
        ("+961", "🇱🇧", "Lebanon"),
        ("+266", "🇱🇸", "Lesotho"),
        ("+231", "🇱🇷", "Liberia"),
        ("+218", "🇱🇾", "Libya"),
        ("+423", "🇱🇮", "Liechtenstein"),
        ("+370", "🇱🇹", "Lithuania"),
        ("+352", "🇱🇺", "Luxembourg"),
        ("+853", "🇲🇴", "Macau"),
        ("+261", "🇲🇬", "Madagascar"),
        ("+265", "🇲🇼", "Malawi"),
        ("+60", "🇲🇾", "Malaysia"),
        ("+960", "🇲🇻", "Maldives"),
        ("+223", "🇲🇱", "Mali"),
        ("+356", "🇲🇹", "Malta"),
        ("+692", "🇲🇭", "Marshall Islands"),
        ("+222", "🇲🇷", "Mauritania"),
        ("+230", "🇲🇺", "Mauritius"),
        ("+52", "🇲🇽", "Mexico"),
        ("+691", "🇫🇲", "Micronesia"),
        ("+373", "🇲🇩", "Moldova"),
        ("+377", "🇲🇨", "Monaco"),
        ("+976", "🇲🇳", "Mongolia"),
        ("+382", "🇲🇪", "Montenegro"),
        ("+212", "🇲🇦", "Morocco"),
        ("+258", "🇲🇿", "Mozambique"),
        ("+95", "🇲🇲", "Myanmar"),
        ("+264", "🇳🇦", "Namibia"),
        ("+674", "🇳🇷", "Nauru"),
        ("+977", "🇳🇵", "Nepal"),
        ("+31", "🇳🇱", "Netherlands"),
        ("+64", "🇳🇿", "New Zealand"),
        ("+505", "🇳🇮", "Nicaragua"),
        ("+227", "🇳🇪", "Niger"),
        ("+234", "🇳🇬", "Nigeria"),
        ("+850", "🇰🇵", "North Korea"),
        ("+389", "🇲🇰", "North Macedonia"),
        ("+47", "🇳🇴", "Norway"),
        ("+968", "🇴🇲", "Oman"),
        ("+92", "🇵🇰", "Pakistan"),
        ("+680", "🇵🇼", "Palau"),
        ("+970", "🇵🇸", "Palestine"),
        ("+507", "🇵🇦", "Panama"),
        ("+675", "🇵🇬", "Papua New Guinea"),
        ("+595", "🇵🇾", "Paraguay"),
        ("+51", "🇵🇪", "Peru"),
        ("+63", "🇵🇭", "Philippines"),
        ("+48", "🇵🇱", "Poland"),
        ("+351", "🇵🇹", "Portugal"),
        ("+1 787", "🇵🇷", "Puerto Rico"),
        ("+974", "🇶🇦", "Qatar"),
        ("+40", "🇷🇴", "Romania"),
        ("+7", "🇷🇺", "Russia"),
        ("+250", "🇷🇼", "Rwanda"),
        ("+1 869", "🇰🇳", "Saint Kitts and Nevis"),
        ("+1 758", "🇱🇨", "Saint Lucia"),
        ("+1 784", "🇻🇨", "Saint Vincent and the Grenadines"),
        ("+685", "🇼🇸", "Samoa"),
        ("+378", "🇸🇲", "San Marino"),
        ("+239", "🇸🇹", "São Tomé and Príncipe"),
        ("+966", "🇸🇦", "Saudi Arabia"),
        ("+221", "🇸🇳", "Senegal"),
        ("+381", "🇷🇸", "Serbia"),
        ("+248", "🇸🇨", "Seychelles"),
        ("+232", "🇸🇱", "Sierra Leone"),
        ("+65", "🇸🇬", "Singapore"),
        ("+421", "🇸🇰", "Slovakia"),
        ("+386", "🇸🇮", "Slovenia"),
        ("+677", "🇸🇧", "Solomon Islands"),
        ("+252", "🇸🇴", "Somalia"),
        ("+27", "🇿🇦", "South Africa"),
        ("+82", "🇰🇷", "South Korea"),
        ("+211", "🇸🇸", "South Sudan"),
        ("+34", "🇪🇸", "Spain"),
        ("+94", "🇱🇰", "Sri Lanka"),
        ("+249", "🇸🇩", "Sudan"),
        ("+597", "🇸🇷", "Suriname"),
        ("+46", "🇸🇪", "Sweden"),
        ("+41", "🇨🇭", "Switzerland"),
        ("+963", "🇸🇾", "Syria"),
        ("+886", "🇹🇼", "Taiwan"),
        ("+992", "🇹🇯", "Tajikistan"),
        ("+255", "🇹🇿", "Tanzania"),
        ("+66", "🇹🇭", "Thailand"),
        ("+670", "🇹🇱", "Timor-Leste"),
        ("+228", "🇹🇬", "Togo"),
        ("+676", "🇹🇴", "Tonga"),
        ("+1 868", "🇹🇹", "Trinidad and Tobago"),
        ("+216", "🇹🇳", "Tunisia"),
        ("+90", "🇹🇷", "Turkey"),
        ("+993", "🇹🇲", "Turkmenistan"),
        ("+688", "🇹🇻", "Tuvalu"),
        ("+256", "🇺🇬", "Uganda"),
        ("+380", "🇺🇦", "Ukraine"),
        ("+971", "🇦🇪", "United Arab Emirates"),
        ("+44", "🇬🇧", "United Kingdom"),
        ("+1", "🇺🇸", "United States"),
        ("+598", "🇺🇾", "Uruguay"),
        ("+998", "🇺🇿", "Uzbekistan"),
        ("+678", "🇻🇺", "Vanuatu"),
        ("+39", "🇻🇦", "Vatican City"),
        ("+58", "🇻🇪", "Venezuela"),
        ("+84", "🇻🇳", "Vietnam"),
        ("+967", "🇾🇪", "Yemen"),
        ("+260", "🇿🇲", "Zambia"),
        ("+263", "🇿🇼", "Zimbabwe"),
    ]
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.1),
                    Color.purple.opacity(0.05),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .onTapGesture { hideKeyboard() }
            
            VStack(spacing: 24) {
                Spacer()
                
                // MARK: - Icon
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: "phone.circle.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                
                // MARK: - Title
                VStack(spacing: 8) {
                    Text("Add Your Phone")
                        .font(.title2.bold())
                    
                    Text("Help friends find you on Raven")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                // MARK: - Phone Input (Capsule Glass)
                HStack(spacing: 12) {
                    // Country Code Picker
                    Button {
                        showCountryPicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(currentFlag)
                                .font(.title2)
                            Text(countryCode)
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    
                    // Phone Number Field
                    TextField("Phone number", text: $phoneNumber)
                        .keyboardType(.phonePad)
                        .font(.body.monospacedDigit())
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 24)
                
                // MARK: - Privacy Note
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                    Text("Your number is encrypted and never shared")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial.opacity(0.5))
                .clipShape(Capsule())
                
                // MARK: - Error Message
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
                
                Spacer()
                
                // MARK: - Buttons
                VStack(spacing: 12) {
                    // Continue Button
                    Button {
                        Task { await savePhoneNumber() }
                    } label: {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Continue")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: isValidPhone ? [.blue, .purple] : [.gray],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    .disabled(!isValidPhone || isLoading)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showCountryPicker) {
            CountryCodePicker(
                countryCodes: countryCodes,
                selectedCode: $countryCode,
                isPresented: $showCountryPicker
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
    
    // MARK: - Helpers
    
    private var currentFlag: String {
        countryCodes.first { $0.0 == countryCode }?.1 ?? "🌍"
    }
    
    private var isValidPhone: Bool {
        // Basic validation: at least 7 digits
        let digits = phoneNumber.filter { $0.isNumber }
        return digits.count >= 7
    }
    
    private var fullPhoneNumber: String {
        let digits = phoneNumber.filter { $0.isNumber }
        let cleanDigits = digits.hasPrefix("0") ? String(digits.dropFirst()) : digits
        return "\(countryCode)\(cleanDigits)"
    }
    
    private func savePhoneNumber() async {
        isLoading = true
        errorMessage = nil
        
        do {
            // Save to server
            try await updateUserPhone(fullPhoneNumber)
            
            await MainActor.run {
                isLoading = false
                onComplete()
            }
        } catch {
            await MainActor.run {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func updateUserPhone(_ phone: String) async throws {
        struct UpdateRequest: Encodable {
            let phone: String
        }
        
        struct EmptyUpdateResponse: Decodable {}
        
        let _: EmptyUpdateResponse = try await NetworkService.shared.patch(
            path: "/api/users/me",
            body: UpdateRequest(phone: phone)
        )
    }
}

// MARK: - Country Code Picker
struct CountryCodePicker: View {
    let countryCodes: [(String, String, String)]
    @Binding var selectedCode: String
    @Binding var isPresented: Bool
    
    @State private var searchText = ""
    
    private var filteredCodes: [(Int, String, String, String)] {
        let indexed = countryCodes.enumerated().map { ($0.offset, $0.element.0, $0.element.1, $0.element.2) }
        if searchText.isEmpty { return indexed }
        return indexed.filter { (_, code, _, name) in
            name.localizedCaseInsensitiveContains(searchText) ||
            code.contains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            List(filteredCodes, id: \.0) { (index, code, flag, name) in
                Button {
                    selectedCode = code
                    isPresented = false
                } label: {
                    HStack {
                        Text(flag)
                            .font(.title2)
                        Text(name)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(code)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                        
                        if code == selectedCode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search country or code")
            .navigationTitle("Select Country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

// MARK: - Preview
#Preview {
    PhoneCollectionView(
        onComplete: { print("Complete") },
        onSkip: { print("Skip") }
    )
}
