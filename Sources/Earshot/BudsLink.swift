import AppKit
import EarshotCore
@preconcurrency import IOBluetooth
import os

private let log = Logger(subsystem: "xyz.srivtx.earshot", category: "link")

@MainActor
protocol BudsLinkDelegate: AnyObject {
    func linkDidChangeState(_ state: BudsLink.State)
    func linkDidReceive(_ event: Event)
    func linkRequestFailed(_ command: Command)
}

/// Owns the RFCOMM control channel to a paired realme earbuds device.
///
/// IOBluetooth delivers every callback on the main run loop, so all state lives on the main actor.
@MainActor
final class BudsLink: NSObject {
    enum State: Equatable {
        /// No realme buds are paired with this Mac.
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
            delegate?.linkDidChangeState(state)
        }
    }

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var decoder = FrameDecoder()
    private var seq: UInt8 = 0

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNote: IOBluetoothUserNotification?

    private var openAttempt = 0
    private var retryTimer: Timer?
    private var pollTimer: Timer?

    private struct Outgoing {
        var command: Command
        var payload: [UInt8]
    }
    private var queue: [Outgoing] = []
    private var inflight: Outgoing?
    private var inflightTimer: Timer?

    /// The vendor control service every realme / Oppo bud exposes over RFCOMM.
    private static let controlService: [UInt8] = [0x00, 0x00, 0x07, 0x9A, 0xD1, 0x02, 0x11, 0xE1,
                                                  0x9B, 0x23, 0x00, 0x02, 0x5B, 0x00, 0xA5, 0xA5]
    /// The channel the Buds Air 7 advertises it on, used if the SDP record isn't cached yet.
    private static let fallbackChannel: BluetoothRFCOMMChannelID = 15
    /// Backoff for opening the channel; the buds often refuse the first attempt after connecting.
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

    var isLinked: Bool { channel?.isOpen() == true }

    func send(_ request: (Command, [UInt8])) {
        guard isLinked else { return }
        // A newer request for the same setting supersedes one still waiting. The last payload
        // byte is the value, so everything before it identifies the setting.
        queue.removeAll {
            $0.command == request.0 && request.0 != .findDevice
                && $0.payload.dropLast() == request.1.dropLast()
        }
        queue.append(Outgoing(command: request.0, payload: request.1))
        pump()
    }

    // MARK: - Device discovery

    private static func findBuds() -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        log.info("paired devices: \(paired.count, privacy: .public)")
        let buds = paired.filter { ($0.name ?? "").lowercased().hasPrefix("realme buds") }
        return buds.first(where: { $0.isConnected() }) ?? buds.first
    }

    private func adopt(_ buds: IOBluetoothDevice) {
        // Always hold the newest object: older ones can keep reporting "not connected".
        let sameDevice = device?.addressString == buds.addressString
        device = buds
        guard !sameDevice || disconnectNote == nil else { return }
        disconnectNote?.unregister()
        disconnectNote = buds.register(forDisconnectNotification: self,
                                       selector: #selector(deviceDidDisconnect(_:device:)))
    }

    private func displayName(_ device: IOBluetoothDevice) -> String {
        device.name ?? "realme Buds"
    }

    @objc private func deviceDidConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard (device.name ?? "").lowercased().hasPrefix("realme buds") else { return }
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
        guard let buds = Self.findBuds(), buds.isConnected() else {
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
            openAttempt += 1
            buds.closeConnection()
            scheduleReconnect(buds)
            return
        }

        var opened: IOBluetoothRFCOMMChannel?
        let id = controlChannel(of: buds)
        let result = buds.openRFCOMMChannelAsync(&opened, withChannelID: id, delegate: self)
        log.info("open channel \(id, privacy: .public) attempt \(self.openAttempt, privacy: .public): \(result, privacy: .public)")
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

    private func controlChannel(of device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID {
        let uuid = Self.controlService.withUnsafeBytes {
            IOBluetoothSDPUUID(bytes: $0.baseAddress, length: Self.controlService.count)
        }
        var id: BluetoothRFCOMMChannelID = 0
        if let record = device.getServiceRecord(for: uuid),
           record.getRFCOMMChannelID(&id) == kIOReturnSuccess {
            return id
        }
        return Self.fallbackChannel
    }

    private func didOpen() {
        retryTimer?.invalidate()
        retryTimer = nil
        openAttempt = 0
        decoder = FrameDecoder()
        seq = 0
        if let device { state = .linked(name: displayName(device)) }

        send(Request.subscribe())
        send(Request.battery())
        send(Request.earbudsStatus())
        send(Request.noiseMode())
        send(Request.holdCycle())
        send(Request.misc(MiscSetting.allCases))
        send(Request.firmware())
        send(Request.touch())
        send(Request.eq())
        send(Request.volumeBoost())

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.send(Request.battery())
                self?.send(Request.earbudsStatus())
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
        if let channel {
            channel.setDelegate(nil)
            channel.close()
        }
        channel = nil
    }

    // MARK: - Request queue

    /// One request in flight at a time: the buds drop commands sent back-to-back.
    private func pump() {
        guard inflight == nil, let channel, channel.isOpen(), !queue.isEmpty else { return }
        let next = queue.removeFirst()
        var bytes = Packet(command: next.command.rawValue, seq: seq, payload: next.payload).encoded()
        seq &+= 1

        let result = channel.writeSync(&bytes, length: UInt16(bytes.count))
        guard result == kIOReturnSuccess else {
            delegate?.linkRequestFailed(next.command)
            pump()
            return
        }
        inflight = next
        // Subscribe is never acknowledged (pushes just start), so only leave a short gap after it.
        let wait = next.command == .subscriptionSet ? Self.unacknowledgedGap : Self.replyTimeout
        inflightTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let stuck = self.inflight else { return }
                self.inflight = nil
                if stuck.command == .subscriptionSet {
                    self.pump()
                    return
                }
                log.error("no reply to \(String(describing: stuck.command), privacy: .public)")
                self.delegate?.linkRequestFailed(stuck.command)
                self.pump()
            }
        }
    }

    private func handle(_ bytes: [UInt8]) {
        for packet in decoder.feed(bytes) {
            if let event = EventParser.parse(packet) {
                log.debug("event \(String(describing: event), privacy: .public)")
                delegate?.linkDidReceive(event)
            }
            if let pending = inflight, packet.command == pending.command.reply {
                inflightTimer?.invalidate()
                inflightTimer = nil
                inflight = nil
                pump()
            }
        }
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
