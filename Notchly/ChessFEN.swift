//
//  ChessFEN.swift
//  Notchly — FEN (Forsyth–Edwards Notation) for chess positions.
//
//  A whole game position packs into one short line like
//  "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1".
//  This is the "game code" players copy/paste (Option B) and the sync payload
//  sent over the network (Option A).
//

import Foundation

extension Position {

    /// Serialize the position to a FEN string.
    func toFEN() -> String {
        var rows: [String] = []
        for r in stride(from: 7, through: 0, by: -1) {
            var row = ""
            var empty = 0
            for f in 0..<8 {
                if let p = squares[r * 8 + f] {
                    if empty > 0 { row += String(empty); empty = 0 }
                    row += Self.letter(for: p)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { row += String(empty) }
            rows.append(row)
        }
        let board = rows.joined(separator: "/")
        let stm = side == .white ? "w" : "b"
        var castle = ""
        if castleWK { castle += "K" }
        if castleWQ { castle += "Q" }
        if castleBK { castle += "k" }
        if castleBQ { castle += "q" }
        if castle.isEmpty { castle = "-" }
        let ep = epTarget.map { Self.algebraic($0) } ?? "-"
        return "\(board) \(stm) \(castle) \(ep) \(halfmove) 1"
    }

    /// Parse a FEN string. Returns nil if malformed.
    init?(fen: String) {
        let parts = fen.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4 else { return nil }

        var board = [ChessPiece?](repeating: nil, count: 64)
        let rows = parts[0].split(separator: "/").map(String.init)
        guard rows.count == 8 else { return nil }
        for (i, row) in rows.enumerated() {
            let r = 7 - i
            var f = 0
            for ch in row {
                if ch.isNumber, let d = ch.wholeNumberValue {
                    f += d
                } else {
                    guard f < 8, let piece = Self.piece(from: ch) else { return nil }
                    board[r * 8 + f] = piece
                    f += 1
                }
            }
            guard f == 8 else { return nil }
        }

        self.squares = board
        self.side = parts[1] == "b" ? .black : .white
        let c = parts[2]
        self.castleWK = c.contains("K")
        self.castleWQ = c.contains("Q")
        self.castleBK = c.contains("k")
        self.castleBQ = c.contains("q")
        self.epTarget = parts[3] == "-" ? nil : Self.square(from: parts[3])
        self.halfmove = parts.count > 4 ? (Int(parts[4]) ?? 0) : 0
    }

    // MARK: Helpers

    private static func letter(for p: ChessPiece) -> String {
        let base: String
        switch p.kind {
        case .pawn: base = "p"
        case .knight: base = "n"
        case .bishop: base = "b"
        case .rook: base = "r"
        case .queen: base = "q"
        case .king: base = "k"
        }
        return p.color == .white ? base.uppercased() : base
    }

    private static func piece(from ch: Character) -> ChessPiece? {
        let color: ChessColor = ch.isUppercase ? .white : .black
        let kind: PieceKind
        switch Character(ch.lowercased()) {
        case "p": kind = .pawn
        case "n": kind = .knight
        case "b": kind = .bishop
        case "r": kind = .rook
        case "q": kind = .queen
        case "k": kind = .king
        default: return nil
        }
        return ChessPiece(color: color, kind: kind)
    }

    private static func algebraic(_ sq: Int) -> String {
        let file = Character(UnicodeScalar(UInt8(97 + (sq & 7))))
        return "\(file)\((sq >> 3) + 1)"
    }

    private static func square(from s: String) -> Int? {
        guard s.count == 2 else { return nil }
        let chars = Array(s)
        guard let fileAscii = chars[0].asciiValue, let rank = chars[1].wholeNumberValue else { return nil }
        let file = Int(fileAscii) - 97
        guard file >= 0, file < 8, rank >= 1, rank <= 8 else { return nil }
        return (rank - 1) * 8 + file
    }
}
