# Bazer

<p align="center">
  <strong>专为 macOS 打造的轻量级原生外设遥测与配置工具</strong><br>
  摆脱臃肿的厂商驱动，在 macOS 菜单栏轻松管理雷蛇（Razer）与罗技（Logitech）鼠标的电量与板载参数。
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPLv3-blue.svg" alt="License: GPLv3"></a>
  <a href="https://developer.apple.com/swift/"><img src="https://img.shields.io/badge/Swift-6.0-orange.svg" alt="Swift 6.0"></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg" alt="macOS 13+"></a>
  <img src="https://img.shields.io/badge/Tests-458%20passed-brightgreen.svg" alt="458 Tests Passed">
</p>

---

## 📖 简介 (Overview)

**Bazer** 是一款采用 Swift 6、SwiftUI 与 IOKit 开发的 macOS 原生菜单栏外设工具。无需安装官方笨重的控制软件（如 Razer Synapse 或 Logitech G HUB），即可在 macOS 上实现无线鼠标电量常驻监控、参数调节（DPI、回报率、XY 轴独立灵敏度）以及板载配置的固化写入与恢复。

### ✨ 核心特性

- 🪶 **轻量无感知**：纯 Swift 原生开发，无后台长驻守护进程（Daemon），内存占用仅约 20~30 MB，CPU 占用日常接近 0%。
- 🔋 **菜单栏电量监控**：主设备电量实时常驻菜单栏，支持充电状态展示、低电量原生横幅通知，以及蓝牙音频设备的电量整合。
- ⚙️ **外设板载配置**：支持 DPI 档位配置、独立 X/Y 轴灵敏度调节、回报率（Polling Rate）切换，直接写入硬件板载存储，断电不丢失。
- 🔀 **多设备拓扑与接收器隔离**：准确识别 2.4G 无线接收器及其下的逻辑子设备；按物理设备进行严格事务锁隔离，多鼠标同时刷新互不干扰。
- 🛡️ **安全与防御式设计**：严格事务互斥、状态回读校验；不盲目重试，确保硬件安全。
- 🔍 **内置诊断工具 (`HIDProbe`)**：自带命令行硬件嗅探与诊断工具，支持无侵入设备枚举、报文调试与连续采样。

---

## 🤝 协议来源与致谢 (Credits & Acknowledgements)

本项目中雷蛇与罗技外设的协议识别、HID 报文定义及通信规范，核心来源于开源项目：

> **[FerrisPulse (https://github.com/Ferris-echo/FerrisPulse)](https://github.com/Ferris-echo/FerrisPulse)**

在 [FerrisPulse](https://github.com/Ferris-echo/FerrisPulse) 的协议定义与设备识别逻辑基础上，Bazer 使用现代 Swift 进行了针对 macOS IOKit 的独立重构与实现：
1. **雷蛇协议 (Razer Protocol)**：基于 FerrisPulse 整理的 Report 报文结构与 CRC 校验，在 `Sources/RazerProtocol` 中实现了 90 字节固定报文封装、电量/充电状态双查询、多档位及扩展回报率控制。
2. **罗技 HID++ 协议**：参考 FerrisPulse 与官方规范，在 `Sources/LogitechHIDPP` 中构建了 HID++ 2.0/4.0+ 的异步报文交互模型与 Feature 动态发现机制。

**同时特别感谢以下开源社区成果：**
- [OpenRazer](https://github.com/openrazer/openrazer)：用于交叉比对雷蛇部分型号的固件与扩展回报率分支。
- [Solaar](https://github.com/pwr-Solaar/Solaar)：罗技无线电量百分比通用非线性放电曲线与 Feature 定义参考。
- [libratbag](https://github.com/libratbag/libratbag)：罗技 Profile 3 板载配置与 Sector 校验规范参考。
- [Logitech cpg-docs](https://github.com/Logitech/cpg-docs)：罗技 HID++ 2.0 基础规范文档。

---

## 🖱️ 设备支持矩阵 (Supported Devices)

| 设备型号 | 连接方式 / 识别码 | 电量与充电监控 | 参数配置 (DPI / 回报率) | 板载持久化 | 验证状态 |
| :--- | :--- | :---: | :---: | :---: | :---: |
| **Razer DeathAdder V3 HyperSpeed** | 2.4G 接收器 (`1532:00C5`) | ✅ 精确 % / 充电状态 | ✅ 400~3200 DPI、独立 XY、125/500/1000Hz | ✅ 物理断电保持 | 实机完整验证 (FW 1.10) |
| **Logitech G PRO Wireless (一代)** | Lightspeed 接收器 (`046D:C539`) | ✅ 电压估算 % (Solaar 曲线) | ✅ 255B Profile 档位、500/1000Hz | ✅ 物理断电保持 | 实机完整验证 (WPID 4079) |
| **蓝牙耳机 / 音频设备** | 系统 Bluetooth 协议 | ✅ 电池电量展示 | — | — | 实机验证 (build6+) |
| **NUT65 键盘** | USB 有线 (`342D:E51A`) | ⚠️ 显示识别（不发探测） | — | — | 实机被动识别 |
| **更多雷蛇/罗技型号** | 2.4G / 有线 | 持续接入扩展中 | 基于协议标准实现 | 需验证支持 | 欢迎提交 Issue / PR |

---

## 🚀 快速上手 (Getting Started)

### 系统要求

- macOS 13.0 (Ventura) 及以上版本
- Apple Silicon (M 系列芯片) 或 Intel 架构
- Command Line Tools 或 Swift 6.0+ 工具链（无需完整 Xcode）

### 源码编译与本地安装

```bash
# 1. 克隆代码仓库
git clone https://github.com/karl/Bazer.git
cd Bazer

# 2. 编译 Release 产物并打包 .app
./scripts/build-app.sh

# 3. 安装到 ~/Applications 目录
./scripts/install-local.sh

# 4. 启动应用
open "$HOME/Applications/Bazer.app"
```

### 权限配置 (macOS TCC)

macOS 针对高权限 USB/HID 通信有严格的输入安全限制：
1. 启动应用后，若提示权限不足或状态显示异常，请前往 **系统设置 → 隐私与安全性 → 输入监控 (Input Monitoring)**。
2. 解锁并确保勾选允许 `Bazer.app`。
3. 若重新授权后由于系统缓存仍未生效，可通过终端执行局部重置：
   ```bash
   tccutil reset ListenEvent local.karl.Bazer
   ```
   随后在“输入监控”中重新勾选并重启应用。

---

## 🛠️ 诊断工具 (`HIDProbe`)

Bazer 内置了强大的 CLI 硬件排障工具 `HIDProbe`，方便在不启动图形界面的情况下查看硬件状态与通信报文：

```bash
# 列出当前所有识别到的外设与 HID 接口
swift run HIDProbe list --json

# 监听外设热插拔事件 (持续 30 秒)
swift run HIDProbe watch --duration 30 --json

# 查看特定设备的描述符与接口细节
swift run HIDProbe inspect --vid 1532 --pid 00C5 --json

# 测试特定设备的电量读取 (采样 10 次，间隔 2 秒)
swift run HIDProbe battery --vid 1532 --pid 00C5 --samples 10 --interval 2 --json
```

---

## 🏗️ 架构与模块划分 (Architecture)

Bazer 遵循清晰的分层解耦设计，各个 Swift 模块职责分明：

```
Bazer/
├── Sources/
│   ├── BazerCore/         # 基础模型、拓扑抽象、采样状态与配置偏好
│   ├── RazerProtocol/     # 雷蛇协议封装 (报文编解码、校验和、DPI/回报率指令)
│   ├── LogitechHIDPP/     # 罗技 HID++ 2.0/4.0+ 报文协议与 Feature 解析
│   ├── BazerHID/          # IOKit HID 传输层、独立线程调度、物理设备锁管理
│   ├── BazerDrivers/      # 品牌驱动适配层、BatteryMonitor 统一管理服务
│   ├── BazerApp/          # 原生 SwiftUI 菜单栏界面、设置面板与通知集成
│   └── HIDProbe/          # 命令行诊断与硬件测试工具
└── Tests/                 # 450+ 离线单元测试与 Mock Fixtures
```

---

## 🧪 开发与测试 (Development)

本项目推行严格的测试驱动与离线模拟验证机制：

```bash
# 运行离线测试套件
./scripts/test.sh
```

- **纯逻辑替身**：测试套件采用官方 Swift Testing 框架，所有测试均使用模拟数据（Mock Fixtures），不会触发真实硬件读写、系统通知或登录项操作。
- **并发锁与稳定性**：包含对多设备并发刷新锁竞争、长时间运行内存与 CPU 轨迹的严格回归校验。

---

## 📄 开源许可证 (License)

本项目采用 **GNU General Public License v3.0 (GPLv3)** 许可证。详情请参阅 [LICENSE](LICENSE) 文件。

第三方代码及参考资料署名见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
