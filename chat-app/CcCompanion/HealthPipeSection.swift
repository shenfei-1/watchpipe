//  HealthPipeSection.swift — 设置页「心率管道」分组（珩 2026-09-11，1.3 build 242）
//  secret 进 Keychain；授权健康数据；状态行（最近上传 / 后台投递已开）；最近几行日志。
//  样式照 CcSettingsView 的 section()/row 手写一遍（那些 helper 是 private 的）。

import SwiftUI

struct HealthPipeSection: View {
    @ObservedObject private var log = HealthLog.shared
    @State private var secret: String = HealthSettings.secret
    @State private var savedSecret: String = HealthSettings.secret
    @State private var authorized: Bool = HealthStatus.authorized
    @State private var bgOn: Bool = HealthStatus.backgroundDeliveryOn
    @State private var pending: Int = Outbox.shared.pendingCount
    @State private var inflight: Int = Outbox.shared.inflightFiles.count
    @State private var lastAt: Date? = HealthStatus.lastUploadAt
    @State private var lastCount: Int = HealthStatus.lastUploadCount
    @State private var busy = false
    @State private var showLog = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("心率管道")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.ccTextDim)
                .tracking(1.2)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                secretRow
                authRow
                statusRow("最近上传", value: lastUploadText)
                statusRow("后台投递", value: bgOn ? "已开" : (authorized ? "未全开" : "等授权"), tint: bgOn ? Color.ccAccent : Color.ccTextDim)
                statusRow("待发送", value: "\(pending) 条 / \(inflight) 批")
                syncRow
                logRows
            }
            .background(Color.ccCard)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in refresh() }
        .onReceive(log.$lines) { _ in refresh() }
    }

    private var lastUploadText: String {
        guard let t = lastAt else { return "还没有" }
        return "\(Self.timeFmt.string(from: t)) · \(lastCount) 条"
    }

    // MARK: rows

    private var secretRow: some View {
        HStack {
            Text("secret")
                .font(.ccSerifAdaptive(size: 15))
                .foregroundStyle(Color.ccText)
            Spacer()
            SecureField("跟 WatchPipe 一样的令牌", text: $secret)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.ccAccent)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if secret.trimmingCharacters(in: .whitespaces) != savedSecret {
                Button {
                    let s = secret.trimmingCharacters(in: .whitespaces)
                    HealthSettings.secret = s
                    savedSecret = s
                    HealthLog.shared.add(s.isEmpty ? "secret 已清空" : "secret 已保存")
                    if !s.isEmpty { Uploader.shared.flush(reason: "填了 secret") }
                } label: {
                    Text("保存")
                        .font(.ccSerifAdaptive(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.ccAccent).clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
    }

    private var authRow: some View {
        HStack {
            Text("健康数据")
                .font(.ccSerifAdaptive(size: 15))
                .foregroundStyle(Color.ccText)
            Spacer()
            if authorized {
                Text("已授权")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Color.ccAccent)
            } else {
                Button {
                    busy = true
                    HealthSync.shared.requestAuthorization { ok in
                        authorized = ok; busy = false; refresh()
                    }
                } label: {
                    Text(busy ? "等系统弹窗…" : "授权健康数据")
                        .font(.ccSerifAdaptive(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.ccAccent).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
    }

    private func statusRow(_ label: String, value: String, tint: Color = Color.ccAccent) -> some View {
        HStack {
            Text(label)
                .font(.ccSerifAdaptive(size: 15))
                .foregroundStyle(Color.ccText)
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
    }

    private var syncRow: some View {
        HStack {
            Button {
                busy = true
                HealthSync.shared.syncAll(reason: "手动") { busy = false; refresh() }
            } label: {
                Text(busy ? "同步中…" : "立即同步并上传")
                    .font(.ccSerifAdaptive(size: 15, weight: .semibold))
                    .foregroundStyle(authorized && !busy ? Color.ccAccent : Color.ccTextDim)
            }
            .buttonStyle(.plain)
            .disabled(busy || !authorized)
            Spacer()
            Button {
                Uploader.shared.flush(reason: "手动重发"); refresh()
            } label: {
                Text("重发未完成")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(inflight > 0 ? Color.ccAccent : Color.ccTextDim)
            }
            .buttonStyle(.plain)
            .disabled(inflight == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
    }

    private var logRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("日志")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.ccTextDim)
                Spacer()
                Button(showLog ? "收起" : "展开") { showLog.toggle() }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.ccAccent)
                    .buttonStyle(.plain)
                Button("清空") { log.clear() }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.ccTextDim)
                    .buttonStyle(.plain)
            }
            let lines = Array(log.lines.reversed().prefix(showLog ? 60 : 5))
            if lines.isEmpty {
                Text("还没有记录")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.ccTextDim)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(l.contains("失败") || l.contains("未开") || l.contains("出错") ? Color.red.opacity(0.8) : Color.ccTextDim)
                    .lineLimit(showLog ? 3 : 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func refresh() {
        authorized = HealthStatus.authorized
        bgOn = HealthStatus.backgroundDeliveryOn
        pending = Outbox.shared.pendingCount
        inflight = Outbox.shared.inflightFiles.count
        lastAt = HealthStatus.lastUploadAt
        lastCount = HealthStatus.lastUploadCount
    }
}
