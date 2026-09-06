import SwiftUI

/// 留灯：把我们家的东西收进一个图标里。底栏五个，更多的收进「更多」。
struct MainTabView: View {
    private let base = "https://bing-k.top"
    var body: some View {
        TabView {
            WebTabPage(title: "留灯", url: URL(string: "\(base)/chat/")!)
                .tabItem { Label("留灯", systemImage: "lamp.table") }
            WebTabPage(title: "小屋", url: URL(string: "\(base)/room/")!)
                .tabItem { Label("小屋", systemImage: "house") }
            WebTabPage(title: "花园", url: URL(string: "https://toy.cedarstar.org/")!)
                .tabItem { Label("花园", systemImage: "leaf") }
            ContentView()
                .tabItem { Label("心率", systemImage: "heart.fill") }
            MoreView(base: base)
                .tabItem { Label("更多", systemImage: "ellipsis.circle") }
        }
        .tint(Color(red: 0.86, green: 0.55, blue: 0.62))   // 小屋那套奶油粉
    }
}

struct MoreView: View {
    let base: String
    var body: some View {
        NavigationView {
            List {
                NavigationLink { WebTabPage(title: "相册", url: URL(string: "\(base)/chat/album.html")!).navigationTitle("相册").navigationBarTitleDisplayMode(.inline) } label: { Label("相册", systemImage: "photo.on.rectangle") }
                NavigationLink { WebTabPage(title: "记忆库", url: URL(string: "\(base)/ob/")!).navigationTitle("记忆库").navigationBarTitleDisplayMode(.inline) } label: { Label("记忆库", systemImage: "brain") }
                NavigationLink { WebTabPage(title: "塔罗", url: URL(string: "\(base)/tarot/")!).navigationTitle("塔罗").navigationBarTitleDisplayMode(.inline) } label: { Label("塔罗", systemImage: "sparkles") }
            }
            .navigationTitle("更多")
        }
    }
}
