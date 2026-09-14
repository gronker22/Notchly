//
//  ChessGame.swift
//  Notchly — Chess
//
//  A from-scratch legal chess engine (all rules: castling, en passant,
//  promotion, check / checkmate / stalemate, 50-move & insufficient-material
//  draws) plus an alpha-beta negamax AI with material + piece-square-table
//  evaluation. You play White; the AI plays Black. The search runs off the main
//  actor on an immutable `Position` value so the UI never blocks.
//

import Foundation
import Combine

// MARK: - Core types

enum ChessColor: Sendable { case white, black; var opposite: ChessColor { self == .white ? .black : .white } }

enum PieceKind: Int, Sendable {
    case pawn, knight, bishop, rook, queen, king
    var value: Int { [100, 320, 330, 500, 900, 0][rawValue] }
    var glyph: String { ["♟", "♞", "♝", "♜", "♛", "♚"][rawValue] } // filled set, tinted per colour
    var letter: String { ["", "N", "B", "R", "Q", "K"][rawValue] }
}

struct ChessPiece: Sendable, Equatable {
    var color: ChessColor
    var kind: PieceKind
}

enum MoveFlag: Sendable, Equatable { case normal, doublePawn, enPassant, castleKing, castleQueen }

struct ChessMove: Sendable, Equatable {
    let from: Int
    let to: Int
    var promotion: PieceKind? = nil
    var flag: MoveFlag = .normal
    var isPromotion: Bool { promotion != nil }
}

// MARK: - Position (immutable value the search operates on)

struct Position: Sendable {
    var squares: [ChessPiece?]      // 64, index = rank*8 + file, rank 0 = white's home
    var side: ChessColor
    var castleWK = true, castleWQ = true, castleBK = true, castleBQ = true
    var epTarget: Int? = nil        // square a pawn may capture en passant into
    var halfmove = 0                // for the 50-move rule

    static func file(_ sq: Int) -> Int { sq & 7 }
    static func rank(_ sq: Int) -> Int { sq >> 3 }

    static let initial: Position = {
        var b = [ChessPiece?](repeating: nil, count: 64)
        let back: [PieceKind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for f in 0..<8 {
            b[f] = ChessPiece(color: .white, kind: back[f])
            b[8 + f] = ChessPiece(color: .white, kind: .pawn)
            b[48 + f] = ChessPiece(color: .black, kind: .pawn)
            b[56 + f] = ChessPiece(color: .black, kind: back[f])
        }
        return Position(squares: b, side: .white)
    }()

    func kingSquare(_ color: ChessColor) -> Int {
        squares.firstIndex { $0 == ChessPiece(color: color, kind: .king) } ?? -1
    }

    // MARK: Attacks

    /// Is `sq` attacked by any piece of `color`?
    func isAttacked(_ sq: Int, by color: ChessColor) -> Bool {
        let f = Self.file(sq), r = Self.rank(sq)

        // Pawn attacks (a `color` pawn attacks diagonally forward).
        let dr = color == .white ? 1 : -1
        for df in [-1, 1] {
            let af = f + df, ar = r - dr    // square the attacking pawn would sit on
            if af >= 0, af < 8, ar >= 0, ar < 8,
               squares[ar * 8 + af] == ChessPiece(color: color, kind: .pawn) { return true }
        }

        // Knight attacks.
        for (df, dr2) in [(1,2),(2,1),(2,-1),(1,-2),(-1,-2),(-2,-1),(-2,1),(-1,2)] {
            let af = f + df, ar = r + dr2
            if af >= 0, af < 8, ar >= 0, ar < 8,
               squares[ar * 8 + af] == ChessPiece(color: color, kind: .knight) { return true }
        }

        // King attacks (adjacent).
        for df in -1...1 {
            for dr2 in -1...1 where !(df == 0 && dr2 == 0) {
                let af = f + df, ar = r + dr2
                if af >= 0, af < 8, ar >= 0, ar < 8,
                   squares[ar * 8 + af] == ChessPiece(color: color, kind: .king) { return true }
            }
        }

        // Sliding: rook/queen (orthogonal), bishop/queen (diagonal).
        let ortho = [(1,0),(-1,0),(0,1),(0,-1)]
        let diag = [(1,1),(1,-1),(-1,1),(-1,-1)]
        for (dirs, kinds) in [(ortho, [PieceKind.rook, .queen]), (diag, [PieceKind.bishop, .queen])] {
            for (df, dr2) in dirs {
                var af = f + df, ar = r + dr2
                while af >= 0, af < 8, ar >= 0, ar < 8 {
                    if let p = squares[ar * 8 + af] {
                        if p.color == color, kinds.contains(p.kind) { return true }
                        break
                    }
                    af += df; ar += dr2
                }
            }
        }
        return false
    }

    func isInCheck(_ color: ChessColor) -> Bool {
        let k = kingSquare(color)
        return k >= 0 && isAttacked(k, by: color.opposite)
    }

    // MARK: Move generation

    /// Fully legal moves for the side to move.
    func legalMoves() -> [ChessMove] {
        pseudoMoves().filter { move in
            let next = makeRaw(move)
            return !next.isInCheck(side)
        }
    }

    private func pseudoMoves() -> [ChessMove] {
        var moves: [ChessMove] = []
        for sq in 0..<64 {
            guard let p = squares[sq], p.color == side else { continue }
            let f = Self.file(sq), r = Self.rank(sq)
            switch p.kind {
            case .pawn:   pawnMoves(sq, f, r, &moves)
            case .knight: stepMoves(sq, f, r, [(1,2),(2,1),(2,-1),(1,-2),(-1,-2),(-2,-1),(-2,1),(-1,2)], &moves)
            case .king:   kingMoves(sq, f, r, &moves)
            case .bishop: slideMoves(sq, f, r, [(1,1),(1,-1),(-1,1),(-1,-1)], &moves)
            case .rook:   slideMoves(sq, f, r, [(1,0),(-1,0),(0,1),(0,-1)], &moves)
            case .queen:  slideMoves(sq, f, r, [(1,0),(-1,0),(0,1),(0,-1),(1,1),(1,-1),(-1,1),(-1,-1)], &moves)
            }
        }
        return moves
    }

    private func pawnMoves(_ sq: Int, _ f: Int, _ r: Int, _ moves: inout [ChessMove]) {
        let dr = side == .white ? 1 : -1
        let startRank = side == .white ? 1 : 6
        let promoRank = side == .white ? 7 : 0
        let oneR = r + dr

        // Forward one.
        if oneR >= 0, oneR < 8, squares[oneR * 8 + f] == nil {
            addPawn(sq, oneR * 8 + f, promoRank, .normal, &moves)
            // Forward two.
            if r == startRank, squares[(r + 2 * dr) * 8 + f] == nil {
                moves.append(ChessMove(from: sq, to: (r + 2 * dr) * 8 + f, flag: .doublePawn))
            }
        }
        // Captures + en passant.
        for df in [-1, 1] {
            let cf = f + df
            guard cf >= 0, cf < 8, oneR >= 0, oneR < 8 else { continue }
            let target = oneR * 8 + cf
            if let cap = squares[target], cap.color != side {
                addPawn(sq, target, promoRank, .normal, &moves)
            } else if epTarget == target {
                moves.append(ChessMove(from: sq, to: target, flag: .enPassant))
            }
        }
    }

    private func addPawn(_ from: Int, _ to: Int, _ promoRank: Int, _ flag: MoveFlag, _ moves: inout [ChessMove]) {
        if Self.rank(to) == promoRank {
            for k in [PieceKind.queen, .rook, .bishop, .knight] {
                moves.append(ChessMove(from: from, to: to, promotion: k, flag: flag))
            }
        } else {
            moves.append(ChessMove(from: from, to: to, flag: flag))
        }
    }

    private func stepMoves(_ sq: Int, _ f: Int, _ r: Int, _ offs: [(Int, Int)], _ moves: inout [ChessMove]) {
        for (df, dr) in offs {
            let af = f + df, ar = r + dr
            guard af >= 0, af < 8, ar >= 0, ar < 8 else { continue }
            let t = ar * 8 + af
            if let p = squares[t], p.color == side { continue }
            moves.append(ChessMove(from: sq, to: t))
        }
    }

    private func slideMoves(_ sq: Int, _ f: Int, _ r: Int, _ dirs: [(Int, Int)], _ moves: inout [ChessMove]) {
        for (df, dr) in dirs {
            var af = f + df, ar = r + dr
            while af >= 0, af < 8, ar >= 0, ar < 8 {
                let t = ar * 8 + af
                if let p = squares[t] {
                    if p.color != side { moves.append(ChessMove(from: sq, to: t)) }
                    break
                }
                moves.append(ChessMove(from: sq, to: t))
                af += df; ar += dr
            }
        }
    }

    private func kingMoves(_ sq: Int, _ f: Int, _ r: Int, _ moves: inout [ChessMove]) {
        for df in -1...1 {
            for dr in -1...1 where !(df == 0 && dr == 0) {
                let af = f + df, ar = r + dr
                guard af >= 0, af < 8, ar >= 0, ar < 8 else { continue }
                let t = ar * 8 + af
                if let p = squares[t], p.color == side { continue }
                moves.append(ChessMove(from: sq, to: t))
            }
        }
        // Castling: king not in check, squares empty, and it doesn't pass through
        // or land on an attacked square.
        let opp = side.opposite
        if side == .white, sq == 4, !isAttacked(4, by: opp) {
            if castleWK, squares[5] == nil, squares[6] == nil,
               !isAttacked(5, by: opp), !isAttacked(6, by: opp),
               squares[7] == ChessPiece(color: .white, kind: .rook) {
                moves.append(ChessMove(from: 4, to: 6, flag: .castleKing))
            }
            if castleWQ, squares[3] == nil, squares[2] == nil, squares[1] == nil,
               !isAttacked(3, by: opp), !isAttacked(2, by: opp),
               squares[0] == ChessPiece(color: .white, kind: .rook) {
                moves.append(ChessMove(from: 4, to: 2, flag: .castleQueen))
            }
        } else if side == .black, sq == 60, !isAttacked(60, by: opp) {
            if castleBK, squares[61] == nil, squares[62] == nil,
               !isAttacked(61, by: opp), !isAttacked(62, by: opp),
               squares[63] == ChessPiece(color: .black, kind: .rook) {
                moves.append(ChessMove(from: 60, to: 62, flag: .castleKing))
            }
            if castleBQ, squares[59] == nil, squares[58] == nil, squares[57] == nil,
               !isAttacked(59, by: opp), !isAttacked(58, by: opp),
               squares[56] == ChessPiece(color: .black, kind: .rook) {
                moves.append(ChessMove(from: 60, to: 58, flag: .castleQueen))
            }
        }
    }

    // MARK: Applying a move

    /// Applies a move without legality checking (used by the generator + search).
    func makeRaw(_ m: ChessMove) -> Position {
        var next = self
        let moving = squares[m.from]!
        next.squares[m.from] = nil
        let isCapture = squares[m.to] != nil || m.flag == .enPassant
        next.epTarget = nil

        switch m.flag {
        case .enPassant:
            next.squares[m.to] = moving
            let capturedPawn = m.to + (side == .white ? -8 : 8)
            next.squares[capturedPawn] = nil
        case .castleKing:
            next.squares[m.to] = moving
            let rookFrom = side == .white ? 7 : 63
            let rookTo = side == .white ? 5 : 61
            next.squares[rookTo] = next.squares[rookFrom]
            next.squares[rookFrom] = nil
        case .castleQueen:
            next.squares[m.to] = moving
            let rookFrom = side == .white ? 0 : 56
            let rookTo = side == .white ? 3 : 59
            next.squares[rookTo] = next.squares[rookFrom]
            next.squares[rookFrom] = nil
        case .doublePawn:
            next.squares[m.to] = moving
            next.epTarget = (m.from + m.to) / 2
        case .normal:
            if let promo = m.promotion {
                next.squares[m.to] = ChessPiece(color: side, kind: promo)
            } else {
                next.squares[m.to] = moving
            }
        }

        // Update castling rights.
        func clearIf(_ sq: Int) {
            if sq == 4 { next.castleWK = false; next.castleWQ = false }
            if sq == 60 { next.castleBK = false; next.castleBQ = false }
            if sq == 0 || m.to == 0 { next.castleWQ = false }
            if sq == 7 || m.to == 7 { next.castleWK = false }
            if sq == 56 || m.to == 56 { next.castleBQ = false }
            if sq == 63 || m.to == 63 { next.castleBK = false }
        }
        clearIf(m.from)
        clearIf(m.to)

        next.halfmove = (moving.kind == .pawn || isCapture) ? 0 : halfmove + 1
        next.side = side.opposite
        return next
    }

    // MARK: End states

    var isCheckmate: Bool { legalMoves().isEmpty && isInCheck(side) }
    var isStalemate: Bool { legalMoves().isEmpty && !isInCheck(side) }

    var isInsufficientMaterial: Bool {
        var minors = 0
        for p in squares.compactMap({ $0 }) {
            switch p.kind {
            case .king: continue
            case .knight, .bishop: minors += 1
            default: return false   // any pawn/rook/queen → sufficient
            }
        }
        return minors <= 1   // K vs K, or K+one minor vs K
    }
}

// MARK: - AI (alpha-beta negamax, off the main actor)

enum ChessAI {
    private static let INF = 1_000_000
    private static let MATE = 100_000

    // Piece-square tables in a8→h1 reading order (index 0 = a8).
    private static let pst: [PieceKind: [Int]] = [
        .pawn: [ 0,0,0,0,0,0,0,0, 50,50,50,50,50,50,50,50, 10,10,20,30,30,20,10,10,
                 5,5,10,25,25,10,5,5, 0,0,0,20,20,0,0,0, 5,-5,-10,0,0,-10,-5,5,
                 5,10,10,-20,-20,10,10,5, 0,0,0,0,0,0,0,0 ],
        .knight: [ -50,-40,-30,-30,-30,-30,-40,-50, -40,-20,0,0,0,0,-20,-40,
                   -30,0,10,15,15,10,0,-30, -30,5,15,20,20,15,5,-30,
                   -30,0,15,20,20,15,0,-30, -30,5,10,15,15,10,5,-30,
                   -40,-20,0,5,5,0,-20,-40, -50,-40,-30,-30,-30,-30,-40,-50 ],
        .bishop: [ -20,-10,-10,-10,-10,-10,-10,-20, -10,0,0,0,0,0,0,-10,
                   -10,0,5,10,10,5,0,-10, -10,5,5,10,10,5,5,-10,
                   -10,0,10,10,10,10,0,-10, -10,10,10,10,10,10,10,-10,
                   -10,5,0,0,0,0,5,-10, -20,-10,-10,-10,-10,-10,-10,-20 ],
        .rook: [ 0,0,0,0,0,0,0,0, 5,10,10,10,10,10,10,5, -5,0,0,0,0,0,0,-5,
                 -5,0,0,0,0,0,0,-5, -5,0,0,0,0,0,0,-5, -5,0,0,0,0,0,0,-5,
                 -5,0,0,0,0,0,0,-5, 0,0,0,5,5,0,0,0 ],
        .queen: [ -20,-10,-10,-5,-5,-10,-10,-20, -10,0,0,0,0,0,0,-10, -10,0,5,5,5,5,0,-10,
                  -5,0,5,5,5,5,0,-5, 0,0,5,5,5,5,0,-5, -10,5,5,5,5,5,0,-10,
                  -10,0,5,0,0,0,0,-10, -20,-10,-10,-5,-5,-10,-10,-20 ],
        .king: [ -30,-40,-40,-50,-50,-40,-40,-30, -30,-40,-40,-50,-50,-40,-40,-30,
                 -30,-40,-40,-50,-50,-40,-40,-30, -30,-40,-40,-50,-50,-40,-40,-30,
                 -20,-30,-30,-40,-40,-30,-30,-20, -10,-20,-20,-20,-20,-20,-20,-10,
                 20,20,0,0,0,0,20,20, 20,30,10,0,0,10,30,20 ]
    ]

    private static func pstValue(_ kind: PieceKind, _ sq: Int, _ color: ChessColor) -> Int {
        let f = Position.file(sq), r = Position.rank(sq)
        let idx = color == .white ? (7 - r) * 8 + f : r * 8 + f
        return pst[kind]![idx]
    }

    /// Static eval from White's perspective (+ = White better).
    private static func evaluateWhite(_ pos: Position) -> Int {
        var score = 0
        for sq in 0..<64 {
            guard let p = pos.squares[sq] else { continue }
            let v = p.kind.value + pstValue(p.kind, sq, p.color)
            score += p.color == .white ? v : -v
        }
        return score
    }

    private static func orderedMoves(_ pos: Position) -> [ChessMove] {
        pos.legalMoves().sorted { a, b in captureScore(pos, a) > captureScore(pos, b) }
    }

    private static func captureScore(_ pos: Position, _ m: ChessMove) -> Int {
        var s = 0
        if let victim = pos.squares[m.to] { s += victim.kind.value * 10 - (pos.squares[m.from]?.kind.value ?? 0) }
        if let promo = m.promotion { s += promo.value }
        return s
    }

    private static func negamax(_ pos: Position, _ depth: Int, _ alpha0: Int, _ beta: Int, _ ply: Int) -> Int {
        var alpha = alpha0
        let moves = orderedMoves(pos)
        if moves.isEmpty {
            return pos.isInCheck(pos.side) ? -(MATE - ply) : 0   // mate (prefer sooner) or stalemate
        }
        if depth == 0 {
            let w = evaluateWhite(pos)
            return pos.side == .white ? w : -w
        }
        var best = -INF
        for m in moves {
            let score = -negamax(pos.makeRaw(m), depth - 1, -beta, -alpha, ply + 1)
            if score > best { best = score }
            if best > alpha { alpha = best }
            if alpha >= beta { break }
        }
        return best
    }

    /// Best move for the side to move at the given search depth.
    static func bestMove(for pos: Position, depth: Int) -> ChessMove? {
        var best: ChessMove?
        var bestScore = -INF
        var alpha = -INF
        for m in orderedMoves(pos) {
            let score = -negamax(pos.makeRaw(m), depth - 1, -INF, -alpha, 1)
            if score > bestScore { bestScore = score; best = m }
            if score > alpha { alpha = score }
        }
        return best
    }
}
