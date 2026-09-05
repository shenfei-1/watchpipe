import Foundation
import HealthKit

struct QuantitySpec {
    let name: String            // 上报字段名（要和服务端/快捷指令一致）
    let id: HKQuantityTypeIdentifier
    let unit: HKUnit
    let label: String
}

final class HealthSync {
    static let shared = HealthSync()
    let store = HKHealthStore()
    private let q = DispatchQueue(label: "watchpipe.sync")
    private var observersRegistered = false

    static let perMin = HKUnit.count().unitDivided(by: .minute())
    static let quantities: [QuantitySpec] = [
        .init(name: "heart_rate",                 id: .heartRate,                unit: perMin,                        label: "count/min"),
        .init(name: "resting_heart_rate",         id: .restingHeartRate,         unit: perMin,                        label: "count/min"),
        .init(name: "walking_heart_rate_average", id: .walkingHeartRateAverage,  unit: perMin,                        label: "count/min"),
        .init(name: "heart_rate_variability",     id: .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli),     label: "ms"),
        .init(name: "oxygen_saturation",          id: .oxygenSaturation,         unit: .percent(),                    label: "%"),
        .init(name: "respiratory_rate",           id: .respiratoryRate,          unit: perMin,                        label: "count/min"),
        .init(name: "step_count",                 id: .stepCount,                unit: .count(),                      label: "count"),
        .init(name: "active_energy",              id: .activeEnergyBurned,       unit: .kilocalorie(),                label: "kcal"),
        // 新增数值型指标：在这张表加一行即可（记得字段名和单位标签要和其它来源一致）
    ]
    static let sleepType = HKCategoryType(.sleepAnalysis)

    var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>(Self.quantities.map { HKQuantityType($0.id) })
        s.insert(Self.sleepType); return s
    }
    var allSampleTypes: [(String, HKSampleType)] {
        Self.quantities.map { ($0.name, HKQuantityType($0.id)) } + [("sleep", Self.sleepType)]
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let iso: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f   // 本地时间、不带时区，和快捷指令那条线一致
    }()

    // MARK: 授权
    func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        guard isAvailable else { done(false); return }
        store.requestAuthorization(toShare: nil, read: readTypes) { ok, err in
            Log.shared.add(ok ? "健康授权完成" : "健康授权失败: \(err?.localizedDescription ?? "")")
            UserDefaults.standard.set(ok, forKey: "authorized")
            if ok { self.startIfAuthorized(); self.syncAll(reason: "首次授权") {} }
            DispatchQueue.main.async { done(ok) }
        }
    }

    // MARK: 观察者 + 后台投递（didFinishLaunching 里调用）
    func startIfAuthorized() {
        guard isAvailable, UserDefaults.standard.bool(forKey: "authorized"), !observersRegistered else { return }
        observersRegistered = true
        for (name, type) in allSampleTypes {
            let oq = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, err in
                if let err { Log.shared.add("\(name) 观察者出错: \(err.localizedDescription)"); completion(); return }
                self.sync(name: name, type: type) { Uploader.shared.flush(reason: "后台投递 \(name)"); completion() }
            }
            store.execute(oq)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { ok, err in
                Log.shared.add(ok ? "\(name) 后台投递已开" : "\(name) 后台投递未开: \(err?.localizedDescription ?? "")")
            }
        }
        Log.shared.add("已注册 \(allSampleTypes.count) 个类型的观察者")
    }

    // MARK: 同步
    func syncAll(reason: String, done: @escaping () -> Void) {
        guard isAvailable, UserDefaults.standard.bool(forKey: "authorized") else { done(); return }
        let g = DispatchGroup()
        for (name, type) in allSampleTypes { g.enter(); sync(name: name, type: type) { g.leave() } }
        g.notify(queue: q) { Uploader.shared.flush(reason: reason); done() }
    }

    private func anchorKey(_ name: String) -> String { "anchor.\(name)" }
    private func loadAnchor(_ name: String) -> HKQueryAnchor? {
        guard let d = UserDefaults.standard.data(forKey: anchorKey(name)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: d)
    }
    private func saveAnchor(_ a: HKQueryAnchor, _ name: String) {
        if let d = try? NSKeyedArchiver.archivedData(withRootObject: a, requiringSecureCoding: true) {
            UserDefaults.standard.set(d, forKey: anchorKey(name))
        }
    }

    func sync(name: String, type: HKSampleType, done: @escaping () -> Void) {
        let anchor = loadAnchor(name)
        // 首次（anchor 为空）只取最近 24 小时，否则 HealthKit 会把全部历史吐出来
        let predicate: NSPredicate? = anchor == nil
            ? HKQuery.predicateForSamples(withStart: Date(timeIntervalSinceNow: -24 * 3600), end: nil, options: [])
            : nil
        let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: HKObjectQueryNoLimit) { _, samples, _, newAnchor, err in
            if let err { Log.shared.add("\(name) 查询出错: \(err.localizedDescription)"); done(); return }
            let out = self.convert(name: name, samples: samples ?? [])
            // 先落盘，再前进 anchor——顺序反了断电就丢数据
            Outbox.shared.append(out)
            if let newAnchor { self.saveAnchor(newAnchor, name) }
            if !out.isEmpty { Log.shared.add("\(name) 入队 \(out.count) 条") }
            done()
        }
        store.execute(query)
    }

    private func convert(name: String, samples: [HKSample]) -> [Sample] {
        if name == "sleep" {
            return samples.compactMap { s in
                guard let c = s as? HKCategorySample else { return nil }
                let v: String
                switch HKCategoryValueSleepAnalysis(rawValue: c.value) {
                case .inBed: v = "InBed"
                case .asleepCore: v = "Core"
                case .asleepDeep: v = "Deep"
                case .asleepREM: v = "REM"
                case .awake: v = "Awake"
                case .asleepUnspecified: v = "Asleep"
                default: v = "Asleep"
                }
                return Sample(type: "sleep", start: iso.string(from: c.startDate), end: iso.string(from: c.endDate), value: v, unit: nil)
            }
        }
        guard let spec = Self.quantities.first(where: { $0.name == name }) else { return [] }
        return samples.compactMap { s in
            guard let qs = s as? HKQuantitySample, qs.quantity.is(compatibleWith: spec.unit) else { return nil }
            var val = qs.quantity.doubleValue(for: spec.unit)
            if spec.id == .oxygenSaturation { val *= 100 }   // HealthKit 的 percent 是 0~1
            let str = val == val.rounded() ? String(Int(val)) : String(format: "%.2f", val)
            return Sample(type: spec.name, start: iso.string(from: qs.startDate), end: iso.string(from: qs.endDate), value: str, unit: spec.label)
        }
    }
}
