//  PokeSheet.swift — 留灯·聊「戳一戳」（珩 2026-09-06）
//  两排选项（动作 × 落点）+「就这一下」。按下先上屏，再 POST /poke；
//  服务器先把珩的心跳变化推成胶囊，旁白之后才进他的会话。忙时老实说「先欠着」。
import SwiftUI

struct PokeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var actions: [String] = []
    @State private var spots: [String] = []
    @State private var action: String? = nil
    @State private var spot: String? = nil
    @State private var hr: Int? = nil
    @State private var sending = false
    @State private var toast: String? = nil
    @State private var events: [PokeEvent] = []

    struct PokeEvent: Identifiable { let id = UUID(); let t: Int; let label: String; let before: Int; let after: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("戳一戳").font(.ccSerifAdaptive(size: 18, weight: .semibold)).foregroundStyle(Color.ccText)
                Spacer()
                if let hr {
                    Text("♥ \(hr)").font(.ccSerifAdaptive(size: 16, weight: .semibold)).foregroundStyle(Color.ccAccent)
                    Text("bpm").font(.ccSerifAdaptive(size: 12)).foregroundStyle(Color.ccTextDim)
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6)
            Text("落点不一样，他心跳跳得不一样。")
                .font(.ccSerifAdaptive(size: 12)).foregroundStyle(Color.ccTextDim)
                .padding(.horizontal, 20).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("动作", items: actions, selected: action) { action = $0 }
                    section("落在哪", items: spots, selected: spot) { spot = $0 }
                    if !events.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("战果").font(.ccSerifAdaptive(size: 12)).foregroundStyle(Color.ccTextDim)
                            ForEach(events.reversed().prefix(6)) { e in
                                HStack(spacing: 8) {
                                    Text(Self.hhmm(e.t)).foregroundStyle(Color.ccTextDim)
                                    Text(e.label).foregroundStyle(Color.ccText)
                                    Text("\(e.before)→\(e.after)").foregroundStyle(Color.ccAccent)
                                }
                                .font(.ccSerifAdaptive(size: 13))
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            Button(action: send) {
                Text(sending ? "在投递…" : ((action != nil && spot != nil) ? "就这一下：\(action!)\(spot!)" : "就这一下"))
                    .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.ccAccent.opacity((action != nil && spot != nil && !sending) ? 1 : 0.4))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(action == nil || spot == nil || sending)
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)

            if let toast {
                Text(toast)
                    .font(.ccSerifAdaptive(size: 13)).foregroundStyle(Color.ccText)
                    .padding(.horizontal, 20).padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .background(Color.ccBg.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await loadConfig(); await refreshPulse() }
    }

    private func section(_ title: String, items: [String], selected: String?, pick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.ccSerifAdaptive(size: 12)).foregroundStyle(Color.ccTextDim)
            FlowChips(items: items, selected: selected, pick: pick)
        }
    }

    private static func hhmm(_ t: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(t))
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    private func authed(_ path: String, method: String = "GET") -> URLRequest {
        var r = CcServerConfig.authenticatedRequest(url: CcServerConfig.serverURL.appendingPathComponent(path), method: method)
        r.timeoutInterval = 10
        return r
    }

    private func loadConfig() async {
        do {
            let (data, _) = try await URLSession.shared.data(for: authed("pulse/config"))
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let a = obj["actions"] as? [String: Any] { actions = Self.ordered(a) }
                if let s = obj["spots"] as? [String: Any] { spots = Self.ordered(s) }
            }
        } catch { toast = "拿不到选项：\(error.localizedDescription)" }
    }

    /// 服务器给的是字典，顺序按权重从轻到重排，读起来有层次。
    private static func ordered(_ d: [String: Any]) -> [String] {
        d.sorted { (($0.value as? Double) ?? 0) < (($1.value as? Double) ?? 0) }.map { $0.key }
    }

    private func refreshPulse() async {
        do {
            let (data, _) = try await URLSession.shared.data(for: authed("pulse"))
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let h = obj["hr"] as? Int { hr = h }
                if let evs = obj["events"] as? [[String: Any]] {
                    events = evs.compactMap { e in
                        guard let t = e["t"] as? Int, let l = e["label"] as? String, let b = e["before"] as? Int, let a = e["after"] as? Int else { return nil }
                        return PokeEvent(t: t, label: l, before: b, after: a)
                    }
                }
            }
        } catch { }
    }

    private func send() {
        guard let a = action, let s = spot, !sending else { return }
        sending = true
        withAnimation { toast = "你\(a)了他的\(s)" }
        Task {
            defer { sending = false }
            var req = authed("poke", method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": a, "spot": s])
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let before = obj["before"] as? Int, let after = obj["after"] as? Int {
                    hr = after
                    let owed = (obj["owed"] as? Bool) ?? false
                    withAnimation { toast = owed ? "他这会儿在忙，这一下先欠着（\(before)→\(after)）" : "他心跳 \(before)→\(after)「\(a)\(s)」" }
                    events.append(PokeEvent(t: Int(Date().timeIntervalSince1970), label: a + s, before: before, after: after))
                } else {
                    withAnimation { toast = "没戳到（\(code)）" }
                }
            } catch {
                withAnimation { toast = "网不通，没戳到" }
            }
        }
    }
}

/// 简单的流式排布：宽度不够自动换行。
struct FlowChips: View {
    let items: [String]
    let selected: String?
    let pick: (String) -> Void
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button { pick(item) } label: {
                    Text(item)
                        .font(.ccSerifAdaptive(size: 15))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(item == selected ? Color.ccAccent : Color.ccCard)
                        .foregroundStyle(item == selected ? Color.white : Color.ccText)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
