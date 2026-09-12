//  ChatTableView.swift — 聊天页消息列表的 UIKit 层（珩 2026-09-12，1.3 build 243「聊天页第一刀」）
//
//  为什么换：SwiftUI ScrollView + LazyVStack 每来一条消息就整段 diff，键盘收起后贴底也靠三连 scrollTo 补，
//  239 没修好的"收键盘后列表往上滑"根在这里。换成 UITableView：
//  - cell 里用 UIHostingConfiguration 承载现有 SwiftUI 气泡（气泡、语音、图片、心跳胶囊、thinking、长按菜单一个不丢）
//  - 行高 automaticDimension + estimated 走缓存字典（message id + 宽度），滚回去不抖
//  - 新消息 insertRows（不 reloadData）；行内容变了 reconfigureRows；只有结构大变才 reloadData
//  - 列表高度变化（键盘弹起/收起、底栏出没）时，若之前贴底就继续贴底：layoutSubviews 里逐帧钉住，
//    再用 keyboardWillChangeFrame 的 duration/curve 在键盘动画结束时做最后一次校准
//  - 从底部附近来了新消息自动跟随；用户往上翻时不打扰，只把"翻上去了"报给 SwiftUI 去显示未读胶囊

import SwiftUI
import UIKit

/// SwiftUI → 列表 的一次性命令。token 变一次执行一次；holdPosition 为真时不自动贴底（跳老消息 / 加载更早期间）。
struct ChatTableCommands: Equatable {
    var scrollToBottomToken: Int = 0
    var scrollToBottomAnimatedToken: Int = 0
    var jumpTargetId: String? = nil
    var holdPosition: Bool = false
}

struct ChatMessageTable: UIViewRepresentable {
    let rows: [ChatRowItem]
    let commands: ChatTableCommands
    /// (row, 上一行, 列表宽度) → 这一行的 SwiftUI 内容
    let content: (_ row: ChatRowItem, _ prev: ChatRowItem?, _ width: CGFloat) -> AnyView
    var onScrolledUpChanged: ((Bool) -> Void)? = nil
    var onPullToRefresh: (() async -> Void)? = nil
    var onFirstLayout: (() -> Void)? = nil
    var onJumpFinished: (() -> Void)? = nil
    var onBackgroundTap: (() -> Void)? = nil

    func makeCoordinator() -> ChatTableCoordinator { ChatTableCoordinator(parent: self) }

    func makeUIView(context: Context) -> ChatUITableView {
        let table = ChatUITableView(frame: .zero, style: .plain)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.register(UITableViewCell.self, forCellReuseIdentifier: ChatTableCoordinator.reuseId)
        table.separatorStyle = .none
        table.backgroundColor = .clear
        table.allowsSelection = false
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 76
        table.estimatedSectionHeaderHeight = 0
        table.estimatedSectionFooterHeight = 0
        table.sectionHeaderTopPadding = 0
        table.keyboardDismissMode = .interactive
        table.contentInsetAdjustmentBehavior = .never
        table.contentInset = UIEdgeInsets(top: ChatMetrics.listTopInset, left: 0, bottom: ChatMetrics.listBottomInset, right: 0)
        table.showsVerticalScrollIndicator = true
        table.selfSizingInvalidation = .enabledIncludingConstraints
        table.insetsContentViewsToSafeArea = false

        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(ChatTableCoordinator.refreshPulled(_:)), for: .valueChanged)
        table.refreshControl = refresh

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(ChatTableCoordinator.backgroundTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        table.addGestureRecognizer(tap)

        context.coordinator.tableView = table
        context.coordinator.observeKeyboard()
        return table
    }

    func updateUIView(_ table: ChatUITableView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.apply(rows: rows, to: table)
        c.apply(commands: commands, to: table)
    }

    static func dismantleUIView(_ table: ChatUITableView, coordinator: ChatTableCoordinator) {
        coordinator.stopObservingKeyboard()
    }
}

// MARK: - Coordinator

final class ChatTableCoordinator: NSObject, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    static let reuseId = "chat-row"
    var parent: ChatMessageTable
    weak var tableView: ChatUITableView?
    private(set) var rows: [ChatRowItem] = []
    /// 行高缓存：key = "\(row.id)|\(Int(width))"
    private var heightCache: [String: CGFloat] = [:]
    private var lastCommands = ChatTableCommands()
    private var reportedScrolledUp = false
    private var didFirstLayout = false
    private var observingKeyboard = false
    private var refreshing = false

    init(parent: ChatMessageTable) {
        self.parent = parent
        super.init()
    }

    // MARK: rows diff

    func apply(rows newRows: [ChatRowItem], to table: ChatUITableView) {
        let old = rows
        if old == newRows { return }

        // 首次 / 清空 → 整表
        if old.isEmpty || newRows.isEmpty {
            rows = newRows
            table.reloadData()
            if !newRows.isEmpty {
                if table.bounds.height > 0 {
                    table.layoutIfNeeded()
                    table.scrollToBottom(animated: false)
                    settleBottom(table)
                } else {
                    table.needsInitialBottom = true
                }
            }
            if !didFirstLayout, !newRows.isEmpty {
                didFirstLayout = true
                DispatchQueue.main.async { [weak self] in self?.parent.onFirstLayout?() }
            }
            return
        }

        // A. 末尾追加（老行 id 逐一相同）：insertRows，不整表
        if newRows.count > old.count, Self.idsMatchPrefix(old: old, new: newRows) {
            var changed: [IndexPath] = []
            for i in old.indices where old[i] != newRows[i] { changed.append(IndexPath(row: i, section: 0)) }
            let inserted = (old.count..<newRows.count).map { IndexPath(row: $0, section: 0) }
            let nearBottom = table.isNearBottom
            let hasOwnMessage = newRows[old.count...].contains { row in
                if case .message(let m, _) = row { return m.isUser }
                return false
            }
            rows = newRows
            UIView.performWithoutAnimation {
                table.performBatchUpdates {
                    if !changed.isEmpty { table.reconfigureRows(at: changed) }
                    table.insertRows(at: inserted, with: .none)
                }
            }
            if (nearBottom && !parent.commands.holdPosition) || hasOwnMessage {
                table.scrollToBottom(animated: true)
            }
            return
        }

        // B. 头部插入（加载更早）：整表重载，但把原先第一可见行钉在原位
        if newRows.count > old.count, Self.idsMatchSuffix(old: old, new: newRows) {
            let anchorPath = table.indexPathsForVisibleRows?.first
            let anchorId = anchorPath.map { old[$0.row].id }
            let anchorOffset = anchorPath.map { table.rectForRow(at: $0).minY - table.contentOffset.y }
            rows = newRows
            table.reloadData()
            table.layoutIfNeeded()
            if let anchorId, let off = anchorOffset,
               let idx = newRows.firstIndex(where: { $0.id == anchorId }) {
                let y = table.rectForRow(at: IndexPath(row: idx, section: 0)).minY - off
                table.setContentOffset(CGPoint(x: 0, y: max(-table.adjustedContentInset.top, y)), animated: false)
            }
            return
        }

        // C. 行数相同、id 相同、内容变了（reaction / showTime 回填 / toolStack 状态）
        if newRows.count == old.count, Self.idsMatchPrefix(old: old, new: newRows) {
            var changed: [IndexPath] = []
            for i in old.indices where old[i] != newRows[i] { changed.append(IndexPath(row: i, section: 0)) }
            rows = newRows
            if changed.isEmpty { return }
            if changed.count <= 24 {
                UIView.performWithoutAnimation { table.reconfigureRows(at: changed) }
            } else {
                table.reloadData()
            }
            return
        }

        // D. 其他（删除 / 窗口收缩 / 搜索切换）：整表；之前贴底就继续贴底
        let nearBottom = table.isNearBottom
        rows = newRows
        table.reloadData()
        table.layoutIfNeeded()
        if nearBottom && !parent.commands.holdPosition {
            table.scrollToBottom(animated: false)
        }
    }

    private static func idsMatchPrefix(old: [ChatRowItem], new: [ChatRowItem]) -> Bool {
        guard new.count >= old.count else { return false }
        for i in old.indices where old[i].id != new[i].id { return false }
        return true
    }

    private static func idsMatchSuffix(old: [ChatRowItem], new: [ChatRowItem]) -> Bool {
        guard new.count >= old.count else { return false }
        let shift = new.count - old.count
        for i in old.indices where old[i].id != new[i + shift].id { return false }
        return true
    }

    /// 首屏贴底：估算行高落不准，下一帧和 0.3s 后各校一次（只在仍贴底时）
    private func settleBottom(_ table: ChatUITableView) {
        DispatchQueue.main.async { [weak table] in
            guard let table, table.isNearBottom else { return }
            table.scrollToBottom(animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak table] in
            guard let table, table.isNearBottom else { return }
            table.scrollToBottom(animated: false)
        }
    }

    // MARK: commands

    func apply(commands: ChatTableCommands, to table: ChatUITableView) {
        defer { lastCommands = commands }
        if commands.scrollToBottomToken != lastCommands.scrollToBottomToken {
            table.scrollToBottom(animated: false)
            settleBottom(table)
        }
        if commands.scrollToBottomAnimatedToken != lastCommands.scrollToBottomAnimatedToken {
            table.scrollToBottom(animated: true)
        }
        if let target = commands.jumpTargetId, target != lastCommands.jumpTargetId {
            if let idx = rows.firstIndex(where: { $0.id == target }) {
                table.scrollToRow(at: IndexPath(row: idx, section: 0), at: .middle, animated: true)
                // 估算行高会让第一次落点偏，0.45s 后再对一次
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak table] in
                    guard let self, let table, self.rows.indices.contains(idx), self.rows[idx].id == target else { return }
                    table.scrollToRow(at: IndexPath(row: idx, section: 0), at: .middle, animated: false)
                    self.parent.onJumpFinished?()
                }
            } else {
                DispatchQueue.main.async { [weak self] in self?.parent.onJumpFinished?() }
            }
        }
    }

    // MARK: keyboard

    func observeKeyboard() {
        guard !observingKeyboard else { return }
        observingKeyboard = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
    }

    func stopObservingKeyboard() {
        guard observingKeyboard else { return }
        observingKeyboard = false
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let table = tableView else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
        let wasNearBottom = table.isNearBottom
        table.keyboardTransitionUntil = Date().addingTimeInterval(duration + 0.15)
        table.stickToBottomDuringTransition = wasNearBottom
        // 键盘动画走完，用同一 duration/curve 做最后一次贴底校准（SwiftUI 改高度是逐帧的，
        // layoutSubviews 已经逐帧钉住；这里兜掉最后一帧的残差，收键盘后不会再"往上滑"）
        guard wasNearBottom else { return }
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak table] in
            guard let table, table.stickToBottomDuringTransition else { return }
            UIView.animate(withDuration: min(0.2, max(0.05, duration)), delay: 0, options: [options, .beginFromCurrentState]) {
                table.pinToBottomNow()
            }
        }
    }

    // MARK: refresh / tap

    @objc func refreshPulled(_ sender: UIRefreshControl) {
        guard !refreshing, let handler = parent.onPullToRefresh else { sender.endRefreshing(); return }
        refreshing = true
        Task { @MainActor [weak self, weak sender] in
            await handler()
            sender?.endRefreshing()
            self?.refreshing = false
        }
    }

    @objc func backgroundTapped(_ g: UITapGestureRecognizer) {
        parent.onBackgroundTap?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: data source

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.reuseId, for: indexPath)
        let row = rows[indexPath.row]
        let prev = indexPath.row > 0 ? rows[indexPath.row - 1] : nil
        let width = tableView.bounds.width
        let build = parent.content
        cell.contentConfiguration = UIHostingConfiguration {
            build(row, prev, width)
        }
        .margins(.all, 0)
        .background(Color.clear)
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.selectionStyle = .none
        return cell
    }

    // MARK: delegate — 行高缓存

    private func cacheKey(_ indexPath: IndexPath, width: CGFloat) -> String? {
        guard rows.indices.contains(indexPath.row) else { return nil }
        return "\(rows[indexPath.row].id)|\(Int(width))"
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        if let key = cacheKey(indexPath, width: tableView.bounds.width), let h = heightCache[key] { return h }
        guard rows.indices.contains(indexPath.row) else { return 76 }
        switch rows[indexPath.row] {
        case .separator: return 34
        case .toolStack: return 40
        case .message: return 76
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let key = cacheKey(indexPath, width: tableView.bounds.width), cell.bounds.height > 1 {
            heightCache[key] = cell.bounds.height
        }
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let key = cacheKey(indexPath, width: tableView.bounds.width), cell.bounds.height > 1 {
            heightCache[key] = cell.bounds.height
        }
    }

    // MARK: scroll → "翻上去了"

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let table = scrollView as? ChatUITableView else { return }
        // 键盘动画期间 viewport 在变，不判
        if Date() < table.keyboardTransitionUntil { return }
        let up = table.distanceFromBottom > 350
        if up != reportedScrolledUp {
            reportedScrolledUp = up
            DispatchQueue.main.async { [weak self] in self?.parent.onScrolledUpChanged?(up) }
        }
    }
}

// MARK: - UITableView 子类：高度变化时贴底

final class ChatUITableView: UITableView {
    /// 键盘动画结束时刻（含余量）；期间的 scrollViewDidScroll 不判"翻上去"
    var keyboardTransitionUntil: Date = .distantPast
    /// 键盘动画开始时是否贴底；是就一路钉住
    var stickToBottomDuringTransition = false
    /// 数据先到、frame 还是 0：等第一次有高度的 layout 再贴底
    var needsInitialBottom = false
    private var lastLayoutHeight: CGFloat = 0
    private var nearBottomAfterLastLayout = true

    var distanceFromBottom: CGFloat {
        let visibleBottom = contentOffset.y + bounds.height
        let contentBottom = contentSize.height + adjustedContentInset.bottom
        return contentBottom - visibleBottom
    }

    var isNearBottom: Bool { distanceFromBottom < 48 }

    var bottomOffsetY: CGFloat {
        max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
    }

    /// 直接把 contentOffset 钉到底（不动画；在 UIView.animate 里调就随动画）
    func pinToBottomNow() {
        let y = bottomOffsetY
        if abs(contentOffset.y - y) > 0.5 {
            contentOffset = CGPoint(x: contentOffset.x, y: y)
        }
    }

    func scrollToBottom(animated: Bool) {
        let n = numberOfRows(inSection: 0)
        guard n > 0, bounds.height > 0 else { return }
        let last = IndexPath(row: n - 1, section: 0)
        if animated {
            scrollToRow(at: last, at: .bottom, animated: true)
        } else {
            scrollToRow(at: last, at: .bottom, animated: false)
            layoutIfNeeded()
            pinToBottomNow()
        }
    }

    override func layoutSubviews() {
        let h = bounds.height
        let heightChanged = lastLayoutHeight > 0 && abs(h - lastLayoutHeight) > 0.5
        let inKeyboardTransition = Date() < keyboardTransitionUntil
        let shouldPin = heightChanged && (nearBottomAfterLastLayout || (inKeyboardTransition && stickToBottomDuringTransition))
        super.layoutSubviews()
        if needsInitialBottom, h > 0 {
            needsInitialBottom = false
            scrollToBottom(animated: false)
        } else if shouldPin {
            pinToBottomNow()
            super.layoutSubviews()
        }
        lastLayoutHeight = h
        nearBottomAfterLastLayout = isNearBottom
    }
}
