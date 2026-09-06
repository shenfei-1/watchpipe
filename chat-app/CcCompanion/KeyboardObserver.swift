//  KeyboardObserver.swift — 键盘在不在（珩 2026-09-06）
//  打字时底栏收起来、键盘收了再回来（微信 / Telegram 的做法），底栏不再跟着键盘一起抬。

import SwiftUI
import Combine
import UIKit

final class KeyboardObserver: ObservableObject {
    @Published var visible: Bool = false
    private var bag: Set<AnyCancellable> = []
    init() {
        let nc = NotificationCenter.default
        nc.publisher(for: UIResponder.keyboardWillShowNotification)
            .sink { [weak self] n in
                let h = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
                self?.visible = h > 100
            }
            .store(in: &bag)
        nc.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] _ in self?.visible = false }
            .store(in: &bag)
    }
}
