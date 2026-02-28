# RAIVEN Web App 🌐

Progressive Web App (PWA) version of RAIVEN with **Web Bluetooth mesh networking** support for offline communication.

---

## ✨ Features

- 🔵 **Web Bluetooth Mesh Networking** - Participate in offline mesh network
- 💬 **Cloud Messaging** - Real-time chat via backend API  
- 📱 **Progressive Web App** - Installable and works offline
- 🔒 **End-to-End Encryption** - Secure messaging with Web Crypto API
- ⚡ **Modern UI** - Glassmorphism design matching mobile app
- 🌍 **Cross-Platform** - Works on Chrome/Edge (desktop & Android)

---

## 🚀 Quick Start

### Prerequisites

You need **Node.js** and **npm** installed:
- Download from: https://nodejs.org/
- Verify: `node --version` and `npm --version`

### Installation

```bash
cd hybrid_messenger/hybrid-messenger-web
npm install
```

### Development Server

```bash
npm run dev
```

Opens at: **http://localhost:3000**

### Build for Production

```bash
npm run build
npm run preview
```

---

## 📁 Project Structure

```
hybrid-messenger-web/
├── src/
│   ├── pages/              # Page components
│   │   ├── LoginPage.jsx
│   │   ├── SignUpPage.jsx
│   │   └── PlaceholderPages.jsx
│   ├── services/           # Core services
│   │   ├── authService.js      # Authentication
│   │   └── bluetoothService.js # Web Bluetooth mesh
│   ├── components/         # Reusable components (future)
│   ├── hooks/              # Custom React hooks (future)
│   ├── utils/              # Utility functions (future)
│   ├── App.jsx             # Main app component
│   ├── main.jsx            # Entry point
│   └── index.css           # Global styles
├── public/                 # Static assets
├── index.html              # HTML template
├── vite.config.js          # Vite configuration + PWA
└── package.json            # Dependencies
```

---

## 🔵 Web Bluetooth Mesh Networking

### How It Works

1. **Device Discovery**: Scan for nearby Bluetooth devices
2. **GATT Connection**: Connect to devices using BLE GATT protocol
3. **Message Exchange**: Send/receive encrypted messages
4. **Multi-Hop Relay**: Messages hop through devices to reach destination
5. **Spray-and-Wait**: Routing algorithm for optimal delivery

### Usage Example

```javascript
import { bluetoothService } from './services/bluetoothService';

// Check if supported
if (bluetoothService.isSupported()) {
  // Request device and connect
  const device = await bluetoothService.requestDevice();
  await bluetoothService.connect(device);
  
  // Send message
  await bluetoothService.sendMessage({
    senderId: 'user-123',
    recipientId: 'user-456',
    content: 'encrypted-content',
    messageType: 'direct'
  });
  
  // Listen for messages
  bluetoothService.onMessage((message) => {
    console.log('Received:', message);
  });
}
```

### Browser Compatibility

| Browser | Support | Notes |
|---------|---------|-------|
| Chrome (Desktop) | ✅ Full | Recommended |
| Chrome (Android) | ✅ Full | Recommended |
| Edge (Desktop) | ✅ Full | Works great |
| Edge (Android) | ✅ Full | Works great |
| Firefox | ⚠️ Experimental | Flag required |
| Safari (macOS) | ⚠️ Limited | Partial support |
| Safari (iOS) | ❌ No | Use native app |

**Recommendation:** Use Chrome or Edge for full functionality.

---

## 🔐 Security

### End-to-End Encryption

All messages are encrypted using **Web Crypto API**:
- **AES-256-GCM** for message content
- **HMAC-SHA256** for mesh authentication
- **RSA-2048** for key exchange

### Local Storage

- **JWT tokens** stored in `localStorage`
- **User data** cached in `IndexedDB`
- **Private keys** managed by Web Crypto API

---

## 📡 API Integration

The web app connects to the same FastAPI backend as the mobile app:

**Backend URL:** `https://hybrid-messenger-api-516053629173.us-central1.run.app`

### Endpoints Used

- `POST /api/auth/signup` - Create account
- `POST /api/auth/login` - Login
- `GET /api/auth/me` - Validate token
- `POST /api/messages` - Send message (Phase 2)
- `GET /api/posts/feed` - Get posts (Phase 4)
- `POST /api/posts/create` - Create post (Phase 4)

---

## 🎨 Design System

Matches mobile app design:

### Colors

```css
--color-primary: #6366f1        /* Purple */
--color-secondary: #10b981      /* Green */
--color-accent-pink: #f093fb    /* Pink */
--color-bg: #0a0a0f            /* Dark background */
--color-surface: #1a1a24       /* Card background */
```

### Glassmorphism

All cards use frosted glass effect:
```css
background: rgba(255, 255, 255, 0.05);
backdrop-filter: blur(10px);
border: 1px solid rgba(255, 255, 255, 0.1);
```

---

## 🧪 Testing Web Bluetooth

### Test with Mobile App

1. **Start web app**: `npm run dev`
2. **Open in Chrome**: http://localhost:3000
3. **Login** to web app
4. **Open mobile app** on another device
5. **Click "Connect Bluetooth"** in web app
6. **Select mobile device** from list
7. **Send test message** via mesh
8. **Verify** message received on mobile

### Browser Console Testing

```javascript
// Open console (F12)
const { bluetoothService } = await import('./src/services/bluetoothService.js');

// Check support
console.log('Supported:', bluetoothService.isSupported());

// Request device
const device = await bluetoothService.requestDevice();
await bluetoothService.connect(device);

// Check connection
console.log('Connected:', bluetoothService.isConnected());
```

---

## 📦 Deployment

### Option 1: Vercel (Recommended)

```bash
npm install -g vercel
vercel --prod
```

### Option 2: Netlify

1. Drag `dist` folder to [app.netlify.com](https://app.netlify.com)
2. Done!

### Option 3: GitHub Pages

```bash
# Add to package.json
"homepage": "https://yourusername.github.io/hybrid-messenger-web"

# Build
npm run build

# Deploy
npx gh-pages -d dist
```

### Important: HTTPS Required

Web Bluetooth **only works over HTTPS** (except localhost). Make sure your deployment uses HTTPS.

---

## 🛠️ Development Phases

### ✅ Phase 1: Foundation (Complete)
- [x] React + Vite setup
- [x] PWA configuration
- [x] Authentication (login/signup)
- [x] Web Bluetooth service
- [x] Basic routing

### ✅ Phase 2: Core Messaging (Complete)
- [x] Chat interface
- [x] Message sending/receiving
- [x] E2EE implementation (AES-256-GCM)
- [x] IndexedDB storage
- [x] Conversations management

### 📅 Phase 3: Bluetooth Mesh (Next)
- [ ] Device discovery UI
- [ ] Mesh message routing
- [ ] Relay visualization
- [ ] Outbox management

### 📅 Phase 4: Social Features
- [ ] Home feed
- [ ] Post creation
- [ ] Like/repost/comment
- [ ] Friend management

### 📅 Phase 5: Polish
- [ ] Settings page
- [ ] Notifications
- [ ] Performance optimization
- [ ] Testing & bug fixes

---

## 🐛 Troubleshooting

### "Navigator.bluetooth is undefined"

**Problem:** Browser doesn't support Web Bluetooth

**Solution:** Use Chrome or Edge browser

### "HTTPS required"

**Problem:** Web Bluetooth requires secure context

**Solution:** 
- Use `localhost` for development
- Deploy to HTTPS in production

### "Permission denied"

**Problem:** User didn't grant Bluetooth permission

**Solution:** Click "Allow" when prompted, or reset site permissions in browser settings

### npm install fails

**Problem:** Node.js or npm not installed

**Solution:** 
```bash
# Install Node.js from https://nodejs.org
# Then retry
npm install
```

---

## 📝 Environment Variables

Create `.env` file:

```bash
VITE_API_URL=https://hybrid-messenger-api-516053629173.us-central1.run.app
VITE_WS_URL=wss://hybrid-messenger-api-516053629173.us-central1.run.app/ws
```

---

## 🤝 Contributing

This is Phase 1 of development. Future phases will add:
- Complete messaging system
- Full Bluetooth mesh integration
- Social features (posts, friends)
- Settings and customization
- Multi-language support

---

## 📱 Mobile App Integration

The web app is designed to work seamlessly with the iOS mobile app:

- **Same backend API**
- **Compatible Bluetooth mesh protocol**
- **Identical message encryption**
- **Shared user database**

Messages sent from web can be received on mobile and vice versa!

---

## 🔗 Links

- **Marketing Site:** `/hybrid_messenger_website/`
- **Backend API:** `https://hybrid-messenger-api-516053629173.us-central1.run.app`
- **Mobile App:** `/lib/` (Flutter)

---

## 📄 License

© 2026 RAIVEN. All rights reserved.

---

## 🆘 Support

For questions or issues:
- Email: support@hybridmessenger.com
- Create an issue in the repository

---

**Made with ⚡ by RAVEN Team**

**Phase 1: Foundation - COMPLETE ✅**
