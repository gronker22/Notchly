//
//  ChessView.swift
//  Notchly — Chess UI + game controller
//
//  Pieces are rendered as a separate overlay layer (one view per physical piece,
//  keyed by a stable id) so a move animates the piece SLIDING from square to
//  square, captures fade + shrink out, and the selected piece lifts. The AI takes
//  a short, natural "thinking" pause before it moves.
//

import SwiftUI
import AppKit
import Combine
import MultipeerConnectivity

// MARK: - Controller

@MainActor
final class ChessGame: ObservableObject {
    enum Status: Equatable { case playing, checkmate(winner: ChessColor), stalemate, draw }
    enum Difficulty: String, CaseIterable, Identifiable {
        case easy, medium, hard
        var id: String { rawValue }
        var depth: Int { self == .easy ? 2 : self == .medium ? 3 : 4 }
        var label: String { rawValue.capitalized }
    }

    /// A physical piece the UI tracks across moves so it can animate sliding.
    struct BoardPiece: Identifiable, Equatable {
        let id = UUID()
        var kind: PieceKind
        var color: ChessColor
        var square: Int
        var captured = false
    }

    @Published private(set) var position = Position.initial
    @Published private(set) var renderPieces: [BoardPiece] = []
    @Published private(set) var status: Status = .playing
    @Published private(set) var selected: Int?
    @Published private(set) var legalTargets: Set<Int> = []
    @Published private(set) var lastMove: ChessMove?
    @Published private(set) var message = "Your move"
    @Published private(set) var thinking = false
    @Published var pendingPromotion: PendingPromotion?
    @Published var difficulty: Difficulty = .medium
    @Published private(set) var wins = 0
    @Published private(set) var losses = 0
    @Published private(set) var draws = 0

    struct PendingPromotion { let from: Int; let to: Int }

    // Multiplayer.
    enum Opponent { case ai, humanLive, humanCode }
    @Published private(set) var opponent: Opponent = .ai
    @Published private(set) var localColor: ChessColor = .white
    @Published private(set) var liveConnected = false
    @Published var opponentName = ""
    /// Set by the live (MultipeerConnectivity) transport to broadcast my moves.
    var onLocalMove: ((ChessMove) -> Void)?
    var humanColor: ChessColor { localColor }   // back-compat for the view

    private let defaults = UserDefaults.standard
    static let slide = Animation.spring(response: 0.38, dampingFraction: 0.78)

    var canLocalMove: Bool {
        guard status == .playing, !thinking, pendingPromotion == nil else { return false }
        switch opponent {
        case .ai:        return position.side == localColor
        case .humanLive: return liveConnected && position.side == localColor
        case .humanCode: return position.side == localColor
        }
    }
    var isMyTurn: Bool { position.side == localColor }

    init() {
        wins = defaults.integer(forKey: "notchly.chess.wins")
        losses = defaults.integer(forKey: "notchly.chess.losses")
        draws = defaults.integer(forKey: "notchly.chess.draws")
        rebuildPieces()
    }

    var inCheckSquare: Int? {
        position.isInCheck(position.side) ? position.kingSquare(position.side) : nil
    }

    func newGame() {
        position = .initial
        status = .playing
        selected = nil
        legalTargets = []
        lastMove = nil
        pendingPromotion = nil
        thinking = false
        message = "Your move"
        rebuildPieces()
    }

    func tap(_ sq: Int) {
        guard canLocalMove else { return }
        if let sel = selected {
            if sq == sel { clearSelection(); return }
            let candidates = legalFrom(sel).filter { $0.to == sq }
            if !candidates.isEmpty {
                if candidates.contains(where: { $0.isPromotion }) {
                    pendingPromotion = PendingPromotion(from: sel, to: sq)
                } else {
                    apply(candidates[0]); afterLocalMove(candidates[0])
                }
                clearSelection(); return
            }
        }
        if let p = position.squares[sq], p.color == localColor {
            selected = sq
            legalTargets = Set(legalFrom(sq).map { $0.to })
        } else {
            clearSelection()
        }
    }

    func completePromotion(_ kind: PieceKind) {
        guard let pp = pendingPromotion else { return }
        if let m = legalFrom(pp.from).first(where: { $0.to == pp.to && $0.promotion == kind }) {
            apply(m); afterLocalMove(m)
        }
        pendingPromotion = nil
    }

    private func legalFrom(_ sq: Int) -> [ChessMove] { position.legalMoves().filter { $0.from == sq } }
    private func clearSelection() { selected = nil; legalTargets = [] }

    // MARK: Applying + animating

    private func apply(_ m: ChessMove) {
        animateMove(m)                 // uses the pre-move position
        position = position.makeRaw(m)
        lastMove = m
        updateStatus()
        // Safety net: if the cosmetic layer ever drifts from the engine, snap it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in self?.reconcileIfNeeded() }
    }

    private func animateMove(_ m: ChessMove) {
        let mover = position.side   // side to move (pre-makeRaw)

        // Remove the captured piece (regular capture or en passant).
        if m.flag == .enPassant {
            let capSq = m.to + (mover == .white ? -8 : 8)
            fadeCapture(at: capSq)
        } else if renderPieces.contains(where: { $0.square == m.to && !$0.captured }) {
            fadeCapture(at: m.to)
        }

        // Slide the moving piece.
        if let mi = renderPieces.firstIndex(where: { $0.square == m.from && !$0.captured }) {
            let id = renderPieces[mi].id
            withAnimation(Self.slide) { renderPieces[mi].square = m.to }
            if let promo = m.promotion {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
                    guard let self, let i = self.renderPieces.firstIndex(where: { $0.id == id }) else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { self.renderPieces[i].kind = promo }
                }
            }
        }

        // Castling: slide the rook too.
        if m.flag == .castleKing || m.flag == .castleQueen {
            let (rf, rt): (Int, Int)
            switch m.to {
            case 6:  (rf, rt) = (7, 5)
            case 2:  (rf, rt) = (0, 3)
            case 62: (rf, rt) = (63, 61)
            default: (rf, rt) = (56, 59)   // 58
            }
            if let ri = renderPieces.firstIndex(where: { $0.square == rf && !$0.captured }) {
                withAnimation(Self.slide) { renderPieces[ri].square = rt }
            }
        }
    }

    private func fadeCapture(at square: Int) {
        guard let idx = renderPieces.firstIndex(where: { $0.square == square && !$0.captured }) else { return }
        let id = renderPieces[idx].id
        withAnimation(.easeOut(duration: 0.22)) { renderPieces[idx].captured = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            self?.renderPieces.removeAll { $0.id == id }
        }
    }

    private func rebuildPieces() {
        renderPieces = (0..<64).compactMap { sq in
            position.squares[sq].map { BoardPiece(kind: $0.kind, color: $0.color, square: sq) }
        }
    }

    private func reconcileIfNeeded() {
        let liveSquares = Set(renderPieces.filter { !$0.captured }.map { $0.square })
        let occupied = Set((0..<64).filter { position.squares[$0] != nil })
        if liveSquares != occupied { rebuildPieces() }
    }

    // MARK: AI

    private func afterLocalMove(_ m: ChessMove) {
        guard status == .playing else { return }
        switch opponent {
        case .ai:        triggerAI()
        case .humanLive: onLocalMove?(m)          // send to the connected peer
        case .humanCode: break                     // player copies the code manually
        }
    }

    // MARK: Multiplayer control

    func startAIGame() {
        opponent = .ai; localColor = .white; liveConnected = false; opponentName = ""
        newGame()
    }

    func startLiveGame(localColor: ChessColor, opponentName: String) {
        opponent = .humanLive
        self.localColor = localColor
        self.opponentName = opponentName
        liveConnected = true
        newGame()
    }

    func setLiveConnected(_ connected: Bool) {
        liveConnected = connected
        if !connected, opponent == .humanLive { message = "Opponent disconnected" }
    }

    /// Apply a move received from the live opponent (validated against the rules).
    func applyRemoteMove(_ m: ChessMove) {
        guard status == .playing,
              legalFrom(m.from).contains(where: { $0.to == m.to && $0.promotion == m.promotion })
        else { return }
        apply(m)
    }

    /// Play-by-code: the current position as a shareable code.
    func exportCode() -> String { position.toFEN() }

    /// Play-by-code: load a code pasted from the opponent — it becomes your turn.
    @discardableResult
    func importCode(_ code: String) -> Bool {
        guard let parsed = Position(fen: code.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        opponent = .humanCode
        liveConnected = false
        opponentName = "Remote"
        position = parsed
        localColor = parsed.side
        lastMove = nil
        clearSelection()
        pendingPromotion = nil
        thinking = false
        rebuildPieces()
        updateStatus()
        return true
    }

    private func triggerAI() {
        guard status == .playing, position.side != humanColor else { return }
        thinking = true
        message = "Thinking…"
        let pos = position
        let depth = difficulty.depth
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            let move = ChessAI.bestMove(for: pos, depth: depth)
            // A natural pause so the AI doesn't snap instantly.
            let minThink = Double.random(in: 0.55...1.0)
            let elapsed = Date().timeIntervalSince(t0)
            if elapsed < minThink {
                try? await Task.sleep(nanoseconds: UInt64((minThink - elapsed) * 1_000_000_000))
            }
            await MainActor.run {
                self.thinking = false
                if let move { self.apply(move) }
            }
        }
    }

    // MARK: Status

    private func updateStatus() {
        if position.isCheckmate {
            let winner = position.side.opposite
            status = .checkmate(winner: winner)
            if winner == localColor { wins += 1; message = "Checkmate — you win! 🏆" }
            else { losses += 1; message = "Checkmate — \(loserFacingWinnerName) wins." }
            persist()
        } else if position.isStalemate {
            status = .stalemate; draws += 1; message = "Stalemate — it's a draw."; persist()
        } else if position.halfmove >= 100 || position.isInsufficientMaterial {
            status = .draw; draws += 1; message = "Draw."; persist()
        } else if position.isInCheck(position.side) {
            message = isMyTurn ? "You're in check!" : "\(turnHolderName) is in check"
        } else if isMyTurn {
            message = "Your move"
        } else {
            switch opponent {
            case .ai:        message = "AI to move"
            case .humanLive: message = "Waiting for \(opponentName)…"
            case .humanCode: message = "Your move is ready — send the code"
            }
        }
    }

    private var turnHolderName: String {
        opponent == .ai ? "AI" : (opponentName.isEmpty ? "Opponent" : opponentName)
    }
    private var loserFacingWinnerName: String {
        opponent == .ai ? "the AI" : (opponentName.isEmpty ? "your opponent" : opponentName)
    }

    private func persist() {
        defaults.set(wins, forKey: "notchly.chess.wins")
        defaults.set(losses, forKey: "notchly.chess.losses")
        defaults.set(draws, forKey: "notchly.chess.draws")
    }
}

// MARK: - Piece view (crisp, outlined, shaded)

struct ChessPieceView: View {
    let kind: PieceKind
    let color: ChessColor
    let size: CGFloat

    private static let outlineOffsets: [CGSize] = {
        let d: CGFloat = 1.1
        return [(-d,-d),(0,-d),(d,-d),(-d,0),(d,0),(-d,d),(0,d),(d,d)].map { CGSize(width: $0.0, height: $0.1) }
    }()

    var body: some View {
        let isWhite = color == .white
        let bodyFill = LinearGradient(
            colors: isWhite ? [Color(white: 1.0), Color(white: 0.78)]
                            : [Color(white: 0.38), Color(white: 0.06)],
            startPoint: .top, endPoint: .bottom)
        let outline = isWhite ? Color.black.opacity(0.8) : Color(white: 0.85).opacity(0.55)

        ZStack {
            ForEach(0..<Self.outlineOffsets.count, id: \.self) { i in
                Text(kind.glyph).offset(Self.outlineOffsets[i]).foregroundStyle(outline)
            }
            Text(kind.glyph).foregroundStyle(bodyFill)
        }
        .font(.system(size: size))
        .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 2)
    }
}

// MARK: - Board view

struct ChessView: View {
    @ObservedObject var game: ChessGame
    @ObservedObject var multipeer: ChessMultipeer
    @ObservedObject var relay: ChessRelay
    @ObservedObject private var settings = NotchSettings.shared
    @State private var showMultiplayer = false
    @State private var joinCode = ""
    @State private var codeMessage: String?
    private let cell: CGFloat = 52
    private var board: CGFloat { cell * 8 }

    private let lightSquare = Color(red: 0.92, green: 0.93, blue: 0.82)
    private let darkSquare  = Color(red: 0.47, green: 0.58, blue: 0.34)

    var body: some View {
        VStack(spacing: 14) {
            header
            boardView
            footer
        }
        .padding(20)
        .frame(width: 460, height: 640, alignment: .top)
        .sheet(isPresented: $showMultiplayer) { multiplayerSheet }
        .alert("Chess invite", isPresented: inviteBinding, presenting: multipeer.incomingInvite) { invite in
            Button("Accept") { invite.respond(true); multipeer.incomingInvite = nil }
            Button("Decline", role: .cancel) { invite.respond(false); multipeer.incomingInvite = nil }
        } message: { invite in
            Text("\(invite.peerName) wants to play chess with you.")
        }
        .onChange(of: relay.phase) { _, phase in
            if phase == .connected { showMultiplayer = false }
        }
        .onChange(of: multipeer.connectedName) { _, name in
            if name != nil { showMultiplayer = false }
        }
    }

    private var inviteBinding: Binding<Bool> {
        Binding(
            get: { multipeer.incomingInvite != nil },
            set: { if !$0 { multipeer.incomingInvite?.respond(false); multipeer.incomingInvite = nil } }
        )
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Chess").font(.system(.title2, design: .rounded).weight(.black)).foregroundStyle(.white)
                if game.opponent == .ai {
                    Text("W \(game.wins) · L \(game.losses) · D \(game.draws)")
                        .font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                } else {
                    Text("vs \(game.opponentName.isEmpty ? "opponent" : game.opponentName) · you're \(game.localColor == .white ? "White" : "Black")")
                        .font(.system(size: 10, design: .rounded)).foregroundStyle(.cyan.opacity(0.8))
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if game.thinking { ProgressView().controlSize(.small).tint(.white) }
                Text(game.message)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(statusTint)
                    .animation(.easeInOut, value: game.message)
                Button { showMultiplayer = true } label: {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(game.opponent == .ai ? .white.opacity(0.6) : .cyan)
                }
                .buttonStyle(.plain)
                .help("Multiplayer")
            }
        }
        .frame(width: board)
    }

    // MARK: Multiplayer sheet

    private var multiplayerSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Multiplayer chess").font(.system(.title2, design: .rounded).weight(.bold))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Your name").font(.headline)
                    TextField("Name others see", text: $settings.multiplayerName)
                        .textFieldStyle(.roundedBorder)
                }

                Divider()

                // Option A — nearby
                VStack(alignment: .leading, spacing: 8) {
                    Text("Play someone nearby").font(.headline)
                    Text("Both Macs must be on the same Wi-Fi / network.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Available to nearby players", isOn: Binding(
                        get: { multipeer.online },
                        set: { $0 ? multipeer.goOnline() : multipeer.goOffline() }))
                    Text(multipeer.statusText).font(.caption).foregroundStyle(.secondary)
                    if multipeer.online {
                        if multipeer.nearby.isEmpty {
                            Text("Searching for players…").font(.caption).foregroundStyle(.tertiary)
                        } else {
                            ForEach(multipeer.nearby, id: \.self) { peer in
                                HStack {
                                    Image(systemName: "person.crop.circle.fill").foregroundStyle(.cyan)
                                    Text(peer.displayName)
                                    Spacer()
                                    Button("Invite") { multipeer.invite(peer) }
                                        .buttonStyle(.borderedProminent).controlSize(.small)
                                }
                            }
                        }
                    }
                }

                Divider()

                // Option B — online via a one-time room code
                VStack(alignment: .leading, spacing: 8) {
                    Text("Play online (room code)").font(.headline)
                    Text("One code to join the same game, then play live over the internet — anywhere. (Uses a free public relay; a random code is your privacy.)")
                        .font(.caption).foregroundStyle(.secondary)

                    switch relay.phase {
                    case .idle:
                        Button { _ = relay.host(name: settings.multiplayerName) } label: {
                            Label("Create a game", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        HStack {
                            TextField("Enter a friend's code", text: $joinCode)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { joinRoom() }
                            Button("Join") { joinRoom() }
                                .disabled(joinCode.trimmingCharacters(in: .whitespaces).count != 5)
                        }

                    case .hosting:
                        if let code = relay.roomCode {
                            HStack(spacing: 10) {
                                Text(code)
                                    .font(.system(size: 30, weight: .black, design: .monospaced))
                                    .foregroundStyle(.cyan)
                                Button { copyRoomCode(code) } label: { Image(systemName: "doc.on.doc") }
                            }
                        }
                        Text(relay.statusText).font(.caption).foregroundStyle(.secondary)
                        ProgressView().controlSize(.small)
                        Button("Cancel") { relay.leave() }

                    case .joining:
                        Text(relay.statusText).font(.caption).foregroundStyle(.secondary)
                        ProgressView().controlSize(.small)
                        Button("Cancel") { relay.leave() }

                    case .connected:
                        Label("Playing \(relay.opponentName)", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                        Button("Leave game") { relay.leave(); game.startAIGame() }
                    }

                    if let m = codeMessage {
                        Text(m).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack {
                    Button("Back to solo (vs AI)") { game.startAIGame(); codeMessage = nil }
                    Spacer()
                    Button("Done") { showMultiplayer = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 420)
        }
        .frame(width: 420, height: 560)
    }

    private func joinRoom() {
        let code = joinCode.trimmingCharacters(in: .whitespaces)
        guard code.count == 5 else { return }
        relay.join(code: code, name: settings.multiplayerName)
    }

    private func copyRoomCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        codeMessage = "Code copied — send it to your friend."
    }

    private var boardView: some View {
        ZStack(alignment: .topLeading) {
            squaresGrid
            piecesLayer.allowsHitTesting(false)
        }
        .frame(width: board, height: board)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .overlay(alignment: .center) { promotionOverlay }
    }

    private var squaresGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { col in
                        squareCell(rank: 7 - row, file: col)
                    }
                }
            }
        }
    }

    private func squareCell(rank: Int, file: Int) -> some View {
        let sq = rank * 8 + file
        let isLight = (rank + file) % 2 == 1
        let isTarget = game.legalTargets.contains(sq)
        let isLast = game.lastMove.map { $0.from == sq || $0.to == sq } ?? false
        let occupied = game.position.squares[sq] != nil

        return ZStack {
            (isLight ? lightSquare : darkSquare)
            if isLast { Color.yellow.opacity(0.30) }
            if game.selected == sq { Color.yellow.opacity(0.45) }
            if game.inCheckSquare == sq {
                Circle().fill(RadialGradient(colors: [.red.opacity(0.85), .red.opacity(0.0)],
                                             center: .center, startRadius: 2, endRadius: cell * 0.6))
            }
            if isTarget {
                if occupied {
                    Circle().strokeBorder(.black.opacity(0.32), lineWidth: 5).padding(3)
                        .transition(.opacity)
                } else {
                    Circle().fill(.black.opacity(0.24)).frame(width: 16, height: 16)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .frame(width: cell, height: cell)
        .contentShape(Rectangle())
        .onTapGesture { game.tap(sq) }
        .animation(.easeInOut(duration: 0.15), value: game.legalTargets)
    }

    private var piecesLayer: some View {
        ZStack {
            ForEach(game.renderPieces) { piece in
                ChessPieceView(kind: piece.kind, color: piece.color, size: 38)
                    .scaleEffect(piece.captured ? 0.4 : (game.selected == piece.square ? 1.16 : 1.0))
                    .opacity(piece.captured ? 0 : 1)
                    .position(x: (CGFloat(piece.square & 7) + 0.5) * cell,
                              y: (CGFloat(7 - (piece.square >> 3)) + 0.5) * cell)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: game.selected)
            }
        }
        .frame(width: board, height: board)
    }

    @ViewBuilder
    private var promotionOverlay: some View {
        if game.pendingPromotion != nil {
            VStack(spacing: 10) {
                Text("Promote to").font(.system(.headline, design: .rounded).weight(.bold)).foregroundStyle(.white)
                HStack(spacing: 10) {
                    ForEach([PieceKind.queen, .rook, .bishop, .knight], id: \.rawValue) { kind in
                        Button { game.completePromotion(kind) } label: {
                            ChessPieceView(kind: kind, color: game.humanColor, size: 34)
                                .frame(width: 52, height: 52)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.85)))
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Picker("Level", selection: $game.difficulty) {
                ForEach(ChessGame.Difficulty.allCases) { d in Text(d.label).tag(d) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .disabled(game.thinking || game.opponent != .ai)
            .opacity(game.opponent == .ai ? 1 : 0.4)

            Spacer()

            Button { game.startAIGame() } label: {
                Label(game.opponent == .ai ? "New game" : "Leave · new game", systemImage: "arrow.clockwise")
                    .font(.system(.callout, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.blue))
            }
            .buttonStyle(.plain)
        }
        .frame(width: board)
    }

    private var statusTint: Color {
        switch game.status {
        case .checkmate(let w): return w == game.humanColor ? .green : .red
        case .stalemate, .draw: return .orange
        case .playing: return game.inCheckSquare != nil ? .orange : .white.opacity(0.8)
        }
    }
}

// MARK: - Window presenter

@MainActor
enum ChessWindowPresenter {
    private static var window: NSWindow?
    private static let game = ChessGame()
    private static var multipeer: ChessMultipeer?
    private static let relay = ChessRelay()

    static func show() {
        if multipeer == nil {
            let mp = ChessMultipeer(displayName: NotchSettings.shared.multiplayerName)
            mp.game = game
            multipeer = mp
        }
        relay.game = game
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = GameWindow.make(title: "Chess", design: CGSize(width: 460, height: 640)) {
            ChessView(game: game, multipeer: multipeer!, relay: relay)
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
