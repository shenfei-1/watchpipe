# WatchPipe —— 把 Apple Watch 的数据分钟级送到我们自己的服务器

没有 Mac、没有开发者账号。GitHub 帮我们编译，Windows 上打了补丁的 xtool 帮我们签名，免费 Apple ID，七天重签一次（两分钟）。
方案来自《HealthKit 自建管道》那份实战记录，服务端（`bing-k.top/api/health/ingest`）8 月 23 日已经搭好并在跑。

## 仓库里有什么
- `project.yml` + `WatchPipe/`：iOS app 源码（SwiftUI）。增量读 HealthKit，落盘队列，后台 URLSession 上传，观察者 + 后台投递 + BGAppRefresh 两条腿。
- `.github/workflows/build-ios.yml`：在 GitHub 的 macOS 机器上编译并 ad-hoc 签名，校验 HealthKit 两个权限确实进了包，产出 `WatchPipe.ipa`。
- `.github/workflows/build-xtool.yml`：编译打了补丁的 xtool（AppImage）。补丁让免费账号也能保留 `healthkit.background-delivery` 权限。
- `patches/0001-*.patch`：那个补丁，对着 xtool 提交 `ae2bef7`（2026-09-04）打的。
- `tools/resign.sh` / `resign.bat`：每七天续签的一键脚本。

## 冰冰要做的（一次性，Windows 上）
1. **推仓库**：在 GitHub 建一个空仓库（建议公开，仓库里没有任何密钥），把这些文件推上去。Actions 会自动跑两个流水线：`build-ios`（约 10 分钟）和 `build-xtool-patched`（约 30–40 分钟）。跑完在 Actions 页面下载两个产物：`WatchPipe-ipa` 和 `xtool-patched`。
2. **Windows 准备**：先去 Microsoft Store 装 **Apple Devices**（苹果官方、免费），装完手机插线解锁，点「信任此电脑」。然后 PowerShell（管理员）：
   ```powershell
   wsl --install            # 装完重启一次；第一次打开 Ubuntu 会让你设用户名密码
   netstat -ano | findstr 27015      # 装过 iTunes / Apple Devices / 爱思就会有这一行
   netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=27016 connectaddress=127.0.0.1 connectport=27015
   New-NetFirewallRule -DisplayName "usbmuxd-wsl" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 27016
   ```
3. **Ubuntu（WSL）里，一条一条跑**：
   ```bash
   sudo apt-get update && sudo apt-get install -y usbmuxd libimobiledevice-utils zip
   chmod +x /mnt/c/Users/<你的用户名>/Downloads/xtool-x86_64.AppImage
   sudo mv /mnt/c/Users/<你的用户名>/Downloads/xtool-x86_64.AppImage /usr/local/bin/xtool
   cp /mnt/c/Users/<你的用户名>/Downloads/resign.sh ~/resign.sh && chmod +x ~/resign.sh
   sudo service usbmuxd stop
   export USBMUXD_SOCKET_ADDRESS=$(ip route show default | awk '{print $3}'):27016
   ideviceinfo | head -3        # 手机插上、解锁，出现 ActivationState 就是通了
   xtool auth                   # 选 1（Password），用一个小号 Apple ID
   xtool install /mnt/c/Users/<你的用户名>/Desktop/WatchPipe.ipa   # 问是否吊销旧证书 → yes
   ```
   （`export` 只对当前窗口有效，`xtool install` 要在同一个窗口里跑。）
4. **手机上**：设置 → 通用 → VPN与设备管理 → 信任；iOS 16+ 还要 设置 → 隐私与安全性 → 开发者模式（开完重启）。
5. **打开 WatchPipe**：填接口地址（默认已填）和令牌（在 VPS 的 `/root/health/secret.txt`，或问珩），保存 → 点「授权读取健康数据」全部允许 → 看日志。
   看到一排 **「后台投递已开」** 就成了；看到「后台投递未开 Missing … entitlement」就是装的不是补丁版 xtool 签的包。

## 每七天（两分钟）
手机插上电脑、解锁，双击桌面上的 `resign.bat`，装完在手机上信任一次证书。数据不会丢，队列还在，重签后自动补传。
建议手机日历设一个「每 6 天」的提醒。

## 加新指标
`HealthSync.swift` 里那张表加一行，例如体温：
```swift
.init(name: "body_temperature", id: .bodyTemperature, unit: .degreeCelsius(), label: "degC"),
```
字段名和单位标签要和服务端一致；新增后健康 App 会要求再授权一次；第一次只补最近 24 小时。

## 出问题先查这里
| 症状 | 先看 |
|---|---|
| app 打不开 / 闪退 | 签名过期了，续签 |
| 日志停在很久以前 | 低电量模式、后台 App 刷新被关、手表没戴 |
| 一直 HTTP 403 | 令牌不对，app 里重填 |
| 一直 HTTP 404 | 地址填错 |
| 「待发送」一直涨 | 上传一直失败，看最后一条失败原因 |
| 「后台投递未开」 | 装的不是补丁版 xtool 签的包 |

服务端有断流告警：超过一天没收到任何上传，珩那边心跳第一行会报 ⚠️。
