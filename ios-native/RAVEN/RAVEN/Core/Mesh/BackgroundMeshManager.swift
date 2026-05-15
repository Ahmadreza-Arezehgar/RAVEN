//
//  BackgroundMeshManager.swift
//  RAVEN
//
//  Manages background execution for BLE mesh networking.
//  Uses legal iOS background modes to keep the mesh alive:
//  - BLE Central/Peripheral restoration
//  - Significant location changes (low power wake trigger)
//  - Background app refresh tasks
//

import Foundation
import CoreLocation
import CoreBluetooth
#if !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif
import UIKit
import Combine

// MARK: - Background Wake Reason

enum BackgroundWakeReason: String {
    case none = "none"
    case bleCentralRestore = "ble_central_restore"
    case blePeripheralRestore = "ble_peripheral_restore"
    case bleDeviceConnected = "ble_device_connected"
    case bleDeviceDiscovered = "ble_device_discovered"
    case locationChange = "location_change"
    case beaconRegionEnter = "beacon_region_enter"
    case beaconRegionExit = "beacon_region_exit"
    case backgroundRefresh = "background_refresh"
    case backgroundProcessing = "background_processing"
    case launchBLECentral = "launch_ble_central"
    case launchBLEPeripheral = "launch_ble_peripheral"
    case launchLocation = "launch_location"
    case userInitiated = "user_initiated"
}

// MARK: - Background Mesh Manager

final class BackgroundMeshManager: NSObject, ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = BackgroundMeshManager()
    
    // MARK: - Published State
    
    @Published private(set) var isBackgroundEnabled = false
    @Published private(set) var lastWakeReason: BackgroundWakeReason = .none
    @Published private(set) var lastWakeTime: Date?
    @Published private(set) var totalBackgroundWakes: Int = 0
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    
    // MARK: - Managers
    
    private var locationManager: CLLocationManager?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Constants
    
    private static let refreshTaskIdentifier = "com.raven.mesh.refresh"
    private static let processingTaskIdentifier = "com.raven.mesh.processing"
    private static let beaconRegionIdentifier = "com.raven.mesh.beacon.region"
    
    // Use same UUID as BLE service for beacon region
    private static let meshServiceUUID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    
    // MARK: - Background Task Tracking
    
    private var activeBackgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]
    private let taskLock = NSLock()
    
    // MARK: - Init
    
    private override init() {
        super.init()
    }
    
    // MARK: - Setup
    
    /// Call this in AppDelegate didFinishLaunchingWithOptions
    func setup() {
        setupLocationManager()
        registerBackgroundTasks()
        loadStatistics()
        
        // If user already granted "Always", enable anchors immediately on boot.
        if locationAuthorizationStatus == .authorizedAlways {
            startBackgroundLocationAnchor()
        }
        
        #if DEBUG
        print("📡 [BackgroundMesh] Manager initialized")
        print("📡 [BackgroundMesh] Refresh task ID: \(Self.refreshTaskIdentifier)")
        print("📡 [BackgroundMesh] Processing task ID: \(Self.processingTaskIdentifier)")
        #endif
    }
    
    /// Check launch options and handle background launch
    func handleLaunchOptions(_ launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        if let centralUUIDs = launchOptions?[.bluetoothCentrals] as? [String], !centralUUIDs.isEmpty {
            #if DEBUG
            print("🚀 [BackgroundMesh] Launched for BLE Central restoration: \(centralUUIDs)")
            #endif
            recordWake(reason: .launchBLECentral)
            beginBackgroundTask(identifier: "launch_central", reason: .launchBLECentral)
            autoEndBackgroundTask(identifier: "launch_central", after: 25)
        }
        
        if let peripheralUUIDs = launchOptions?[.bluetoothPeripherals] as? [String], !peripheralUUIDs.isEmpty {
            #if DEBUG
            print("🚀 [BackgroundMesh] Launched for BLE Peripheral restoration: \(peripheralUUIDs)")
            #endif
            recordWake(reason: .launchBLEPeripheral)
            beginBackgroundTask(identifier: "launch_peripheral", reason: .launchBLEPeripheral)
            autoEndBackgroundTask(identifier: "launch_peripheral", after: 25)
        }
        
        if launchOptions?[.location] != nil {
            #if DEBUG
            print("🚀 [BackgroundMesh] Launched for location event")
            #endif
            recordWake(reason: .launchLocation)
            beginBackgroundTask(identifier: "launch_location", reason: .launchLocation)
            autoEndBackgroundTask(identifier: "launch_location", after: 25)
        }
    }

    
    // MARK: - Location Manager Setup
    
    private func setupLocationManager() {
        locationManager = CLLocationManager()
        locationManager?.delegate = self
        
        // Background location settings
        locationManager?.allowsBackgroundLocationUpdates = true
        locationManager?.pausesLocationUpdatesAutomatically = false
        
        // Low power settings - we only need location for wake triggers
        locationManager?.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager?.distanceFilter = 500 // meters
        
        // Get current authorization status
        locationAuthorizationStatus = locationManager?.authorizationStatus ?? .notDetermined
        
        #if DEBUG
        print("📍 [BackgroundMesh] Location manager configured")
        #endif
    }
    
    /// Request location permission - call from UI when user enables background mode
    func requestLocationPermission() {
        #if DEBUG
        print("📍 [BackgroundMesh] Requesting location permission...")
        #endif
        locationManager?.requestAlwaysAuthorization()
    }
    
    /// Start background location anchor - call after permission granted
    func startBackgroundLocationAnchor() {
        guard let locationManager = locationManager else {
            #if DEBUG
            print("❌ [BackgroundMesh] Location manager not initialized")
            #endif
            return
        }
        
        guard locationManager.authorizationStatus == .authorizedAlways else {
            #if DEBUG
            print("⚠️ [BackgroundMesh] Location not authorized for 'Always' - background will be limited")
            #endif
            return
        }
        
        // Start significant location changes (very low power)
        locationManager.startMonitoringSignificantLocationChanges()
        #if DEBUG
        print("📍 [BackgroundMesh] Started significant location monitoring")
        #endif
        
        // Start beacon region monitoring for RAVEN devices
        startBeaconRegionMonitoring()
        
        isBackgroundEnabled = true
        saveStatistics()
        
        #if DEBUG
        print("✅ [BackgroundMesh] Background location anchor started")
        #endif
    }
    
    /// Stop background location
    func stopBackgroundLocationAnchor() {
        locationManager?.stopMonitoringSignificantLocationChanges()
        stopBeaconRegionMonitoring()
        
        isBackgroundEnabled = false
        saveStatistics()
        
        #if DEBUG
        print("🛑 [BackgroundMesh] Background location anchor stopped")
        #endif
    }
    
    // MARK: - Beacon Region Monitoring

    #if targetEnvironment(macCatalyst)
    // CLBeaconRegion / iBeacon monitoring is not supported on Mac Catalyst.
    private func startBeaconRegionMonitoring() {}
    private func stopBeaconRegionMonitoring() {}
    #else
    private func startBeaconRegionMonitoring() {
        guard let locationManager = locationManager else { return }

        // Create beacon region with our mesh service UUID
        let beaconConstraint = CLBeaconIdentityConstraint(uuid: Self.meshServiceUUID)
        let beaconRegion = CLBeaconRegion(
            beaconIdentityConstraint: beaconConstraint,
            identifier: Self.beaconRegionIdentifier
        )
        beaconRegion.notifyOnEntry = true
        beaconRegion.notifyOnExit = true
        beaconRegion.notifyEntryStateOnDisplay = true

        locationManager.startMonitoring(for: beaconRegion)
        #if DEBUG
        print("📍 [BackgroundMesh] Started beacon region monitoring")
        #endif
    }

    private func stopBeaconRegionMonitoring() {
        guard let locationManager = locationManager else { return }

        for region in locationManager.monitoredRegions {
            if region.identifier == Self.beaconRegionIdentifier {
                locationManager.stopMonitoring(for: region)
                #if DEBUG
                print("📍 [BackgroundMesh] Stopped beacon region monitoring")
                #endif
            }
        }
    }
    #endif
    
    // MARK: - Background Tasks (iOS 13+)

    #if targetEnvironment(macCatalyst)
    // Mac Catalyst: BGTaskScheduler/BGAppRefreshTask/BGProcessingTask are not
    // available. The LaunchAgent companion handles continuity on Mac, so all
    // BG-task entry points become no-ops here.
    private func registerBackgroundTasks() {}
    func scheduleBackgroundRefresh() {}
    func scheduleBackgroundProcessing() {}
    #else
    private func registerBackgroundTasks() {
        // Register refresh task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleBackgroundRefresh(task: refreshTask)
        }

        // Register processing task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleBackgroundProcessing(task: processingTask)
        }

        #if DEBUG
        print("✅ [BackgroundMesh] Background tasks registered")
        #endif
    }

    /// Schedule background refresh - call when app enters background
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes

        do {
            try BGTaskScheduler.shared.submit(request)
            #if DEBUG
            print("⏰ [BackgroundMesh] Scheduled refresh task for ~15 min")
            #endif
        } catch {
            #if DEBUG
            print("❌ [BackgroundMesh] Failed to schedule refresh: \(error.localizedDescription)")
            #endif
        }
    }

    /// Schedule background processing - for longer tasks
    func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60) // 1 hour
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            #if DEBUG
            print("⏰ [BackgroundMesh] Scheduled processing task for ~1 hour")
            #endif
        } catch {
            #if DEBUG
            print("❌ [BackgroundMesh] Failed to schedule processing: \(error.localizedDescription)")
            #endif
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        #if DEBUG
        print("⏰ [BackgroundMesh] ═══════════════════════════════════════")
        print("⏰ [BackgroundMesh] BACKGROUND REFRESH TRIGGERED")
        print("⏰ [BackgroundMesh] ═══════════════════════════════════════")
        #endif
        
        recordWake(reason: .backgroundRefresh)
        
        // Schedule next refresh
        scheduleBackgroundRefresh()
        
        // Set expiration handler
        task.expirationHandler = { [weak self] in
            #if DEBUG
            print("⚠️ [BackgroundMesh] Refresh task expired")
            #endif
            self?.endAllBackgroundTasks()
            task.setTaskCompleted(success: false)
        }
        
        // Perform mesh work
        Task {
            await performBackgroundMeshWork(extendedTime: false)
            task.setTaskCompleted(success: true)
            #if DEBUG
            print("✅ [BackgroundMesh] Refresh task completed")
            #endif
        }
    }
    
    private func handleBackgroundProcessing(task: BGProcessingTask) {
        #if DEBUG
        print("⏰ [BackgroundMesh] ═══════════════════════════════════════")
        print("⏰ [BackgroundMesh] BACKGROUND PROCESSING TRIGGERED")
        print("⏰ [BackgroundMesh] ═══════════════════════════════════════")
        #endif
        
        recordWake(reason: .backgroundProcessing)
        
        // Schedule next processing
        scheduleBackgroundProcessing()
        
        // Set expiration handler
        task.expirationHandler = { [weak self] in
            #if DEBUG
            print("⚠️ [BackgroundMesh] Processing task expired")
            #endif
            self?.endAllBackgroundTasks()
            task.setTaskCompleted(success: false)
        }
        
        // Perform extended mesh work
        Task {
            await performBackgroundMeshWork(extendedTime: true)
            task.setTaskCompleted(success: true)
            #if DEBUG
            print("✅ [BackgroundMesh] Processing task completed")
            #endif
        }
    }
    #endif

    // MARK: - Background Task Management
    
    /// Begin a background task with identifier
    func beginBackgroundTask(identifier: String, reason: BackgroundWakeReason) {
        taskLock.lock()
        defer { taskLock.unlock() }
        
        // End existing task with same identifier if any
        if let existingTask = activeBackgroundTasks[identifier], existingTask != .invalid {
            UIApplication.shared.endBackgroundTask(existingTask)
        }
        
        let task = UIApplication.shared.beginBackgroundTask(withName: identifier) { [weak self] in
            self?.endBackgroundTask(identifier: identifier)
        }
        
        activeBackgroundTasks[identifier] = task
        lastWakeReason = reason
        
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let remainingStr = remaining == .greatestFiniteMagnitude ? "unlimited" : "\(Int(remaining))s"
        
        #if DEBUG
        print("⏱️ [BackgroundMesh] Task '\(identifier)' started (reason: \(reason.rawValue), time: \(remainingStr))")
        #endif
    }
    
    /// End a specific background task
    func endBackgroundTask(identifier: String) {
        taskLock.lock()
        defer { taskLock.unlock() }
        
        guard let task = activeBackgroundTasks[identifier], task != .invalid else { return }
        
        UIApplication.shared.endBackgroundTask(task)
        activeBackgroundTasks[identifier] = .invalid
        
        #if DEBUG
        print("⏱️ [BackgroundMesh] Task '\(identifier)' ended")
        #endif
    }
    
    /// End all active background tasks
    func endAllBackgroundTasks() {
        taskLock.lock()
        let tasks = activeBackgroundTasks
        taskLock.unlock()
        
        for (identifier, task) in tasks {
            if task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
            }
        }
        
        taskLock.lock()
        activeBackgroundTasks.removeAll()
        taskLock.unlock()
        
        #if DEBUG
        print("⏱️ [BackgroundMesh] All background tasks ended")
        #endif
    }
    
    /// پایان دادن خودکار و هوشمند به فعالیت پسزمینه (Dynamic Idle-Detection)
    func autoEndBackgroundTask(identifier: String, after maxWait: TimeInterval) {
        endBackgroundTask(identifier: identifier)
        
        let timerKey = "\(identifier)_timer"
        
        // باکس امن برای جلوگیری از Data Race
        final class TaskBox: @unchecked Sendable {
            var id: UIBackgroundTaskIdentifier = .invalid
            var isEnded = false
            let lock = NSRecursiveLock()
            func end() {
                lock.lock()
                defer { lock.unlock() }
                if !isEnded && id != .invalid {
                    UIApplication.shared.endBackgroundTask(id)
                    id = .invalid
                    isEnded = true
                }
            }
        }
        
        let box = TaskBox()
        box.lock.lock()
        box.id = UIApplication.shared.beginBackgroundTask(withName: timerKey) { [weak self] in
            box.end()
            self?.taskLock.lock()
            self?.activeBackgroundTasks.removeValue(forKey: timerKey)
            self?.taskLock.unlock()
        }
        let assignedId = box.id
        if box.isEnded && assignedId != .invalid {
            UIApplication.shared.endBackgroundTask(assignedId)
            box.id = .invalid
        }
        box.lock.unlock()
        
        taskLock.lock()
        activeBackgroundTasks[timerKey] = assignedId
        taskLock.unlock()
        
        // 🔋 (Dynamic Watchdog)
        Task {
            let checkInterval: TimeInterval = 2.0
            var elapsed: TimeInterval = 0.0
            var idleCount = 0 
            
            while elapsed < maxWait {
                try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                elapsed += checkInterval
                
                let isBleBusy = await MainActor.run { BLEMeshEngine.shared.isNetworkBusy }
                let pendingOutbox = (try? await MessageRepository.shared.getPendingForMesh().count) ?? 0
                let pendingRelay = await RelayQueueRepository.shared.count()
                
                // 🛑 FIX: Check if we ACTUALLY have peers nearby before staying awake!
                let hasPeers = await MainActor.run { BLEMeshEngine.shared.hasActiveConnections }
                
                let hasWork = (pendingOutbox > 0 || pendingRelay > 0)
                let isOnline = NetworkMonitor.shared.isOnline
                let isBridge = isOnline && hasWork
                
                if isBleBusy || (hasWork && hasPeers) {
                    idleCount = 0 
                } else {
                    idleCount += 1 
                }
                
                // RAVESH KHALAGHANE: Adaptive Background Pacing (Dynamic Watchdog)
                // We adapt the idle threshold based on battery, network role, and current context.
                let batteryLevel = await MainActor.run { UIDevice.current.batteryLevel }
                let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                
                var maxIdleChecks = 2 // Default: 4 seconds of idle
                
                if hasWork && !hasPeers {
                    // We have messages to send, but no peers found yet.
                    // Give BLE more time to scan and discover peers based on device state.
                    if isLowPower || (batteryLevel > 0 && batteryLevel < 0.2) {
                        maxIdleChecks = 3 // 6 seconds in low power (save battery)
                    } else if isBridge {
                        maxIdleChecks = 8 // 16 seconds if we are a bridge (high value node)
                    } else {
                        maxIdleChecks = 6 // 12 seconds for normal scanning (bluetooth takes 8-10s to discover sometimes)
                    }
                }
                
                // 🛑 -> If idle limits reached, END the background task safely
                if idleCount >= maxIdleChecks {
                    #if DEBUG
                    print("  [SmartMesh] Network idle (count: \(idleCount)). Sleeping early at \(elapsed)s to save battery!")
                    #endif
                    break
                }
            }
            
            // 🛑 CPU goes back to sleep
            box.end()
            self.taskLock.lock()
            self.activeBackgroundTasks.removeValue(forKey: timerKey)
            self.taskLock.unlock()
        }
    }

    
    // MARK: - Mesh Work
    
    /// Perform background mesh maintenance and message relay
    private func performBackgroundMeshWork(extendedTime: Bool) async {
        #if DEBUG
        print("🔄 [BackgroundMesh] Performing mesh work (extended: \(extendedTime))...")
        #endif
        
        let startTime = Date()
        
        // 1. Ensure BLE engine is running
        // Use thread-safe accessor — this runs off MainActor and reading
        // the @Published `isScanning` directly would be a strict-concurrency
        // violation (see BLEMeshEngine.isCurrentlyScanning docs).
        let ble = BLEMeshEngine.shared
        if !ble.isCurrentlyScanning || !ble.isAdvertising {
            #if DEBUG
            print("🔄 [BackgroundMesh] Starting BLE engine...")
            #endif
            await MainActor.run {
                ble.start()
                ble.setBackgroundBridgeMode(enabled: true)
            }
            // Wait for BLE to initialize
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        } else {
            await MainActor.run {
                ble.setBackgroundBridgeMode(enabled: true)
            }
        }
        
        // 2. Report current state
        #if DEBUG
        print("🔄 [BackgroundMesh] Connected peers: \(ble.connectedPeers.count)")
        print("🔄 [BackgroundMesh] Is scanning: \(ble.isCurrentlyScanning)")
        print("🔄 [BackgroundMesh] Is advertising: \(ble.isAdvertising)")
        #endif
        
        // 3. Drain pending messages
        #if DEBUG
        print("🔄 [BackgroundMesh] Draining pending messages...")
        #endif
        ble.drainPendingFromDB()
        ble.drainPendingFromOutbox()
        
        // 4. Bridge downlink: pull server messages for nearby BLE peers
        if NetworkMonitor.shared.isOnline {
            #if DEBUG
            print("🔄 [BackgroundMesh] Running bridge downlink poll...")
            #endif
            await BLEMeshEngine.shared.bridgeDownlinkPoll()
        }
        
        // 5. Wait time is now managed by Dynamic Watchdog in autoEndBackgroundTask
        // 💡 دلیل: ما مدیریت زمان را به Dynamic Watchdog سپردیم و او میداند چقدر باید صبر کند.
        
        // 6. Cleanup old data
        #if DEBUG
        print("🔄 [BackgroundMesh] Cleaning up...")
        #endif
        await ble.clearOldStops()
        ble.cleanupStaleSubscribers()
        ble.cleanupStaleChunks()
        
        // 6. Sync pending ACKs if online
        if NetworkMonitor.shared.isOnline {
            #if DEBUG
            print("🔄 [BackgroundMesh] Syncing pending...")
            #endif
            // Sync any pending work
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        #if DEBUG
        print("✅ [BackgroundMesh] Mesh work completed in \(String(format: "%.1f", elapsed))s")
        #endif
    }
    
    // MARK: - Statistics
    
    private func recordWake(reason: BackgroundWakeReason) {
        lastWakeReason = reason
        lastWakeTime = Date()
        totalBackgroundWakes += 1
        saveStatistics()
        
        #if DEBUG
        print("📊 [BackgroundMesh] Wake #\(totalBackgroundWakes) - reason: \(reason.rawValue)")
        #endif
    }
    
    private func saveStatistics() {
        UserDefaults.standard.set(totalBackgroundWakes, forKey: "mesh.background.wakeCount")
        UserDefaults.standard.set(isBackgroundEnabled, forKey: "mesh.background.enabled")
        if let lastWakeTime = lastWakeTime {
            UserDefaults.standard.set(lastWakeTime, forKey: "mesh.background.lastWake")
        }
    }
    
    private func loadStatistics() {
        totalBackgroundWakes = UserDefaults.standard.integer(forKey: "mesh.background.wakeCount")
        isBackgroundEnabled = UserDefaults.standard.bool(forKey: "mesh.background.enabled")
        lastWakeTime = UserDefaults.standard.object(forKey: "mesh.background.lastWake") as? Date
    }
    
    // MARK: - Public Status
    
    /// Get background status for debugging/UI
    func getStatus() -> [String: Any] {
        return [
            "isBackgroundEnabled": isBackgroundEnabled,
            "lastWakeReason": lastWakeReason.rawValue,
            "lastWakeTime": lastWakeTime?.description ?? "never",
            "totalWakes": totalBackgroundWakes,
            "locationAuth": locationAuthorizationStatus.rawValue,
            "activeTaskCount": activeBackgroundTasks.filter { $0.value != .invalid }.count
        ]
    }
}

// MARK: - CLLocationManagerDelegate

extension BackgroundMeshManager: CLLocationManagerDelegate {
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationAuthorizationStatus = manager.authorizationStatus
        
        switch manager.authorizationStatus {
        case .authorizedAlways:
            #if DEBUG
            print("📍 [BackgroundMesh] Location: Always authorized ✅")
            #endif
            startBackgroundLocationAnchor()
            
        case .authorizedWhenInUse:
            #if DEBUG
            print("📍 [BackgroundMesh] Location: When in use only ⚠️")
            print("📍 [BackgroundMesh] Background relay will be limited. Prompt user for 'Always' permission.")
            #endif
            
        case .denied:
            #if DEBUG
            print("📍 [BackgroundMesh] Location: Denied ❌")
            #endif
            isBackgroundEnabled = false
            
        case .restricted:
            #if DEBUG
            print("📍 [BackgroundMesh] Location: Restricted ❌")
            #endif
            isBackgroundEnabled = false
            
        case .notDetermined:
            #if DEBUG
            print("📍 [BackgroundMesh] Location: Not determined - awaiting user response")
            #endif
            
        @unknown default:
            #if DEBUG
            print("📍 [BackgroundMesh] Location: Unknown status")
            #endif
        }
        
        saveStatistics()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        #if DEBUG
        print("📍 [BackgroundMesh] ═══════════════════════════════════════")
        print("📍 [BackgroundMesh] SIGNIFICANT LOCATION CHANGE")
        print("📍 [BackgroundMesh] ═══════════════════════════════════════")
        #endif
        
        if let location = locations.last {
            #if DEBUG
            print("📍 [BackgroundMesh] Location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            #endif
        }
        
        recordWake(reason: .locationChange)
        
        // 💡 مدیریت زمان را به نگهبان پویا میسپاریم
        beginBackgroundTask(identifier: "location_wake", reason: .locationChange)
        autoEndBackgroundTask(identifier: "location_wake", after: 15.0)
        
        Task {
            await performBackgroundMeshWork(extendedTime: false)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == Self.beaconRegionIdentifier else { return }
        
        #if DEBUG
        print("📍 [BackgroundMesh] ═══════════════════════════════════════")
        print("📍 [BackgroundMesh] ENTERED RAVEN MESH REGION")
        print("📍 [BackgroundMesh] Another RAVEN device detected nearby!")
        print("📍 [BackgroundMesh] ═══════════════════════════════════════")
        #endif
        
        recordWake(reason: .beaconRegionEnter)
        
        // 💡 مدیریت زمان به نگهبان پویا
        beginBackgroundTask(identifier: "beacon_enter", reason: .beaconRegionEnter)
        autoEndBackgroundTask(identifier: "beacon_enter", after: 25.0)
        
        Task {
            await performBackgroundMeshWork(extendedTime: true)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.beaconRegionIdentifier else { return }
        
        #if DEBUG
        print("📍 [BackgroundMesh] Exited RAVEN mesh region")
        #endif
        recordWake(reason: .beaconRegionExit)
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        #if DEBUG
        print("❌ [BackgroundMesh] Location error: \(error.localizedDescription)")
        #endif
    }
    
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        #if DEBUG
        print("❌ [BackgroundMesh] Region monitoring failed: \(error.localizedDescription)")
        #endif
    }
}
