//
//  ChessRelay.swift
//  Notchly — online chess via a one-time room code (Option B, relayed)
//
//  Uses ntfy.sh — a free, no-account public pub/sub over plain HTTPS — as the
//  relay in the middle. One player "creates" a game and gets a short code; the
//  other enters that code to join. Both then exchange moves live by publishing
//  to / polling a topic named after the code. No accounts, no server to run.
//
//  Trade-offs (as chosen): it's a PUBLIC relay, so the random room code is the
//  only privacy, and delivery can lag or briefly drop. Fine for casual play.
//

import Foundation
import Combine

private enum RelayMessage: Codable {
    case join(name: String)
    case start(hostName: String, hostIsWhite: Bool)
    case move(from: Int, to: Int, promo: Int?)
    case resign
}

private struct RelayEnvelope: Codable {
    let sender: String
    let msg: RelayMessage
}

@MainActor
final class ChessRelay: ObservableObject {
    enum Phase: Equatable { case idle, hosting, joining, connected }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var roomCode: String?
    @Published private(set) var statusText = ""
    @Published private(set) var opponentName = ""

    weak var game: ChessGame?

    private let senderID = UUID().uuidString
    private var myName = "Player"
    private var iAmHost = false
    private var pollTask: Task<Void, Never>?
    private var lastSince = ""

    private static let base = "https://ntfy.sh"
    private func topic(_ code: String) -> String { "ntchly-chess-\(code.lowercased())" }

    private static let codeAlphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    private static func newCode() -> String { String((0..<5).map { _ in codeAlphabet.randomElement()! }) }

    // MARK: Public control

    /// Create a game; returns the code to share.
    @discardableResult
    func host(name: String) -> String {
        stop()
        myName = name.isEmpty ? "Player" : name
        iAmHost = true
        let code = Self.newCode()
        roomCode = code
        phase = .hosting
        statusText = "Waiting for a friend to join with code \(code)…"
        startPolling(code: code)
        return code
    }

    /// Join an existing game by its code.
    func join(code: String, name: String) {
        stop()
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard clean.count == 5 else { statusText = "That code doesn't look right."; return }
        myName = name.isEmpty ? "Player" : name
        iAmHost = false
        roomCode = clean
        phase = .joining
        statusText = "Joining \(clean)…"
        startPolling(code: clean)
        publish(.join(name: myName), code: clean)
    }

    func leave() {
        if phase == .connected { publish(.resign, code: roomCode ?? "") }
        stop()
        phase = .idle
        roomCode = nil
        opponentName = ""
        statusText = ""
        game?.setLiveConnected(false)
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
        lastSince = ""
    }

    private func sendMove(_ m: ChessMove) {
        guard let code = roomCode else { return }
        publish(.move(from: m.from, to: m.to, promo: m.promotion?.rawValue), code: code)
    }

    // MARK: Networking (ntfy)

    private func publish(_ msg: RelayMessage, code: String) {
        guard let body = try? JSONEncoder().encode(RelayEnvelope(sender: senderID, msg: msg)),
              let url = URL(string: "\(Self.base)/\(topic(code))") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }

    private func startPolling(code: String) {
        lastSince = String(Int(Date().timeIntervalSince1970))   // only messages from now on
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(code: code)
                try? await Task.sleep(nanoseconds: 1_400_000_000)
            }
        }
    }

    private func pollOnce(code: String) async {
        guard let url = URL(string: "\(Self.base)/\(topic(code))/json?poll=1&since=\(lastSince)") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let note = try? JSONDecoder().decode(NtfyNote.self, from: lineData) else { continue }
            lastSince = note.id
            guard note.event == "message", let payloadStr = note.message,
                  let payloadData = payloadStr.data(using: .utf8),
                  let env = try? JSONDecoder().decode(RelayEnvelope.self, from: payloadData),
                  env.sender != senderID else { continue }
            handle(env.msg)
        }
    }

    private struct NtfyNote: Codable { let id: String; let event: String?; let message: String? }

    // MARK: Message handling

    private func handle(_ msg: RelayMessage) {
        switch msg {
        case .join(let name):
            guard iAmHost, phase != .connected else { return }
            opponentName = name
            phase = .connected
            statusText = "Connected to \(name)"
            game?.onLocalMove = { [weak self] m in self?.sendMove(m) }
            game?.startLiveGame(localColor: .white, opponentName: name)
            if let code = roomCode { publish(.start(hostName: myName, hostIsWhite: true), code: code) }

        case .start(let hostName, let hostIsWhite):
            guard !iAmHost, phase != .connected else { return }
            opponentName = hostName
            phase = .connected
            statusText = "Connected to \(hostName)"
            game?.onLocalMove = { [weak self] m in self?.sendMove(m) }
            game?.startLiveGame(localColor: hostIsWhite ? .black : .white, opponentName: hostName)

        case .move(let from, let to, let promo):
            game?.applyRemoteMove(ChessMove(from: from, to: to, promotion: promo.flatMap { PieceKind(rawValue: $0) }))

        case .resign:
            statusText = "\(opponentName) left the game"
            game?.setLiveConnected(false)
        }
    }
}
