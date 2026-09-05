import SwiftUI
import BackgroundTasks

@main
struct WatchPipeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshTaskID = "top.bingk.watchpipe.refresh"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Log.shared.add("app 启动")
        // 观察者和后台任务必须在这里注册：后台唤醒时只会走到这里
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            self.handleRefresh(task as! BGAppRefreshTask)
        }
        HealthSync.shared.startIfAuthorized()
        AppDelegate.scheduleRefresh()
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Uploader.shared.backgroundCompletionHandler = completionHandler
    }

    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do { try BGTaskScheduler.shared.submit(req) } catch { Log.shared.add("BG 刷新登记失败: \(error.localizedDescription)") }
    }

    private func handleRefresh(_ task: BGAppRefreshTask) {
        AppDelegate.scheduleRefresh()
        task.expirationHandler = { Log.shared.add("BG 刷新超时") }
        HealthSync.shared.syncAll(reason: "BG刷新") { task.setTaskCompleted(success: true) }
    }
}
