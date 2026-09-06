//
//  GroupSearchView.swift
//  CcCompanion
//
//  Local search controls for the workgroup tab.
//

import SwiftUI

struct GroupSearchBar: View {
    @Binding var text: String
    let visibleCount: Int
    let totalCount: Int
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ccTextDim)
                TextField("搜群聊消息 / @mention / agent", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.ccSerifAdaptive(size: 14))
                    .foregroundStyle(Color.ccText)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.ccTextDim)
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onClose) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ccAccent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ccCard))

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("\(visibleCount) / \(totalCount) 条")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.ccTextDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.ccBg)
    }
}

struct GroupSearchEmptyState: View {
    let query: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.ccTextDim)
            Text("没有匹配消息")
                .font(.ccSerifAdaptive(size: 16, weight: .semibold))
                .foregroundStyle(Color.ccText)
            Text(query)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.ccTextDim)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}

enum GroupMessageSearch {
    static func matches(_ message: GroupMessage, member: GroupMember, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        let haystack = [
            message.text,
            message.senderId,
            message.senderModel ?? "",
            message.messageType,
            member.title,
            message.mentions.joined(separator: " "),
        ].joined(separator: " ").lowercased()
        return haystack.contains(q)
    }
}
