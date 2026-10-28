# 斐讯麦（FeiXunMai）

把 **斐讯 T1/N1 蓝牙语音遥控器**（RTL_618 方案）变成 Mac 的无线麦克风 + 空气鼠标，
对标 [无线麦 SayAll（remote-mic-app）](https://github.com/HD838A/remote-mic-app) 与
OpenAI × Work Louder 的 [Codex Micro](https://worklouder.cc/codex-micro) 的思路：
**一个语音键指挥 AI，几个实体键控制电脑**。

整个安装包约 300 KB，纯苹果原生技术栈（Swift / AppKit / CoreBluetooth / AVFoundation），
无任何第三方 Swift 依赖。

![截图占位](docs/按键设计.md)

## 功能

**语音（按住说话，松开结束）**
- 遥控器语音经 BLE Kehwin 私有协议推送 mSBC 16 kHz 音频，本机解码后送入虚拟麦克风；
- 语音开始时自动合成 Fn 长按（可换 ⌘/⌥/F5 直连/点按切换），拉起豆包、微信输入法等语音入口；
- 语音期间系统默认输入自动切到虚拟麦克风，松开自动还原——**遥控器语音与键盘语音互不干扰**；
- 自带豆包专属虚拟声卡 **FeiXunV 2ch**（USB transport，豆包可自动识别）。

**按键**
- 方向键 = 鼠标移动（按住加速）；OK = 鼠标左键（按住可拖动）；
- 菜单 = 回车；返回 = 删除（按住连删）；主页 = Esc；OTT 电源 = 粘贴 ⌘V；
- 全部可在界面重映射（回车 / Esc / 删除 / 复制 / 粘贴 / 左右键 / 调度中心 / 锁屏 / 屏蔽）；
- 音量键走系统直通；TV 电源为红外，不经过 Mac；
- 语音键的 F5 回声自动吞掉，不会误触系统听写或其他语音工具。

**其他**
- 菜单栏常驻 + 设置窗口（纯 AppKit，原生标签页）；
- 本地统计（语音次数/时长），不上传任何数据；
- 语音通道 30 秒保活 + 订阅自检 + 睡眠唤醒自愈，长期待机也能即按即说。

## 硬件与系统要求

- Mac（Apple Silicon / Intel），macOS 13+；
- 斐讯 T1/N1 原装遥控器（`斐讯遥控器`，HID + Kehwin 1920 服务）；
- 配对方式：同时长按 **主页 + 音量减**，在系统蓝牙里连接。

## 安装

1. 双击 `dist/斐讯麦安装包-0.3.0.pkg`（内含 斐讯麦.app + FeiXunV 2ch + BlackHole 2ch 两个虚拟声卡）；
2. 允许「蓝牙」权限；
3. 语音应用的麦克风设为 **“自动 / 跟随系统默认”**（不要固定选某个设备）；
4. 按住遥控器语音键说话即出字；需要 Fn 模拟时再授予「辅助功能」权限。

构建（可选，从源码）：

```zsh
./scripts/build-app.sh    # 产出 dist/斐讯麦.app、zip、dmg 和总安装包 pkg
```

## 工作原理

```
遥控器语音键 ─┬─ GATT 07fc01/07fc07 + mSBC 音频流 → libsbc 解码 → 0.4s 门槛（滤掉点按毛刺）
              │                                      → 缓冲排空 → FeiXunV/BlackHole 虚拟麦克风
              └─ HID F5 回声（合成模式下吞掉）
语音开始 ────┬─ 合成 Fn 按下（结束 +0.35s 排空后松开）
             └─ 系统默认输入 → 虚拟麦克风；松开后还原真实麦克风
其余按键 ─────  HID 报告层"布防-拦截"：只处理遥控器（VID 0x005D）的键，
                真键盘的同键码按键永远直通
```

更多设计与实测数据见 [docs/](docs/)：
[按键设计](docs/按键设计.md) ·
[遥控器能力摸底](docs/遥控器能力摸底.md) ·
[对标梳理](docs/对标梳理.md) ·
[经验教训](docs/经验教训.md) ·
[HID 验证计划](docs/HID验证计划.md)

## 已知限制

- 按住语音键说话期间，返回/主页/菜单暂不响应（固件在推流时暂停消费键上报，松开即恢复）；
- 遥控器固件偶发按键无响应时，扣电池重装即可恢复（RTL_618 固件已知问题）；
- 语音触发键若使用修饰键（⌘/⌥）可能与目标应用快捷键冲突，默认 Fn 一般最稳。

## 隐私

不联网、不上传；语音只在本地解码转发，统计只存本机 UserDefaults。

## 许可与致谢

- 本项目代码：MIT（见 [LICENSE](LICENSE)）；
- [BlackHole](https://github.com/ExistentialAudio/BlackHole)（Existential Audio）：
  FeiXunV 2ch / BlackHole 2ch 虚拟声卡基于其 v0.7.1 修改，遵循 **GPL-3.0**，
  修改后源码见 [driver/BlackHole-0.7.1](driver/BlackHole-0.7.1/)；
- [google/libsbc](https://github.com/google/libsbc)：mSBC 解码（Apache-2.0）；
- [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app)：架构参考与
  大量踩坑经验的来源（HID 布防-拦截、语音门槛、排障思路）。
