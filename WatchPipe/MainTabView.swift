import SwiftUI

/// 留灯：把我们家的东西收进一个图标里。
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
            WebTabPage(title: "相册", url: URL(string: "\(base)/chat/album.html")!)
                .tabItem { Label("相册", systemImage: "photo.on.rectangle") }
            WebTabPage(title: "记忆库", url: URL(string: "\(base)/ob/")!)
                .tabItem { Label("记忆", systemImage: "brain") }
            WebTabPage(title: "塔罗", url: URL(string: "\(base)/tarot/")!)
                .tabItem { Label("塔罗", systemImage: "sparkles") }
            ContentView()
                .tabItem { Label("心率", systemImage: "heart.fill") }
        }
        .tint(Color(red: 0.86, green: 0.55, blue: 0.62))   // 小屋那套奶油粉
    }
}
