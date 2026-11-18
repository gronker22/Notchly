//
//  PokerLobbyView.swift
//  Notchly — multiplayer poker lobby
//
//  Host a table or join one, over the local network or with a room code, then
//  choose how many seats and whether to fill the empty ones with bots. Leaving
//  bots off and the table at 2 is heads-up.
//

import SwiftUI
import AppKit
import MultipeerConnectivity

struct PokerLobbyView: View {
    @ObservedObject var session: PokerSession
    @ObservedObject private var settings = NotchSettings.shared
    var onStart: () -> Void
    var onClose: () -> Void

    @State private var joinCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if session.role == .offline {
                nameField
                modeChoices
            } else {
                lobbyBody
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Color(red: 0.07, green: 0.12, blue: 0.09))
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.2.fill")
                .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.55))
            Text("Play with friends")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                session.leave()
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("YOUR NAME")
                .font(.system(size: 9, design: .rounded).weight(.bold))
                .foregroundStyle(.white.opacity(0.45))
                .kerning(0.5)
            TextField("Name others see", text: $settings.multiplayerName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var modeChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            tableOptions

            Divider().overlay(.white.opacity(0.1))

            Text("SAME WI-FI")
                .font(.system(size: 9, design: .rounded).weight(.bold))
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 10) {
                bigButton("Host a table", "antenna.radiowaves.left.and.right",
                          fill: true) { session.hostNearby() }
                bigButton("Find a table", "magnifyingglass") { session.browseNearby() }
            }

            Divider().overlay(.white.opacity(0.1))

            Text("ROOM CODE — ANY NETWORK")
                .font(.system(size: 9, design: .rounded).weight(.bold))
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 10) {
                bigButton("Create a code", "plus.circle.fill", fill: true) {
                    session.hostRoomCode()
                }
                HStack(spacing: 6) {
                    TextField("Code", text: $joinCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 92)
                    Button("Join") { session.joinRoomCode(joinCode) }
                        .disabled(joinCode.trimmingCharacters(in: .whitespaces).count < 4)
                }
            }
        }
    }

    private var tableOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper("Seats at the table: \(session.tableSize)",
                    value: $session.tableSize, in: 2...6)
                .foregroundStyle(.white)
            Toggle("Fill empty seats with bots", isOn: $session.fillWithBots)
                .toggleStyle(.switch)
                .tint(Color(red: 0.30, green: 0.80, blue: 0.46))
                .foregroundStyle(.white)
            Text(session.fillWithBots
                 ? "Empty seats are filled with AI so the table always plays a full game."
                 : "Real players only — the hand waits until everyone has joined.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var lobbyBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let code = session.roomCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ROOM CODE")
                        .font(.system(size: 9, design: .rounded).weight(.bold))
                        .foregroundStyle(.white.opacity(0.45))
                    HStack(spacing: 10) {
                        Text(code)
                            .font(.system(size: 30, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .kerning(4)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Copy")
                    }
                }
            }

            if !session.status.isEmpty {
                Text(session.status)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
            }

            // Guests browsing for a nearby host.
            if session.role == .guest, !session.nearbyHosts.isEmpty, !session.started {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TABLES NEARBY")
                        .font(.system(size: 9, design: .rounded).weight(.bold))
                        .foregroundStyle(.white.opacity(0.45))
                    ForEach(session.nearbyHosts, id: \.self) { peer in
                        HStack {
                            Text(peer.displayName).foregroundStyle(.white)
                            Spacer()
                            Button("Join") { session.joinNearby(peer) }
                        }
                    }
                }
            }

            if !session.seats.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SEATED")
                        .font(.system(size: 9, design: .rounded).weight(.bold))
                        .foregroundStyle(.white.opacity(0.45))
                    ForEach(session.seats) { seat in
                        HStack(spacing: 8) {
                            Image(systemName: seat.isBot ? "cpu" : "person.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(seat.isBot
                                                 ? .white.opacity(0.4)
                                                 : Color(red: 0.35, green: 0.85, blue: 0.55))
                            Text(seat.name).foregroundStyle(.white)
                            if seat.id == session.myID {
                                Text("you")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            Spacer()
                        }
                    }
                }
            }

            if session.role == .host {
                let humans = session.seats.filter { !$0.isBot }.count
                let ready = session.fillWithBots ? humans >= 1 : humans >= 2
                Button {
                    session.begin()
                    onStart()
                } label: {
                    Text(ready ? "Deal" : "Waiting for another player…")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(ready
                            ? Color(red: 0.35, green: 0.85, blue: 0.55)
                            : Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .disabled(!ready)
            } else if session.started {
                Text("Game in progress")
                    .foregroundStyle(.white.opacity(0.6))
            }

            Button("Leave table") {
                session.leave()
                onClose()
            }
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func bigButton(_ title: String, _ icon: String, fill: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(fill ? .black : .white.opacity(0.9))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(fill
                ? AnyShapeStyle(Color(red: 0.35, green: 0.85, blue: 0.55))
                : AnyShapeStyle(Color.white.opacity(0.14))))
        }
        .buttonStyle(.plain)
    }
}
