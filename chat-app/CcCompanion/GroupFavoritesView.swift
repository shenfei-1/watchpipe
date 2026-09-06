//
//  GroupFavoritesView.swift
//  CcCompanion
//
//  Local favorites browser for workgroup messages.
//

import SwiftUI
import Foundation

nonisolated struct GroupFavoriteItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let createdAt: String
    let message: GroupMessage
    let senderTitle: String

    enum CodingKeys: String, CodingKey {
        case id, message, senderTitle
        case createdAt = "created_at"
    }
}

extension Notification.Name {
    static let ccGroupFavoritesDidChange = Notification.Name("CcGroupFavoritesDidChange")
}

enum GroupFavoritesStore {
    private static let key = "group_message_favorites_v1"

    static func all() -> [GroupFavoriteItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([GroupFavoriteItem].self, from: data) else {
            return []
        }
        return decoded.sorted { lhs, rhs in lhs.createdAt > rhs.createdAt }
    }

    static func ids() -> Set<String> {
        Set(all().map(\.id))
    }

    static func contains(_ messageId: String) -> Bool {
        ids().contains(messageId)
    }

    @discardableResult
    static func toggle(message: GroupMessage, member: GroupMember) -> Bool {
        if contains(message.id) {
            remove(messageId: message.id)
            return false
        }
        add(message: message, member: member)
        return true
    }

    static func add(message: GroupMessage, member: GroupMember) {
        var items = all().filter { $0.id != message.id }
        let formatter = ISO8601DateFormatter()
        items.insert(GroupFavoriteItem(
            id: message.id,
            createdAt: formatter.string(from: Date()),
            message: message,
            senderTitle: member.title
        ), at: 0)
        persist(items)
    }

    static func remove(messageId: String) {
        persist(all().filter { $0.id != messageId })
    }

    private static func persist(_ items: [GroupFavoriteItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: .ccGroupFavoritesDidChange, object: nil)
    }
}

struct GroupFavoritesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [GroupFavoriteItem] = []
    @State private var searchText = ""

    private var filteredItems: [GroupFavoriteItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { item in
            let member = GroupMember.defaultMap[item.message.senderId] ?? GroupMember(id: item.message.senderId, displayName: item.message.senderId, kind: nil, avatar: nil, color: nil, model: nil, tmux: nil, canReply: nil, optional: nil)
            return GroupMessageSearch.matches(item.message, member: member, query: q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                        .foregroundStyle(Color.ccText)
                }
                Spacer()
                Text("群聊收藏")
                    .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                    .foregroundStyle(Color.ccText)
                Spacer()
                Image(systemName: "xmark")
                    .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                    .opacity(0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.ccBg)

            if filteredItems.isEmpty {
                GroupFavoritesEmptyState(hasSearch: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredItems) { item in
                        GroupFavoriteRow(item: item)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions {
                                Button(role: .destructive) {
                                    GroupFavoritesStore.remove(messageId: item.id)
                                    reload()
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.ccBg)
        .toolbar(.hidden, for: .navigationBar)
        .searchable(text: $searchText, prompt: "搜群聊收藏")
        .onReceive(NotificationCenter.default.publisher(for: .ccGroupFavoritesDidChange)) { _ in reload() }
        .onAppear { reload() }
        .refreshable { reload() }
    }

    private func reload() {
        items = GroupFavoritesStore.all()
    }
}

private struct GroupFavoriteRow: View {
    let item: GroupFavoriteItem

    private var member: GroupMember {
        GroupMember.defaultMap[item.message.senderId] ?? GroupMember(
            id: item.message.senderId,
            displayName: item.senderTitle,
            kind: nil,
            avatar: nil,
            color: nil,
            model: nil,
            tmux: nil,
            canReply: nil,
            optional: nil
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            GroupAvatarView(member: member, size: 34)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.senderTitle)
                        .font(.ccSerifAdaptive(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ccText)
                    Text(item.message.shortTime)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.ccTextDim)
                    if item.message.messageType != "chat" {
                        Text(item.message.messageType.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.ccAccent)
                    }
                    Spacer()
                }
                Text(item.message.text)
                    .font(.ccSerifAdaptive(size: 14))
                    .foregroundStyle(Color.ccText)
                    .lineLimit(5)
                    .lineSpacing(2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.ccCard.opacity(0.85)))
    }
}

private struct GroupFavoritesEmptyState: View {
    let hasSearch: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: hasSearch ? "magnifyingglass" : "star")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.ccTextDim)
            Text(hasSearch ? "没有匹配收藏" : "还没有收藏")
                .font(.ccSerifAdaptive(size: 16, weight: .semibold))
                .foregroundStyle(Color.ccText)
            Text(hasSearch ? "换个关键词试试。" : "在群聊消息上长按，点收藏。")
                .font(.ccSerifAdaptive(size: 13))
                .foregroundStyle(Color.ccTextDim)
        }
        .multilineTextAlignment(.center)
    }
}
