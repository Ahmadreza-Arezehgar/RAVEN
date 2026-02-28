import SwiftUI

/// Generates random anonymous names and avatars for audio room participants
struct AnonymousNameGenerator {
    
    // MARK: - Adjectives
    
    private static let adjectives = [
        "Happy", "Clever", "Swift", "Gentle", "Brave",
        "Calm", "Wise", "Lucky", "Curious", "Friendly",
        "Bright", "Cool", "Quiet", "Shy", "Bold",
        "Sleepy", "Fuzzy", "Fluffy", "Silly", "Sneaky",
        "Cozy", "Lazy", "Jolly", "Merry", "Perky",
        "Zippy", "Bouncy", "Giggly", "Sparkly", "Wobbly",
        "Chirpy", "Peppy", "Snappy", "Zesty", "Groovy"
    ]
    
    // MARK: - Animals
    
    private static let animals = [
        // Safari
        "Lion", "Tiger", "Elephant", "Giraffe", "Zebra",
        "Hippo", "Rhino", "Cheetah", "Leopard", "Gorilla",
        
        // Forest
        "Fox", "Wolf", "Bear", "Deer", "Owl",
        "Rabbit", "Squirrel", "Hedgehog", "Badger", "Raccoon",
        
        // Ocean
        "Dolphin", "Whale", "Shark", "Octopus", "Turtle",
        "Penguin", "Seal", "Otter", "Crab", "Starfish",
        
        // Birds
        "Eagle", "Falcon", "Parrot", "Flamingo", "Peacock",
        "Swan", "Hummingbird", "Toucan", "Puffin", "Pelican",
        
        // Pets
        "Cat", "Dog", "Hamster", "Guinea Pig", "Bunny",
        "Panda", "Koala", "Sloth", "Capybara", "Red Panda"
    ]
    
    // MARK: - Animal Emojis
    
    private static let animalEmojis: [String: String] = [
        // Safari
        "Lion": "🦁", "Tiger": "🐯", "Elephant": "🐘", "Giraffe": "🦒", "Zebra": "🦓",
        "Hippo": "🦛", "Rhino": "🦏", "Cheetah": "🐆", "Leopard": "🐆", "Gorilla": "🦍",
        
        // Forest
        "Fox": "🦊", "Wolf": "🐺", "Bear": "🐻", "Deer": "🦌", "Owl": "🦉",
        "Rabbit": "🐰", "Squirrel": "🐿️", "Hedgehog": "🦔", "Badger": "🦡", "Raccoon": "🦝",
        
        // Ocean
        "Dolphin": "🐬", "Whale": "🐋", "Shark": "🦈", "Octopus": "🐙", "Turtle": "🐢",
        "Penguin": "🐧", "Seal": "🦭", "Otter": "🦦", "Crab": "🦀", "Starfish": "⭐",
        
        // Birds
        "Eagle": "🦅", "Falcon": "🦅", "Parrot": "🦜", "Flamingo": "🦩", "Peacock": "🦚",
        "Swan": "🦢", "Hummingbird": "🐦", "Toucan": "🐦", "Puffin": "🐧", "Pelican": "🐦",
        
        // Pets
        "Cat": "🐱", "Dog": "🐶", "Hamster": "🐹", "Guinea Pig": "🐹", "Bunny": "🐰",
        "Panda": "🐼", "Koala": "🐨", "Sloth": "🦥", "Capybara": "🦫", "Red Panda": "🐾"
    ]
    
    // MARK: - Colors for avatar background
    
    private static let avatarColors: [Color] = [
        .red, .orange, .yellow, .green, .mint,
        .teal, .cyan, .blue, .indigo, .purple,
        .pink, .brown
    ]
    
    // MARK: - Generate Random Name
    
    /// Generate a random anonymous name like "Happy Fox" or "Clever Dolphin"
    static func generateName() -> String {
        let adjective = adjectives.randomElement() ?? "Anonymous"
        let animal = animals.randomElement() ?? "User"
        return "\(adjective) \(animal)"
    }
    
    /// Generate name and matching emoji
    static func generateNameWithEmoji() -> (name: String, emoji: String) {
        let adjective = adjectives.randomElement() ?? "Anonymous"
        let animal = animals.randomElement() ?? "User"
        let emoji = animalEmojis[animal] ?? "🎭"
        return (name: "\(adjective) \(animal)", emoji: emoji)
    }
    
    /// Generate a complete anonymous identity
    static func generateIdentity() -> AnonymousIdentity {
        let adjective = adjectives.randomElement() ?? "Anonymous"
        let animal = animals.randomElement() ?? "User"
        let emoji = animalEmojis[animal] ?? "🎭"
        let color = avatarColors.randomElement() ?? .blue
        
        return AnonymousIdentity(
            displayName: "\(adjective) \(animal)",
            emoji: emoji,
            backgroundColor: color
        )
    }
}

// MARK: - Anonymous Identity Model

struct AnonymousIdentity: Codable, Equatable {
    let displayName: String
    let emoji: String
    private let colorData: CodableColor
    
    var backgroundColor: Color { colorData.color }
    
    init(displayName: String, emoji: String, backgroundColor: Color) {
        self.displayName = displayName
        self.emoji = emoji
        self.colorData = CodableColor(color: backgroundColor)
    }
    
    // Codable helpers
    enum CodingKeys: String, CodingKey {
        case displayName, emoji, colorData
    }
}

// MARK: - Codable Color Helper

private struct CodableColor: Codable, Equatable {
    let hue: Double
    let saturation: Double
    let brightness: Double
    
    var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }
    
    init(color: Color) {
        // Default to blue if conversion fails
        var h: CGFloat = 0.6
        var s: CGFloat = 0.8
        var b: CGFloat = 0.9
        
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        
        self.hue = Double(h)
        self.saturation = Double(s)
        self.brightness = Double(b)
    }
}

// MARK: - Anonymous Avatar View

struct AnonymousAvatarView: View {
    let identity: AnonymousIdentity
    var size: CGFloat = 60
    
    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(identity.backgroundColor.gradient)
            
            // Emoji
            Text(identity.emoji)
                .font(.system(size: size * 0.5))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Preview

#Preview("Anonymous Names") {
    VStack(spacing: 20) {
        Text("Random Anonymous Names")
            .font(.headline)
        
        ForEach(0..<5, id: \.self) { _ in
            let identity = AnonymousNameGenerator.generateIdentity()
            
            HStack(spacing: 12) {
                AnonymousAvatarView(identity: identity, size: 50)
                
                Text(identity.displayName)
                    .font(.body)
            }
        }
    }
    .padding()
}
