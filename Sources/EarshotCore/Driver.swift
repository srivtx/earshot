// The contract between the Bluetooth link and a brand's protocol.
//
// The link owns the RFCOMM channel and sends one message at a time. A driver turns intents into
// messages, frames them when they go out (some brands number them), and turns received bytes
// into events.

/// A message waiting to be sent.
public struct Outgoing: Equatable, Sendable {
    /// Driver-specific contents; `Driver.frame(_:)` turns it into bytes at send time.
    public var body: [UInt8]
    /// What the link waits for before sending the next message. Nil leaves a short gap instead.
    public var reply: UInt32?
    /// Reported as failed if the reply never comes.
    public var setting: Setting?
    /// A newer message with the same key replaces one still queued.
    public var supersedes: [UInt8]?
    /// For brands that never confirm changes: report success once the bytes are written.
    public var appliedOnWrite = false

    public init(body: [UInt8], reply: UInt32? = nil, setting: Setting? = nil,
                supersedes: [UInt8]? = nil, appliedOnWrite: Bool = false) {
        self.body = body
        self.reply = reply
        self.setting = setting
        self.supersedes = supersedes
        self.appliedOnWrite = appliedOnWrite
    }
}

/// What a driver made of received bytes.
public struct Inbound: Equatable, Sendable {
    public var events: [Event] = []
    /// Reply keys that arrived, matched against `Outgoing.reply`.
    public var replies: [UInt32] = []
    /// Follow-up messages, e.g. reading a setting back after the buds accepted it.
    public var send: [Outgoing] = []
    /// Frames to write straight away, ahead of the queue (protocol-level acknowledgements).
    public var immediate: [[UInt8]] = []

    public init() {}
}

public protocol Driver: AnyObject {
    var capabilities: Capabilities { get }
    /// Sent once the channel opens.
    func start() -> [Outgoing]
    /// Sent every so often while linked, to keep battery levels fresh.
    func poll() -> [Outgoing]
    func encode(_ intent: Intent) -> [Outgoing]
    /// Final bytes for a message, at the moment it's written.
    func frame(_ message: Outgoing) -> [UInt8]
    func receive(_ bytes: [UInt8]) -> Inbound
}

extension Driver {
    public func poll() -> [Outgoing] { encode(.refresh) }
    public func frame(_ message: Outgoing) -> [UInt8] { message.body }
}
