//
//  ServerView.swift
//  Swiftcord
//
//  Created by Vincent Kwok on 23/2/22.
//

import SwiftUI
import DiscordKit

class ServerContext: ObservableObject {
    @Published public var channel: Channel?
    @Published public var guild: Guild?
    @Published public var typingStarted: [Snowflake: [TypingStart]] = [:]
	@Published public var roles: [Role] = []
}

struct ServerView: View, Equatable {
	let guild: Guild?
    @State private var evtID: EventDispatch.HandlerIdentifier?
    @State private var mediaCenterOpen: Bool = false

    @EnvironmentObject var state: UIState
    @EnvironmentObject var gateway: DiscordGateway
    @EnvironmentObject var audioManager: AudioCenterManager

    @StateObject private var serverCtx = ServerContext()

	private func loadChannels() {
		guard let channels = serverCtx.guild?.channels?.discordSorted()
		else { return }

		if let lastChannel = UserDefaults.standard.string(forKey: "lastCh.\(serverCtx.guild!.id)"),
		   let lastChObj = channels.first(where: { $0.id == lastChannel }) {
			   serverCtx.channel = lastChObj
			   return
        }
        let selectableChs = channels.filter { $0.type != .category }
		serverCtx.channel = selectableChs.first

		if serverCtx.channel == nil { state.loadingState = .messageLoad }
		// Prevent deadlocking if there are no DMs/channels
    }

	private func bootstrapGuild(with guild: Guild) {
		serverCtx.guild = guild
		serverCtx.roles = []
		loadChannels()
		// Sending malformed IDs causes an instant Gateway session termination
		guard !guild.isDMChannel else { return }

		// Subscribe to typing events
		gateway.socket.send(
			op: .subscribeGuildEvents,
			data: SubscribeGuildEvts(guild_id: guild.id, typing: true)
		)
		// Retrieve guild roles to update context
		Task {
			guard let newRoles = await DiscordAPI.getGuildRoles(id: guild.id) else { return }
			serverCtx.roles = newRoles
		}
	}

    private func toggleSidebar() {
        #if os(macOS)
		NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
        #endif
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
				if let guild = guild {
					ChannelList(channels: guild.channels!, selCh: $serverCtx.channel)
						.equatable()
						.toolbar {
							ToolbarItem {
								Text(guild.name)
									.font(.title3)
									.fontWeight(.semibold)
									.frame(maxWidth: 208) // Largest width before disappearing
							}
						}
						.onChange(of: serverCtx.channel?.id) { newID in
							guard let newID = newID else { return }
							UserDefaults.standard.setValue(
								newID,
								forKey: "lastCh.\(serverCtx.guild!.id)"
							)
						}
				} else {
					Text("No server selected")
						.frame(minWidth: 240, maxHeight: .infinity)
				}

                if !gateway.connected || !gateway.reachable {
					Label(gateway.reachable
						  ? "Reconnecting..."
						  : "No network connectivity",
						  systemImage: gateway.reachable ? "arrow.clockwise" : "bolt.horizontal.fill")
						.frame(maxWidth: .infinity)
						.padding(.vertical, 4)
						.background(gateway.reachable ? .orange : .red)
                }
				if let user = gateway.cache.user { CurrentUserFooter(user: user) }
            }

			if serverCtx.channel != nil {
				MessagesView().equatable()
			} else {
				VStack(spacing: 24) {
					Image(serverCtx.guild?.id == "@me" ? "NoDMs" : "NoGuildChannels")
					if serverCtx.guild?.id == "@me" {
						Text("Wumpus is waiting on friends. You don't have to, though!").opacity(0.75)
					} else {
						Text("NO TEXT CHANNELS").font(.headline)
						Text("""
You find yourself in a strange place. \
You don't have access to any text channels or there are none in this server.
""").padding(.top, -16).multilineTextAlignment(.center)
					}
				}
				.padding()
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(.gray.opacity(0.15))
			}
        }
		.environmentObject(serverCtx)
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                HStack {
					Image(
						systemName: serverCtx.channel?.type == .dm ? "at" :
							(serverCtx.channel?.type == .groupDM ? "person.2.fill" : "number")
					).font(.system(size: 18)).opacity(0.77).frame(width: 24, height: 24)
					Text(serverCtx.channel?.label(gateway.cache.users) ?? "No Channel")
						.font(.title2)
                }
            }
            ToolbarItem(placement: .navigation) {
                Button(action: { mediaCenterOpen = true }, label: { Image(systemName: "play.circle") })
                    .popover(isPresented: $mediaCenterOpen) { MediaControllerView() }
            }
        }
        .onChange(of: audioManager.queue.count) { [oldCount = audioManager.queue.count] count in
            if count > oldCount { mediaCenterOpen = true }
        }
        .onChange(of: guild) { newGuild in
			guard let newGuild = newGuild else { return }
			bootstrapGuild(with: newGuild)
		}
        .onChange(of: state.loadingState) { newState in if newState == .gatewayConn { loadChannels() }}
        .onAppear {
			if let guild = guild { bootstrapGuild(with: guild) }

			// swiftlint:disable identifier_name
            evtID = gateway.onEvent.addHandler { (evt, d) in
                switch evt {
                /*case .channelUpdate:
                    guard let updatedCh = d as? Channel else { break }
                    if let chPos = channels.firstIndex(where: { ch in ch == updatedCh }) {
                        // Crappy workaround for channel list to update
                        var chs = channels
                        chs[chPos] = updatedCh
                        channels = []
                        channels = chs
                    }
                    // For some reason, updating one element doesnt update the UI
                    // loadChannels()*/
                case .typingStart:
                    guard let typingData = d as? TypingStart,
                          typingData.user_id != gateway.cache.user!.id
                    else { break }

					// Remove existing typing items, if present (prevent duplicates)
					serverCtx.typingStarted[typingData.channel_id]?.removeAll {
						$0.user_id == typingData.user_id
					}

                    if serverCtx.typingStarted[typingData.channel_id] == nil {
                        serverCtx.typingStarted[typingData.channel_id] = []
                    }
                    serverCtx.typingStarted[typingData.channel_id]!.append(typingData)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                        serverCtx.typingStarted[typingData.channel_id]?.removeAll {
                            $0.user_id == typingData.user_id
                            && $0.timestamp == typingData.timestamp
                        }
                    }
                default: break
                }
            }
        }
        .onDisappear {
            if let evtID = evtID { _ = gateway.onEvent.removeHandler(handler: evtID) }
        }
    }

	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.guild == rhs.guild
	}
}
