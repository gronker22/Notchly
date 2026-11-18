//
//  PokerNet.swift
//  Notchly — multiplayer Texas Hold'em
//
//  Poker is harder to network than chess, and the design follows from why.
//
//  Chess is fully observable: both sides see the whole board, so each client
//  can run the same engine and validate the other's move independently. Poker
//  isn't — hole cards are hidden, and no client can be trusted to shuffle or to
//  tell the truth about what it holds. So this is **host-authoritative**: the
//  host runs the one real game, and everyone else sends intents and renders
//  what they're told.
//
//    guest  --act(fold/call/raise)-->  host     (intent only, never state)
//    host   --snapshot(public)------>  everyone (pot, bets, board, whose turn)
//    host   --hole(cards)----------->  one player only
//
//  Two transports, same protocol:
//
//  * Nearby — MultipeerConnectivity over the local network, same as chess.
//    No server, no accounts, but both Macs must be on the same Wi-Fi.
//  * Room code — a short code over the public ntfy.sh relay, for players on
//    different networks.
//
//  Honest limit on the relay: ntfy topics are public, so hole cards travel in
//  the clear over a hard-to-guess topic name rather than a private channel.
//  That's fine among friends; it is not a defence against someone who wants to
//  cheat and knows the code. Nearby play over MultipeerConnectivity is
//  encrypted and doesn't have this caveat.
//

import Foundation
import Combine
import MultipeerConnectivity

// MARK: - Wire types

struct CardDTO: Codable, Equatable {
    let rank: Int
    let suit: String
}

enum PokerAction: Codable, Equatable {
    case fold, check, call, allIn
    case raiseTo(Int)
}

struct PokerSeatInfo: Codable, Equatable, Identifiable {
    let id: String          // peer/player id; bots get a synthetic one
    let name: String
    let isBot: Bool
}

/// Everything a client needs to draw the table. Public information only —
/// hole cards arrive separately and only to their owner.
struct PokerSnapshot: Codable, Equatable {
    struct PlayerView: Codable, Equatable {
        let seat: Int
        let name: String
        let chips: Int
        let bet: Int
        let folded: Bool
        let allIn: Bool
        let lastAction: String
        let isBot: Bool
        /// Populated only at showdown, when everyone's cards are face up.
        let revealedHole: [CardDTO]
    }
    let players: [PlayerView]
    let community: [CardDTO]
    let pot: Int
    let toCall: Int
    let minRaiseTo: Int
    let currentSeat: Int
    let dealerSeat: Int
    let stage: String
    let message: String
    let resultText: String
    let revealAll: Bool
}

enum PokerMessage: Codable {
    case hello(id: String, name: String)        // guest -> host
    case roster([PokerSeatInfo])                // host -> all
    case begin                                  // host -> all
    case snapshot(PokerSnapshot)                // host -> all
    case hole(playerID: String, cards: [CardDTO])  // host -> one
    case act(playerID: String, action: PokerAction) // guest -> host
    case bye(id: String)
}

// MARK: - Transport

@MainActor
protocol PokerTransport: AnyObject {
    var onMessage: ((PokerMessage) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    func send(_ message: PokerMessage)
    func stop()
}

// MARK: - Room-code transport (ntfy.sh)

@MainActor
final class PokerRelayTransport: PokerTransport {

    var onMessage: ((PokerMessage) -> Void)?
    var onStatus: ((String) -> Void)?

    let code: String
    private let senderID = UUID().uuidString
    private var pollTask: Task<Void, Never>?
    private var lastSince = "all"

    private static let base = "https://ntfy.sh"
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// Five characters from an alphabet with no look-alikes (no O/0, I/1, L).
    static func newCode() -> String {
        String((0..<5).map { _ in alphabet.randomElement()! })
    }

    private func topic() -> String { "ntchly-poker-\(code.lowercased())" }

    init(code: String) {
        self.code = code
        startPolling()
    }

    private struct Envelope: Codable {
        let sender: String
        let msg: PokerMessage
    }
    private struct NtfyNote: Codable { let id: String; let event: String?; let message: String? }

    func send(_ message: PokerMessage) {
        guard let body = try? JSONEncoder().encode(Envelope(sender: senderID, msg: message)),
              let url = URL(string: "\(Self.base)/\(topic())") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }

    private func startPolling() {
        lastSince = String(Int(Date().timeIntervalSince1970))
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                // Poker is turn-based with human-speed decisions, so a ~1s
                // poll is responsive without hammering a public relay.
                try? await Task.sleep(nanoseconds: 1_100_000_000)
            }
        }
    }

    private func pollOnce() async {
        guard let url = URL(string: "\(Self.base)/\(topic())/json?poll=1&since=\(lastSince)"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let note = try? JSONDecoder().decode(NtfyNote.self, from: lineData) else { continue }
            lastSince = note.id
            guard note.event == "message",
                  let payload = note.message,
                  let payloadData = payload.data(using: .utf8),
                  let env = try? JSONDecoder().decode(Envelope.self, from: payloadData),
                  env.sender != senderID else { continue }
            onMessage?(env.msg)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}

// MARK: - Nearby transport (MultipeerConnectivity)

@MainActor
final class PokerNearbyTransport: NSObject, PokerTransport {

    var onMessage: ((PokerMessage) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Raised on the host when a peer connects, so it can seat them.
    var onPeerConnected: ((String) -> Void)?
    var onPeerDisconnected: ((String) -> Void)?

    static let serviceType = "notchly-poker"    // 1–15 chars, [a-z0-9-]

    private let peerID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    @Published private(set) var found: [MCPeerID] = []

    init(displayName: String, isHost: Bool) {
        let trimmed = String(displayName.prefix(60))
        peerID = MCPeerID(displayName: trimmed.isEmpty ? "Player" : trimmed)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self

        if isHost {
            let ad = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil,
                                               serviceType: Self.serviceType)
            ad.delegate = self
            ad.startAdvertisingPeer()
            advertiser = ad
            onStatus?("Waiting for players…")
        } else {
            let br = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
            br.delegate = self
            br.startBrowsingForPeers()
            browser = br
            onStatus?("Looking for tables…")
        }
    }

    func invite(_ peer: MCPeerID) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 25)
        onStatus?("Joining \(peer.displayName)…")
    }

    func send(_ message: PokerMessage) {
        guard !session.connectedPeers.isEmpty,
              let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
        advertiser = nil
        browser = nil
    }
}

/// MCSession/advertiser/browser callbacks arrive off the main actor, so each
/// one hops across with the payload boxed.
private struct Box<T>: @unchecked Sendable { let value: T }

extension PokerNearbyTransport: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        Task { @MainActor in
            switch state {
            case .connected:
                self.onStatus?("\(name) connected")
                self.onPeerConnected?(name)
            case .notConnected:
                self.onStatus?("\(name) left")
                self.onPeerDisconnected?(name)
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let msg = try? JSONDecoder().decode(PokerMessage.self, from: data) else { return }
        let boxed = Box(value: msg)
        Task { @MainActor in self.onMessage?(boxed.value) }
    }

    nonisolated func session(_ s: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) {}
    nonisolated func session(_ s: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    nonisolated func session(_ s: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}

extension PokerNearbyTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // The host is openly advertising a table, so joins are accepted. The
        // lobby still shows who arrived before anyone can deal.
        let boxed = Box(value: invitationHandler)
        Task { @MainActor in boxed.value(true, self.session) }
    }
}

extension PokerNearbyTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        let boxed = Box(value: peerID)
        Task { @MainActor in
            if !self.found.contains(boxed.value) { self.found.append(boxed.value) }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let boxed = Box(value: peerID)
        Task { @MainActor in self.found.removeAll { $0 == boxed.value } }
    }
}
