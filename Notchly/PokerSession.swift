//
//  PokerSession.swift
//  Notchly — multiplayer table coordination
//
//  Owns the lobby: who is sitting down, whether empty seats get filled with
//  bots, and which side of the host/guest split this Mac is on. The game engine
//  itself stays in TexasHoldemGame; this just feeds it and relays its state.
//
//  Seat 0 is always this Mac's player, so the existing "you" rendering keeps
//  working unchanged whether the table is local, hosted or joined.
//

import Foundation
import Combine
import MultipeerConnectivity

@MainActor
final class PokerSession: ObservableObject {

    enum Role: Equatable { case offline, host, guest }
    enum Transport: Equatable { case nearby, roomCode }

    @Published private(set) var role: Role = .offline
    @Published private(set) var transport: Transport = .nearby
    @Published private(set) var roomCode: String?
    @Published private(set) var seats: [PokerSeatInfo] = []
    @Published private(set) var status = ""
    @Published private(set) var started = false
    @Published private(set) var nearbyHosts: [MCPeerID] = []

    /// Fill unused seats with AI so a short table still plays a full game.
    /// Heads-up is simply this left off with one other human.
    @Published var fillWithBots = true
    /// Total seats at the table, including you.
    @Published var tableSize = 4

    /// Latest table state received from the host (guests only).
    @Published private(set) var snapshot: PokerSnapshot?
    /// This player's hole cards as dealt by the host (guests only).
    @Published private(set) var myHole: [CardDTO] = []

    let myID = UUID().uuidString
    var myName: String { NotchSettings.shared.multiplayerName }

    private var relay: PokerRelayTransport?
    private var nearby: PokerNearbyTransport?
    private var cancellables = Set<AnyCancellable>()

    /// Set by the view so incoming actions can be driven into the engine.
    var onGuestAction: ((String, PokerAction) -> Void)?
    /// Raised on guests when the host says the game is starting.
    var onBegin: (() -> Void)?

    private var current: (any PokerTransport)? { relay ?? nearby }

    // MARK: - Hosting

    func hostRoomCode() {
        reset()
        role = .host
        transport = .roomCode
        let code = PokerRelayTransport.newCode()
        roomCode = code
        let t = PokerRelayTransport(code: code)
        wire(t)
        relay = t
        seats = [PokerSeatInfo(id: myID, name: myName, isBot: false)]
        status = "Share code \(code) — waiting for players"
    }

    func hostNearby() {
        reset()
        role = .host
        transport = .nearby
        let t = PokerNearbyTransport(displayName: myName, isHost: true)
        wire(t)
        t.onPeerConnected = { [weak self] name in
            guard let self else { return }
            // Nearby peers are identified by display name; the roster uses it
            // as the id so actions can be attributed without a handshake.
            self.addSeat(PokerSeatInfo(id: name, name: name, isBot: false))
        }
        t.onPeerDisconnected = { [weak self] name in
            self?.seats.removeAll { $0.id == name }
            self?.broadcastRoster()
        }
        nearby = t
        seats = [PokerSeatInfo(id: myID, name: myName, isBot: false)]
        status = "Waiting for players on this network"
    }

    // MARK: - Joining

    func joinRoomCode(_ code: String) {
        reset()
        role = .guest
        transport = .roomCode
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        roomCode = clean
        let t = PokerRelayTransport(code: clean)
        wire(t)
        relay = t
        t.send(.hello(id: myID, name: myName))
        status = "Joining table \(clean)…"
    }

    func browseNearby() {
        reset()
        role = .guest
        transport = .nearby
        let t = PokerNearbyTransport(displayName: myName, isHost: false)
        wire(t)
        t.$found
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.nearbyHosts = $0 }
            .store(in: &cancellables)
        nearby = t
        status = "Looking for tables on this network…"
    }

    func joinNearby(_ peer: MCPeerID) {
        nearby?.invite(peer)
        // The hello is sent once the session reports the peer connected.
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            self.current?.send(.hello(id: self.myID, name: self.myName))
        }
    }

    // MARK: - Wiring

    private func wire(_ t: any PokerTransport) {
        var t = t
        t.onStatus = { [weak self] in self?.status = $0 }
        t.onMessage = { [weak self] msg in self?.handle(msg) }
    }

    private func handle(_ msg: PokerMessage) {
        switch msg {
        case .hello(let id, let name):
            guard role == .host else { return }
            addSeat(PokerSeatInfo(id: id, name: name, isBot: false))

        case .roster(let list):
            guard role == .guest else { return }
            seats = list
            status = "Seated — \(list.count) player\(list.count == 1 ? "" : "s")"

        case .begin:
            guard role == .guest else { return }
            started = true
            onBegin?()

        case .snapshot(let snap):
            guard role == .guest else { return }
            snapshot = snap

        case .hole(let playerID, let cards):
            guard role == .guest, playerID == myID else { return }
            myHole = cards

        case .act(let playerID, let action):
            guard role == .host else { return }
            onGuestAction?(playerID, action)

        case .bye(let id):
            seats.removeAll { $0.id == id }
            if role == .host { broadcastRoster() }
        }
    }

    private func addSeat(_ seat: PokerSeatInfo) {
        guard role == .host else { return }
        guard !seats.contains(where: { $0.id == seat.id }) else { return }
        guard seats.filter({ !$0.isBot }).count < tableSize else {
            status = "Table is full"
            return
        }
        seats.append(seat)
        status = "\(seats.count) player\(seats.count == 1 ? "" : "s") seated"
        broadcastRoster()
    }

    func broadcastRoster() {
        guard role == .host else { return }
        current?.send(.roster(seats))
    }

    // MARK: - Host → table

    /// Final seat list once the host deals: humans first, then bots to fill.
    func finalSeating() -> [PokerSeatInfo] {
        var list = seats.filter { !$0.isBot }
        if fillWithBots {
            let botNames = ["Ava", "Rex", "Mia", "Leo", "Nico", "Sam"]
            var n = 0
            while list.count < tableSize && n < botNames.count {
                let name = botNames[n]
                n += 1
                guard !list.contains(where: { $0.name == name }) else { continue }
                list.append(PokerSeatInfo(id: "bot-\(name)", name: name, isBot: true))
            }
        }
        return list
    }

    func begin() {
        guard role == .host else { return }
        seats = finalSeating()
        broadcastRoster()
        current?.send(.begin)
        started = true
    }

    func broadcast(_ snapshot: PokerSnapshot) {
        guard role == .host else { return }
        current?.send(.snapshot(snapshot))
    }

    func deal(_ cards: [CardDTO], to playerID: String) {
        guard role == .host else { return }
        current?.send(.hole(playerID: playerID, cards: cards))
    }

    // MARK: - Guest → host

    func sendAction(_ action: PokerAction) {
        guard role == .guest else { return }
        current?.send(.act(playerID: myID, action: action))
    }

    // MARK: - Teardown

    func leave() {
        current?.send(.bye(id: myID))
        reset()
    }

    private func reset() {
        relay?.stop(); relay = nil
        nearby?.stop(); nearby = nil
        cancellables.removeAll()
        role = .offline
        roomCode = nil
        seats = []
        nearbyHosts = []
        snapshot = nil
        myHole = []
        started = false
        status = ""
    }
}
