//
//  ChessMultipeer.swift
//  Notchly — nearby chess over MultipeerConnectivity (Option A)
//
//  Advertises you (by your multiplayer username) on the local network and
//  browses for other Notchly users. Either side can invite the other; on accept
//  a peer-to-peer session opens and moves are relayed live. No server, no
//  accounts — same Wi-Fi / local network only.
//

import Foundation
import Combine
import MultipeerConnectivity

/// Wire messages exchanged over the session.
enum GameMessage: Codable {
    case start(hostIsWhite: Bool)          // host tells guest the game has begun
    case move(from: Int, to: Int, promo: Int?)
    case resign
}

/// Lets a non-Sendable MC callback payload cross into a MainActor hop safely.
private struct Unsafe<T>: @unchecked Sendable { let value: T }

@MainActor
final class ChessMultipeer: NSObject, ObservableObject {
    static let serviceType = "notchly-chess"   // 1–15 chars, [a-z0-9-]

    struct Invite: Identifiable {
        let id = UUID()
        let peerName: String
        let respond: (Bool) -> Void
    }

    @Published private(set) var online = false
    @Published private(set) var nearby: [MCPeerID] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var statusText = "Offline"
    @Published var incomingInvite: Invite?

    weak var game: ChessGame?

    private let myPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var iAmHost = false

    init(displayName: String) {
        let name = String(displayName.trimmingCharacters(in: .whitespaces).prefix(60))
        myPeerID = MCPeerID(displayName: name.isEmpty ? "Player" : name)
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    // MARK: Presence

    func goOnline() {
        guard !online else { return }
        online = true
        statusText = "Looking for players…"
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func goOffline() {
        online = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        nearby = []
        connectedName = nil
        incomingInvite = nil
        statusText = "Offline"
    }

    func invite(_ peer: MCPeerID) {
        iAmHost = true
        statusText = "Inviting \(peer.displayName)…"
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 25)
    }

    // MARK: Sending

    func send(_ message: GameMessage) {
        guard !session.connectedPeers.isEmpty, let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    func resign() {
        send(.resign)
    }

    // MARK: Connection lifecycle (main-actor)

    private func handleConnected(_ peerName: String) {
        connectedName = peerName
        statusText = "Connected to \(peerName)"
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        if iAmHost {
            // Host is White; tell the guest and start.
            send(.start(hostIsWhite: true))
            game?.onLocalMove = { [weak self] m in
                self?.send(.move(from: m.from, to: m.to, promo: m.promotion?.rawValue))
            }
            game?.startLiveGame(localColor: .white, opponentName: peerName)
        }
        // Guest waits for the .start message to learn its colour.
    }

    private func handleDisconnected() {
        connectedName = nil
        game?.setLiveConnected(false)
        if online { statusText = "Looking for players…"; advertiser.startAdvertisingPeer(); browser.startBrowsingForPeers() }
        else { statusText = "Offline" }
    }

    private func handle(_ message: GameMessage, from peerName: String) {
        switch message {
        case .start(let hostIsWhite):
            // We are the guest → take the opposite colour and start.
            game?.onLocalMove = { [weak self] m in
                self?.send(.move(from: m.from, to: m.to, promo: m.promotion?.rawValue))
            }
            game?.startLiveGame(localColor: hostIsWhite ? .black : .white, opponentName: peerName)
        case .move(let from, let to, let promo):
            let move = ChessMove(from: from, to: to,
                                 promotion: promo.flatMap { PieceKind(rawValue: $0) })
            game?.applyRemoteMove(move)
        case .resign:
            game?.setLiveConnected(false)
            statusText = "\(peerName) resigned"
        }
    }
}

// MARK: - MC delegates (nonisolated; hop to the main actor)

extension ChessMultipeer: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        Task { @MainActor [weak self] in
            switch state {
            case .connected: self?.handleConnected(name)
            case .notConnected: self?.handleDisconnected()
            default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let msg = try? JSONDecoder().decode(GameMessage.self, from: data) else { return }
        let boxed = Unsafe(value: msg)
        let name = peerID.displayName
        Task { @MainActor [weak self] in self?.handle(boxed.value, from: name) }
    }

    nonisolated func session(_ s: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) {}
    nonisolated func session(_ s: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    nonisolated func session(_ s: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}

extension ChessMultipeer: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let name = peerID.displayName
        let boxed = Unsafe(value: invitationHandler)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.iAmHost = false
            self.incomingInvite = Invite(peerName: name) { accept in
                boxed.value(accept, accept ? self.session : nil)
                if !accept { self.incomingInvite = nil }
            }
        }
    }
}

extension ChessMultipeer: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let boxed = Unsafe(value: peerID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.nearby.contains(boxed.value) { self.nearby.append(boxed.value) }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let boxed = Unsafe(value: peerID)
        Task { @MainActor [weak self] in self?.nearby.removeAll { $0 == boxed.value } }
    }
}
