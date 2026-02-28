// Feature Details Database for RAVEN Website
// This file contains in-depth content for feature modals

const featureDetails = {
    // ========================================
    // PRIVACY FEATURE
    // ========================================
    privacy: {
        title: "Military-Grade Privacy",
        icon: "🔒",
        tagline: "Your conversations belong to you—and only you",
        sections: [
            {
                type: "text",
                title: "End-to-End Encryption Explained",
                content: "Every single message you send in RAVEN is encrypted on your device before it even leaves your phone. Think of it like sealing each message in a vault that only you and your recipient have the key to unlock. Not even we can read your messages—that's a promise."
            },
            {
                type: "flowchart",
                title: "How Encryption Works (The Simple Version)",
                steps: [
                    {
                        number: 1,
                        title: "You Type",
                        desc: "Write your message like normal",
                        icon: "✍️",
                        highlight: false
                    },
                    {
                        number: 2,
                        title: "RAVEN Locks It",
                        desc: "Message is scrambled using military-grade encryption (AES-256)",
                        icon: "🔐",
                        highlight: true
                    },
                    {
                        number: 3,
                        title: "Sent Safely",
                        desc: "Encrypted message travels through WiFi or Bluetooth",
                        icon: "📡",
                        highlight: false
                    },
                    {
                        number: 4,
                        title: "Friend Unlocks It",
                        desc: "Only your friend's device can unlock and read it",
                        icon: "🔓",
                        highlight: true
                    }
                ]
            },
            {
                type: "text",
                content: "**What makes it 'military-grade'?** We use the same encryption technology (AES-256) that governments use to protect top-secret information. Even the most powerful supercomputers would need billions of years to crack it."
            },
            {
                type: "list",
                title: "Privacy Features That Protect You",
                items: [
                    "End-to-end encryption—not even RAVEN servers can read your messages",
                    "Secure key exchange using RSA (like banks use)",
                    "Message signing to prove messages are authentic",
                    "Keys stored in iOS Keychain (the same system that protects your credit cards)",
                    "No message data stored on our servers (we can't hand over what we don't have)"
                ]
            },
            {
                type: "stats",
                items: [
                    { label: "Encryption Standard", value: "AES-256-GCM" },
                    { label: "Key Strength", value: "256-bit" },
                    { label: "Time to Crack", value: "Billions of years" },
                    { label: "Data Stored by RAVEN", value: "Zero messages" }
                ]
            }
        ]
    },

    // ========================================
    // OFFLINE MESSAGING FEATURE
    // ========================================
    offline: {
        title: "Message Without Internet",
        icon: "📱",
        tagline: "Stay connected even when WiFi and cell service are down",
        sections: [
            {
                type: "text",
                title: "Bluetooth Mesh Networking",
                content: "Lost your internet connection? RAVEN keeps you connected. Your phone uses Bluetooth to talk to nearby RAVEN users, and they relay your message like a chain of messengers until it reaches your friend. It's like passing a note in class, but way faster and way smarter."
            },
            {
                type: "flowchart",
                title: "How Messages Travel Without Internet",
                subtitle: "A real example: Alice sends a message to Bob",
                steps: [
                    {
                        number: 1,
                        title: "Alice (Sender)",
                        desc: "Wants to message Bob but has no WiFi",
                        icon: "👩",
                        highlight: false
                    },
                    {
                        number: 2,
                        title: "Finds Carol Nearby",
                        desc: "Alice's phone finds Carol's phone via Bluetooth (50-100m range)",
                        icon: "📲",
                        highlight: true
                    },
                    {
                        number: 3,
                        title: "Carol Relays to Dave",
                        desc: "Carol's phone automatically forwards the message to Dave",
                        icon: "📲",
                        highlight: false
                    },
                    {
                        number: 4,
                        title: "Dave Delivers to Bob",
                        desc: "Dave's phone completes the delivery to Bob",
                        icon: "👨",
                        highlight: true
                    }
                ]
            },
            {
                type: "mesh-network",
                title: "The Bluetooth Mesh Network in Action",
                nodes: [
                    { name: "Alice", role: "sender", color: "#10b981" },
                    { name: "Carol", role: "relay", color: "#8b5cf6" },
                    { name: "Dave", role: "relay", color: "#8b5cf6" },
                    { name: "Bob", role: "receiver", color: "#3b82f6" }
                ],
                connections: [
                    { from: 0, to: 1, label: "Hop 1 BLE" },
                    { from: 1, to: 2, label: "Hop 2 BLE" },
                    { from: 2, to: 3, label: "Hop 3 BLE" }
                ],
                note: "✅ Message delivered without internet!"
            },
            {
                type: "text",
                content: "**Why is this amazing?** In disasters (earthquakes, hurricanes), crowded events (concerts, protests), or remote areas (hiking, camping), cell towers fail or are overloaded. RAVEN works as long as there are users nearby—no infrastructure needed."
            },
            {
                type: "list",
                title: "Real-World Use Cases",
                items: [
                    "🏔️ **Hiking & Camping**: Stay in touch with your group in the wilderness",
                    "🌊 **Natural Disasters**: Communicate when cell towers are down",
                    "🎪 **Crowded Events**: Message friends when networks are overloaded",
                    "✊ **Protests & Rallies**: Organize safely without relying on cellular networks",
                    "🚇 **Underground**: Message in subways and tunnels with no service"
                ]
            },
            {
                type: "stats",
                items: [
                    { label: "Bluetooth Range", value: "50-100m per hop" },
                    { label: "Max Hops", value: "Unlimited*" },
                    { label: "Routing Algorithm", value: "Spray-and-Wait" },
                    { label: "Internet Required", value: "Nope! 🎉" }
                ]
            }
        ]
    },

    // ========================================
    // GEMINI AI FEATURE
    // ========================================
    gemini: {
        title: "AI Assistant Built-In",
        icon: "✨",
        tagline: "Your smart sidekick powered by Google Gemini",
        sections: [
            {
                type: "text",
                title: "Your Built-In AI Helper",
                content: "Meet your new messaging buddy! RAVEN has Google's powerful Gemini AI built right in. It's like having a genius friend who can help you with anything—from translating languages to answering questions to making your messages sound better."
            },
            {
                type: "flowchart",
                title: "What Can Gemini Do For You?",
                steps: [
                    {
                        number: 1,
                        title: "Ask Anything",
                        desc: "'Explain quantum physics in simple terms'",
                        icon: "💬",
                        highlight: false
                    },
                    {
                        number: 2,
                        title: "Gemini Thinks",
                        desc: "AI processes your question using Google's most advanced model",
                        icon: "🧠",
                        highlight: true
                    },
                    {
                        number: 3,
                        title: "Get Smart Answers",
                        desc: "Clear, helpful responses in seconds",
                        icon: "💡",
                        highlight: true
                    },
                    {
                        number: 4,
                        title: "Chat Naturally",
                        desc: "Have a conversation—Gemini remembers context",
                        icon: "💬",
                        highlight: false
                    }
                ]
            },
            {
                type: "list",
                title: "Cool Things You Can Do",
                items: [
                    "🌍 **Translate Messages**: 'Translate this to Spanish for me'",
                    "✍️ **Improve Writing**: 'Make this message sound more professional'",
                    "🤔 **Get Answers**: 'What's the best gift for someone who loves hiking?'",
                    "📚 **Learn Anything**: 'Explain how encryption works like I'm 10'",
                    "🎯 **Plan Things**: 'Help me plan a surprise party'",
                    "😂 **Have Fun**: 'Tell me a funny joke about cats'"
                ]
            },
            {
                type: "text",
                content: "**Is it private?** Your chats with Gemini are processed by Google's AI, but your personal messages to friends stay encrypted end-to-end. Gemini only sees what you directly ask it—never your private conversations."
            },
            {
                type: "decision",
                title: "Use Cases",
                desc: "Gemini adapts to help you with anything",
                branches: [
                    {
                        condition: "Need Help Writing?",
                        outcome: "'Draft a professional apology email'",
                        color: "#10b981"
                    },
                    {
                        condition: "Language Barrier?",
                        outcome: "'Translate to Arabic' → Perfect translation",
                        color: "#3b82f6"
                    },
                    {
                        condition: "Just Curious?",
                        outcome: "'Why is the sky blue?' → Learn something new!",
                        color: "#f59e0b"
                    }
                ]
            },
            {
                type: "stats",
                items: [
                    { label: "AI Model", value: "Google Gemini" },
                    { label: "Languages", value: "100+" },
                    { label: "Response Time", value: "< 2 seconds" },
                    { label: "Cost", value: "Free with RAVEN" }
                ]
            }
        ]
    },

    // ========================================
    // SIMPLICITY FEATURE
    // ========================================
    simple: {
        title: "Simple & Beautiful",
        icon: "🎯",
        tagline: "Powerful features without the complexity",
        sections: [
            {
                type: "text",
                title: "Easy to Use, Powerful Features",
                content: "We believe amazing technology should be easy to use. RAVEN gives you military-grade security, AI assistance, and offline messaging—but you don't need a tech degree to use it. If you can text, you can use RAVEN."
            },
            {
                type: "flowchart",
                title: "The RAVEN Experience",
                steps: [
                    {
                        number: 1,
                        title: "Download & Open",
                        desc: "Install from App Store, open the app",
                        icon: "📲",
                        highlight: false
                    },
                    {
                        number: 2,
                        title: "Sign In (2 seconds)",
                        desc: "Use Apple ID or Google—no passwords to remember",
                        icon: "👆",
                        highlight: true
                    },
                    {
                        number: 3,
                        title: "Start Chatting",
                        desc: "That's it! Everything else happens automatically",
                        icon: "💬",
                        highlight: true
                    },
                    {
                        number: 4,
                        title: "Enjoy",
                        desc: "Encryption, offline mode, AI—all working behind the scenes",
                        icon: "✨",
                        highlight: false
                    }
                ]
            },
            {
                type: "list",
                title: "What Makes RAVEN Easy",
                items: [
                    "🎨 **Beautiful Design**: Clean, modern interface that feels natural",
                    "🔐 **Auto-Encryption**: Security happens automatically—no setup needed",
                    "📡 **Smart Switching**: App chooses WiFi or Bluetooth automatically",
                    "🌓 **Dark Mode**: Easy on the eyes, battery-friendly",
                    "🇬🇧🇪🇸🇮🇷 **Your Language**: English, Spanish, Persian, German, Chinese, and more",
                    "♿ **Accessible**: VoiceOver support, large text, high contrast"
                ]
            },
            {
                type: "text",
                content: "**No Complicated Settings**: Unlike other apps that overwhelm you with 50 settings, RAVEN works perfectly out of the box. Advanced users can tweak things, but 99% of users never need to."
            },
            {
                type: "decision",
                title: "Designed For Everyone",
                desc: "Whether you're 15 or 75, tech-savvy or not",
                branches: [
                    {
                        condition: "First Time User?",
                        outcome: "Welcome tutorial shows you the basics in 30 seconds",
                        color: "#10b981"
                    },
                    {
                        condition: "Power User?",
                        outcome: "Advanced features hidden in settings when you're ready",
                        color: "#8b5cf6"
                    },
                    {
                        condition: "Accessibility Needs?",
                        outcome: "Full VoiceOver, Dynamic Type, and color contrast support",
                        color: "#3b82f6"
                    }
                ]
            },
            {
                type: "stats",
                items: [
                    { label: "Setup Time", value: "< 1 minute" },
                    { label: "Required Training", value: "Zero" },
                    { label: "Main Menu Items", value: "4 (not 40!)" },
                    { label: "User Satisfaction", value: "⭐⭐⭐⭐⭐" }
                ]
            }
        ]
    }
};

// Note: Removed old features (dual-transport, social, news, backup, language, oauth, sync)
// Only keeping: privacy, offline, gemini, simple
