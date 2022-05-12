//
//  DiscordGateway.swift
//  Native Discord
//
//  Created by Vincent Kwok on 20/2/22.
//

import Foundation
import os
import SwiftUI

class DiscordGateway: ObservableObject {
    // Events
    let onEvent = EventDispatch<(GatewayEvent, GatewayData?)>()
    let onAuthFailure = EventDispatch<Void>()
    
    // WebSocket object
    @Published public var socket: RobustWebSocket!
    
    // State cache
    @Published var cache: CachedState = CachedState()
    
    private var evtListenerID: EventDispatch.HandlerIdentifier? = nil,
                authFailureListenerID: EventDispatch.HandlerIdentifier? = nil,
                connStateChangeListenerID: EventDispatch.HandlerIdentifier? = nil
    
    @Published var connected = false
    @Published var reachable = false
    
    // Logger
    private let log = Logger(category: "DiscordGateway")
    
    public func logout() {
        log.debug("Logging out on request")
        
        // Remove token from the keychain
        let _ = Keychain.remove(key: "token")
        // Reset user defaults
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        // Clear cache
        cache = CachedState()
        
        socket.close(code: .normalClosure)
        onAuthFailure.notify()
    }
    
    public func connect() {
        socket.open()
    }
    
    private func handleEvt(type: GatewayEvent, data: GatewayData?) {
        switch (type) {
        case .ready:
            guard let d = data as? ReadyEvt else { return }
            
            // Populate cache with data sent in ready event
            self.cache.guilds = (d.guilds
                .filter({ g in !d.user_settings.guild_positions.contains(g.id) })
                .sorted(by: { lhs, rhs in lhs.joined_at! > rhs.joined_at! }))
            + d.user_settings.guild_positions.map({ id in d.guilds.first { g in g.id == id }! })
            self.cache.dms = d.private_channels
            self.cache.user = d.user
            self.cache.users = d.users
            
            log.info("Gateway ready")
        case .guildCreate:
            guard let d = data as? Guild else { return }
            self.cache.guilds?.insert(d, at: 0) // As per official Discord implementation
        case .guildDelete:
            guard let d = data as? GuildUnavailable else { return }
            self.cache.guilds?.removeAll { g in g.id == d.id }
        case .userUpdate:
            guard let updatedUser = data as? User else { return }
            self.cache.user = updatedUser
        default: break
        }
        onEvent.notify(event: (type, data))
        log.info("Dispatched event <\(type.rawValue, privacy: .public)>")
    }
    
    init(connectionTimeout: Double = 5, maxMissedACK: Int = 3) {
        socket = RobustWebSocket()
        evtListenerID = socket.onEvent.addHandler { [weak self] (t, d) in
            self?.handleEvt(type: t, data: d)
        }
        authFailureListenerID = socket.onAuthFailure.addHandler { [weak self] in
            self?.onAuthFailure.notify()
        }
        connStateChangeListenerID = socket.onConnStateChange.addHandler { [weak self] (c, r) in
            withAnimation {
                self?.connected = c
                self?.reachable = r
            }
        }
    }
    
    deinit {
        if let evtListenerID = evtListenerID {
            let _ = socket.onEvent.removeHandler(handler: evtListenerID)
        }
        if let authFailureListenerID = authFailureListenerID {
            let _ = socket.onAuthFailure.removeHandler(handler: authFailureListenerID)
        }
        if let connStateChangeListenerID = connStateChangeListenerID {
            let _ = socket.onConnStateChange.removeHandler(handler: connStateChangeListenerID)
        }
    }
}
