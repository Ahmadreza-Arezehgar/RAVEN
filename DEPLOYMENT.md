# Deploying & Testing on Physical iOS Devices

To test the **RAIVEN** mesh capabilities, you need at least **two physical iOS devices**.

## 1. Prerequisites
- **Xcode** installed on your Mac.
- **Apple ID** (Free or Paid Developer Program).
- **Two iOS Devices** (iPhone or iPad).

## 2. Configure Signing
1. Open the project in Xcode:
   ```bash
   open ios/Runner.xcworkspace
   ```
2. In the **Project Navigator** (left sidebar), select the root **Runner** project.
3. Select the **Runner target**.
4. Go to the **Signing & Capabilities** tab.
5. Under **Team**, select your Apple ID/Team.
   - *If you don't see one, click "Add an Account" and log in.*
6. Ensure **Bundle Identifier** is unique (e.g., `com.yourname.hybridMessenger`).

## 3. Deployment
1. Connect your **first device** via USB.
2. Select it in the Xcode device selector (top bar).
3. Press **Run** (Play button) or `Cmd+R`.
   - *If using a free Apple ID, you may need to go to **Settings > General > VPN & Device Management** on the iPhone and "Trust" your certificate.*
4. Repeat for the **second device**.

## 4. Testing Scenarios

### Scenario A: Full Mesh (No Internet)
1. **Disable Wi-Fi and Cellular Data** on both phones.
   - *Ensure Bluetooth is ON and "Local Network" permission is granted.*
2. Launch the app on both devices.
3. Go to the **Nearby** tab.
4. You should see the other device appear (e.g., "iPhone (2)").
5. Select the device to start a chat.
6. Send a message.
   - It should route via Bluetooth/Multipeer.

### Scenario B: 3-Message Limit & Friend Request
1. Start a fresh chat with a new peer.
2. Send **3 messages**.
3. Try to send a 4th message.
   - App should block and show "Limit Reached".
4. Click **"Add Friend"**.
5. On the other device, look for the **"Friend Request"** card in the chat.
6. Tap **"Accept"**.
7. Continue chatting unlimitedly.

### Scenario C: Internet Relay
1. **Device A**: Turn OFF Internet (Airplane mode + Bluetooth ON).
2. **Device B**: Turn ON Internet (Wi-Fi/4G) + Bluetooth ON.
3. **Device A** sends a message to **Device B**.
4. **Device B** receives it via Mesh.
5. **Device B** (the Router) will log: `🌐 [Router] Internet available`.
   - *Note: In this demo, we mock the actual Cloud API, but the logs will confirm the relay attempt.*
