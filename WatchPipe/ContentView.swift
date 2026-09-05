import SwiftUI

struct ContentView: View {
    @ObservedObject var log = Log.shared
    @State private var url = Settings.serverURL
    @State private var secret = Settings.secret
    @State private var authorized = UserDefaults.standard.bool(forKey: "authorized")
    @State private var pending = Outbox.shared.pendingCount
    @State private var inflight = Outbox.shared.inflightFiles.count
    @State private var busy = false

    var body: some View {
        NavigationView {
            List {
                Section("服务器") {
                    TextField("接口地址", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("令牌（secret）", text: $secret)
                    Button("保存") { Settings.serverURL = url.trimmingCharacters(in: .whitespaces); Settings.secret = secret.trimmingCharacters(in: .whitespaces); Log.shared.add("已保存服务器设置") }
                }
                Section("状态") {
                    HStack { Text("健康授权"); Spacer(); Text(authorized ? "已授权" : "未授权").foregroundColor(authorized ? .green : .red) }
                    HStack { Text("待发送"); Spacer(); Text("\(pending) 条 / \(inflight) 批").monospacedDigit() }
                    if !authorized {
                        Button("授权读取健康数据") { busy = true; HealthSync.shared.requestAuthorization { ok in authorized = ok; busy = false; refresh() } }
                    }
                    Button(busy ? "同步中…" : "立即同步并上传") {
                        busy = true
                        HealthSync.shared.syncAll(reason: "手动") { DispatchQueue.main.async { busy = false; refresh() } }
                    }.disabled(busy || !authorized)
                    Button("重发未完成的批次") { Uploader.shared.flush(reason: "手动重发"); refresh() }.disabled(!authorized)
                }
                Section(header: HStack { Text("日志"); Spacer(); Button("清空") { log.clear() }.font(.caption) }) {
                    ForEach(Array(log.lines.reversed().prefix(120).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 11, design: .monospaced)).foregroundColor(l.contains("失败") || l.contains("未开") || l.contains("出错") ? .red : .primary)
                    }
                }
            }
            .navigationTitle("WatchPipe")
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in refresh() }
        }
    }
    private func refresh() { pending = Outbox.shared.pendingCount; inflight = Outbox.shared.inflightFiles.count; authorized = UserDefaults.standard.bool(forKey: "authorized") }
}
