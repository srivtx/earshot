import AppKit
import EarshotCore
@preconcurrency import IOBluetooth
import os

private let log = Logger(subsystem: "xyz.srivtx.earshot", category: "link")

@MainActor
protocol BudsLinkDelegate: AnyObject {
    func linkDidChangeState(_ state: BudsLink.State)
    func linkDidOpen(_ capabilities: Capabilities)
    func linkDidReceive(_ event: Event)
    func linkRequestFailed(_ setting: Setting)
}

/// Owns the RFCOMM control channel to a paired pair of supported buds, and speaks to them
/// through the brand's driver.
///
/// IOBluetooth delivers every callback on the main run loop, so all state lives on the main actor.
@MainActor
final class BudsLink: NSObject {
    enum State: Equatable {
        /// No supported buds are paired with this Mac.
        case noBuds
        /// Paired, but not connected over Bluetooth (in the case, or connected elsewhere).
        case away(name: String)
        /// Connected for audio; opening the control channel.
        case linking(name: String)
        /// Control channel open.
        case linked(name: String)

        /// Away or unpaired: something the user has to do. Linking resolves by itself.
        var needsAction: Bool {
            switch self {
            case .noBuds, .away: true
            case .linking, .linked: false
            }
        }

        var name: String? {
            switch self {
            case .noBuds: nil
            case let .away(name), let .linking(name), let .linked(name): name
            }
        }
    }

    weak var delegate: BudsLinkDelegate?
    private(set) var state: State = .noBuds {
        didSet {
            guard state != oldValue else { return }
            log.info("state \(String(describing: self.state), privacy: .public)")
            journal.note("state \(state)")
            delegate?.linkDidChangeState(state)
        }
    }

    /// The paired buds' profile, known as soon as they're found.
    private(set) var profile: Profile?
    private(set) var driver: (any Driver)?
    /// Recent traffic, for "Save a report".
    let journal = Journal()

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNote: IOBluetoothUserNotification?

    private var openAttempt = 0
    private var queriedServices = false
    private var retryTimer: Timer?
    private var pollTimer: Timer?

    private var queue: [Outgoing] = []
    private var inflight: Outgoing?
    private var inflightTimer: Timer?

    /// Backoff for opening the channel; buds often refuse the first attempt after connecting.
    private static let retryDelays: [TimeInterval] = [0.4, 0.8, 1.5, 3, 5, 8, 15]
    private static let replyTimeout: TimeInterval = 2.5
    private static let unacknowledgedGap: TimeInterval = 0.15
    private static let openTimeout: TimeInterval = 6
    private static let resetAfterAttempts = 4
    private static let pollInterval: TimeInterval = 90

    func start() {
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(deviceDidConnect(_:device:)))
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
    }

    /// Re-reads the paired device list and links if the buds are connected.
    func refresh() {
        retryTimer?.invalidate()
        retryTimer = nil
        guard let buds = Self.findBuds() else {
            teardown()
            device = nil
            profile = nil
            state = .noBuds
            return
        }
        adopt(buds)
        if buds.isConnected() {
            if !isLinked { beginOpening() }
        } else {
            teardown()
            state = .away(name: displayName(buds))
        }
    }

    /// Asks macOS to connect to the buds (as if picked in the Bluetooth menu).
    func connectAudio() {
        guard let device, !device.isConnected() else { return }
        state = .linking(name: displayName(device))
        let result = device.openConnection(self)
        if result != kIOReturnSuccess { state = .away(name: displayName(device)) }
    }

    var isLinked: Bool { channel?.isOpen() == true && driver != nil }

    func send(_ intent: Intent) {
        guard isLinked, let driver else { return }
        enqueue(driver.encode(intent))
    }

    private func enqueue(_ messages: [Outgoing]) {
        for message in messages {
            if let key = message.supersedes { queue.removeAll { $0.supersedes == key } }
            queue.append(message)
        }
        pump()
    }

    // MARK: - Device discovery

    private static func findBuds() -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        log.info("paired devices: \(paired.count, privacy: .public)")
        let buds = paired.filter { Profiles.match(name: $0.name ?? "") != nil }
        return buds.first(where: { $0.isConnected() }) ?? buds.first
    }

    /// A fresh object for the same buds, if they're still paired and connected.
    private static func refetch(_ device: IOBluetoothDevice?) -> IOBluetoothDevice? {
        guard let address = device?.addressString else { return nil }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.first { $0.addressString == address && $0.isConnected() }
    }

    private func adopt(_ buds: IOBluetoothDevice) {
        // Always hold the newest object: older ones can keep reporting "not connected".
        let sameDevice = device?.addressString == buds.addressString
        device = buds
        profile = Profiles.match(name: buds.name ?? "")
        guard !sameDevice || disconnectNote == nil else { return }
        queriedServices = false
        disconnectNote?.unregister()
        disconnectNote = buds.register(forDisconnectNotification: self,
                                       selector: #selector(deviceDidDisconnect(_:device:)))
    }

    private func displayName(_ device: IOBluetoothDevice) -> String {
        device.name ?? "Buds"
    }

    @objc private func deviceDidConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard Profiles.match(name: device.name ?? "") != nil else { return }
        // Another pair of supported buds is already linked; leave it be.
        if isLinked, self.device?.addressString != device.addressString { return }
        adopt(device)
        // Give the buds a moment to finish bringing up audio before asking for the control channel.
        teardown()
        state = .linking(name: displayName(device))
        scheduleOpen(after: 1.0)
    }

    @objc private func deviceDidDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        teardown()
        disconnectNote?.unregister()
        disconnectNote = nil
        state = .away(name: displayName(device))
        // Another supported pair may still be connected.
        scheduleOpen(after: 1.0, refreshing: true)
    }

    @objc private func systemDidWake() {
        teardown()
        scheduleOpen(after: 2.0, refreshing: true)
    }

    // MARK: - Channel lifecycle

    private func beginOpening() {
        teardown()
        openAttempt = 0
        if let device { state = .linking(name: displayName(device)) }
        openChannel()
    }

    private func scheduleOpen(after delay: TimeInterval, refreshing: Bool = false) {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryTimer = nil
                if refreshing { self.refresh() } else { self.openChannel() }
            }
        }
    }

    private func openChannel() {
        guard let buds = Self.refetch(device) ?? Self.findBuds(), buds.isConnected() else {
            teardown()
            if let device { state = .away(name: displayName(device)) } else { state = .noBuds }
            return
        }
        adopt(buds)
        state = .linking(name: displayName(buds))

        // A channel left half-open (e.g. by a force-quit copy) blocks new opens until the
        // Bluetooth link is reset. Do that once the normal retries have clearly failed.
        if openAttempt == Self.resetAfterAttempts {
            log.info("control channel stuck; resetting the Bluetooth link")
            journal.note("resetting the Bluetooth link")
            openAttempt += 1
            buds.closeConnection()
            scheduleReconnect(buds)
            return
        }

        guard let id = controlChannel(of: buds) else {
            // The service records aren't cached yet: ask the buds for them, then try again.
            if !queriedServices {
                queriedServices = true
                journal.note("no control service in SDP cache; querying")
                buds.performSDPQuery(nil)
            }
            retryOpen()
            return
        }

        var opened: IOBluetoothRFCOMMChannel?
        let result = buds.openRFCOMMChannelAsync(&opened, withChannelID: id, delegate: self)
        log.info("open channel \(id, privacy: .public) attempt \(self.openAttempt, privacy: .public): \(result, privacy: .public)")
        journal.note("open channel \(id) attempt \(openAttempt): \(result)")
        if result != kIOReturnSuccess {
            retryOpen()
        } else {
            channel = opened
            // If macOS never reports back on the open, start over rather than hang in "linking".
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: Self.openTimeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.channel === opened, opened?.isOpen() != true else { return }
                    log.error("channel open timed out")
                    self.retryTimer = nil
                    self.retryOpen()
                }
            }
        }
    }

    private func scheduleReconnect(_ buds: IOBluetoothDevice) {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryTimer = nil
                // The connect notification schedules the next open.
                if buds.openConnection(self) != kIOReturnSuccess { self.retryOpen() }
            }
        }
    }

    /// Closes the control channel so the buds accept a new one straight away next launch.
    func shutdown() {
        teardown()
        connectNote?.unregister()
        disconnectNote?.unregister()
    }

    private func retryOpen() {
        log.info("open attempt \(self.openAttempt, privacy: .public) failed, retrying")
        if let channel {
            channel.setDelegate(nil)
            channel.close()
        }
        channel = nil
        let delay = openAttempt < Self.retryDelays.count ? Self.retryDelays[openAttempt] : 30
        openAttempt += 1
        scheduleOpen(after: delay)
    }

    /// The RFCOMM channel of the brand's control service, from the SDP records.
    private func controlChannel(of device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        guard let profile else { return nil }
        let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
        for match in profile.services {
            for record in records where Self.record(record, matches: match) {
                var id: BluetoothRFCOMMChannelID = 0
                if record.getRFCOMMChannelID(&id) == kIOReturnSuccess { return id }
            }
        }
        return profile.fallbackChannel
    }

    private static func record(_ record: IOBluetoothSDPServiceRecord, matches match: ServiceMatch) -> Bool {
        let classes = record.getAttributeDataElement(BluetoothSDPServiceAttributeID(kBluetoothSDPAttributeIdentifierServiceClassIDList.rawValue))?
            .getArrayValue() as? [IOBluetoothSDPDataElement] ?? []
        return classes.contains { element in
            guard let uuid = element.getUUIDValue()?.getWithLength(16) else { return false }
            let bytes = [UInt8](Data(referencing: uuid))
            switch match {
            case let .uuid(wanted): return bytes == wanted
            case let .prefix(wanted): return bytes.starts(with: wanted)
            }
        }
    }

    private func didOpen() {
        retryTimer?.invalidate()
        retryTimer = nil
        openAttempt = 0
        guard let device, let profile else { return }
        let driver = profile.driver(name: displayName(device))
        self.driver = driver
        journal.begin(name: displayName(device), profile: profile)
        state = .linked(name: displayName(device))
        delegate?.linkDidOpen(driver.capabilities)
        enqueue(driver.start())

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let driver = self.driver else { return }
                self.enqueue(driver.poll())
            }
        }
    }

    private func teardown() {
        retryTimer?.invalidate()
        retryTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        inflightTimer?.invalidate()
        inflightTimer = nil
        inflight = nil
        queue.removeAll()
        driver = nil
        if let channel {
            channel.setDelegate(nil)
            channel.close()
        }
        channel = nil
    }

    // MARK: - Request queue

    /// One message in flight at a time: buds drop commands sent back to back.
    private func pump() {
        guard inflight == nil, let channel, channel.isOpen(), let driver, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        guard write(driver.frame(next), on: channel) else {
            if let setting = next.setting { delegate?.linkRequestFailed(setting) }
            pump()
            return
        }
        if next.appliedOnWrite, let setting = next.setting { delegate?.linkDidReceive(.applied(setting)) }
        inflight = next
        let wait = next.reply == nil ? Self.unacknowledgedGap : Self.replyTimeout
        inflightTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let stuck = self.inflight else { return }
                self.inflight = nil
                if stuck.reply != nil {
                    log.error("no reply to \(stuck.body.hex, privacy: .public)")
                    self.journal.note("no reply")
                    if let setting = stuck.setting, !stuck.appliedOnWrite { self.delegate?.linkRequestFailed(setting) }
                }
                self.pump()
            }
        }
    }

    private func write(_ frame: [UInt8], on channel: IOBluetoothRFCOMMChannel) -> Bool {
        var bytes = frame
        journal.record(.sent, bytes)
        return channel.writeSync(&bytes, length: UInt16(bytes.count)) == kIOReturnSuccess
    }

    private func handle(_ bytes: [UInt8]) {
        journal.record(.received, bytes)
        guard let driver, let channel else { return }
        let inbound = driver.receive(bytes)
        for frame in inbound.immediate { _ = write(frame, on: channel) }
        for event in inbound.events {
            log.debug("event \(String(describing: event), privacy: .public)")
            if case let .capabilities(caps) = event { delegate?.linkDidOpen(caps) } else { delegate?.linkDidReceive(event) }
        }
        if let pending = inflight?.reply, inbound.replies.contains(pending) {
            inflightTimer?.invalidate()
            inflightTimer = nil
            inflight = nil
        }
        enqueue(inbound.send)
    }
}

// MARK: - IOBluetoothRFCOMMChannelDelegate

extension BudsLink: IOBluetoothRFCOMMChannelDelegate {
    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        MainActor.assumeIsolated {
            guard rfcommChannel === channel else { return }
            if error == kIOReturnSuccess { didOpen() } else { retryOpen() }
        }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        MainActor.assumeIsolated {
            guard rfcommChannel === channel else { return }
            handle(bytes)
        }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        MainActor.assumeIsolated {
            guard rfcommChannel === channel else { return }
            teardown()
            // Closed under us while still connected: reopen. Otherwise the disconnect note handles it.
            if let device, device.isConnected() {
                state = .linking(name: displayName(device))
                retryOpen()
            }
        }
    }
}

extension [UInt8] {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
