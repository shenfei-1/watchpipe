#!/usr/bin/env bash
# WSL 里跑：手机插在 Windows 上、解锁，然后双击 resign.bat 就会调到这里。约两分钟。
set -e
IPA=$(ls -t /mnt/c/Users/*/Desktop/WatchPipe.ipa /mnt/c/Users/*/OneDrive/*/WatchPipe.ipa /mnt/c/Users/*/Downloads/WatchPipe.ipa 2>/dev/null | head -1 || true)
[ -n "$IPA" ] || { echo "没找到 WatchPipe.ipa，放到桌面或下载文件夹"; exit 1; }
echo "用这个包：$IPA"
sudo service usbmuxd stop 2>/dev/null || true
export USBMUXD_SOCKET_ADDRESS=$(ip route show default | awk '{print $3}'):27016
ideviceinfo 2>/dev/null | grep -q ActivationState || { echo "手机没连上：检查数据线、手机解锁、Windows 上 portproxy 27016→27015"; exit 1; }
xtool install "$IPA"
echo
echo "装好了。手机上：设置 → 通用 → VPN与设备管理 → 信任；然后打开 WatchPipe 看日志有没有「后台投递已开」。"
