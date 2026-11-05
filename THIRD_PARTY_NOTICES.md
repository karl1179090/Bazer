# 来源与许可记录

Bazer 的新增实现采用 GNU General Public License version 3 or later（`GPL-3.0-or-later`）。根目录 `LICENSE` 保留参考工程提供的 GPLv3 许可全文，包括其既有作者记录。

## FerrisPulse

- 项目：[Ferris-echo/FerrisPulse](https://github.com/Ferris-echo/FerrisPulse)
- 只读本地参考：`/Users/karl/Desktop/Project/FerrisPulse`
- 固定提交：`eccb3802eef1aef036d17e65bc57ce1621884461`
- 上游许可：GPLv3；上游许可文本中列出的作者：`Copyright (C) 2026 Zhaopf`。其余贡献者及历史署名保留在上游项目中。
- 参考范围：`src/Hardware/RazerDeviceHelper.cs` 中 `CalculateCrc`、`CreateRazerReport`（约 1081 行）与电量 `07/80`、充电 `07/84` 的命令字段及 `arguments[1]` 取值（约 1244 行）。
- 对应 Bazer 文件：`Sources/RazerProtocol/RazerPacket.swift`。这是 Swift 独立实现，移除 Windows 前导占位，固定当前配置的 90 字节帧，补齐长度、单帧结构、协议类型、payload、命令、事务、保留字段、XOR 与成功状态校验。
- 没有迁移上游默认 50%、排除 raw=0、至少 1% 夹值、失败推断休眠、DPI/回报率附带查询、通用字节猜电量或 Windows UI/Win32 实现。
- 未修改上游目录或 Git 工作区，也未复制其错误的 `00C4/00C5` 型号命名表。

## 本机被动描述符

`docs/evidence/hid-baseline-2026-11-03.json` 由本机只读 IORegistry 采集，未打开 HID、未采集输入报告、未包含序列号。测试 fixture 仅保留该快照的目标描述符与非唯一产品属性；真实 Registry ID、Location ID 和端口信息不进入回放 fixture。物理父节点的合成标签表达期望分组，不是实际 Registry ID。

## OpenRazer

- [razerchromacommon.c](https://github.com/openrazer/openrazer/blob/master/driver/razerchromacommon.c)、[razermouse_driver.c](https://github.com/openrazer/openrazer/blob/master/driver/razermouse_driver.c)、[razermouse_driver.h](https://github.com/openrazer/openrazer/blob/master/driver/razermouse_driver.h)。文件头为 `GPL-2.0-or-later`，保留来源署名 `Copyright (c) 2015 Terri Cain`。
- 用于核对固件、DPI、档位、传统/扩展回报率字段与 00C5 的具体分支。对应独立 Swift 实现为 `Sources/RazerProtocol/RazerSettings.swift` 及 `Sources/BazerHID/HIDFeatureTransport.swift`，没有引入 Linux 驱动或运行依赖。
- 读取的原始内容以规划基线 JSON 中 SHA256 为准：common `23bc58cf7a1d8c91a6f397087b55ff897340c68d76be48e01f2e2b9274d8c9bf`；mouse `6489dcdfc3cd31f284f379b332882f91beb2fe38bd7b1f3c8e8c05bdf2b3d562`；header `dac1063ae7a74d689b1d4915cae61ef5f4d940d160bf9196533715d31b4923a4`。可变 master 链接不是固定修订声明。

## Logitech HID++ 资料与一手实现

- [Logitech cpg-docs](https://github.com/Logitech/cpg-docs/tree/f9107a4e3190d798f9be8c5d596f255f5e5741d2/hidpp20)，修订 `f9107a4e3190d798f9be8c5d596f255f5e5741d2`：报文结构、Root、ping 和 feature lookup；没有将其他 feature 伪称为官方完整公开规格。
- [Solaar](https://github.com/pwr-Solaar/Solaar/tree/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver)，本轮新增 receiver/base 参考的修订 `e7304c4c451cc9bb4f206a914844525e67856a28`；原规划的 hidpp20/settings 内容另由规划基线 SHA256 固定。文件声明 `GPL-2.0-or-later`，署名 Daniel Pavel、Solaar Contributors。核对动态 feature、身份、电量、DPI、回报率和 receiver 分支。GPW1 百分比估算另采用下述固定来源的通用电压曲线。
- [libratbag hidpp20.c](https://github.com/libratbag/libratbag/blob/8235b5bb6032dea15901ab58a8218956f4494d08/src/hidpp20.c) / [hidpp20.h](https://github.com/libratbag/libratbag/blob/8235b5bb6032dea15901ab58a8218956f4494d08/src/hidpp20.h)，修订 `8235b5bb6032dea15901ab58a8218956f4494d08`，用于核对已知 profile 3 布局、CRC、完整 sector 读写；原规划 C 文件内容以基线 SHA256 `e85d52969160b292bdfdd96fd6c54a4f20bc12e5e3c7af9aaece967d3b17ed55` 固定。上游文件的 MIT 署名与许可如下。
- [Linux hid-logitech-hidpp.c](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-logitech-hidpp.c) 仅核对 Unified Battery 能力位等协议事实。文件头 `GPL-2.0-only`，署名 Logitech、Google、Red Hat；未复制或分发 Linux 驱动代码。

对应实现为独立 `Sources/LogitechHIDPP` 与 macOS Input/Output transport。没有引入上述项目作为运行依赖；来源、字段和限制另见 `docs/evidence/logitech-source-design-2026-11-04.md`。上游支持不构成 Bazer 实机证据。

### GPW1 电压百分比估算的 Solaar 来源

- 来源：[`estimate_battery_level_percentage`](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/hidpp20.py#L2280-L2319)，固定修订 `e7304c4c451cc9bb4f206a914844525e67856a28`，读取文件 SHA256 `b6dfbd88bba8dcbf6b3eb2de5ea1345c2b02f56a67e23799a1b2a5c7f635aaa7`。
- 上游版权：`Copyright (C) 2012-2013 Daniel Pavel`；`Copyright (C) 2014-2024 Solaar Contributors https://pwr-solaar.github.io/Solaar/`。上游允许 GNU General Public License version 2 或任何后续版本；本项目适配以 `GPL-3.0-or-later` 分发，许可全文见根目录 `LICENSE`，保留无担保条件。
- 对应文件：`Sources/BazerDrivers/LogitechBatteryPercentageEstimate.swift`；采用 13 点通用曲线及相邻点插值，新增精确 GPW1 身份限定、仅正常放电估算、适用范围拒绝和 5% 显示步进。没有移植 Linux `GPL-2.0-only` 电压曲线/实现，也没有使用 FerrisPulse 电量算法。
- 这是未针对 GPW1 本机校准的通用估算，不是硬件原生 SOC。测得 mV/raw/source 保留，估算单独编码为 `percentageEstimate`，显示带“约”，百分比通知不使用估算。

### libratbag MIT notice

Copyright 2015 Benjamin Tissoires <benjamin.tissoires@gmail.com>
Copyright 2015 Red Hat, Inc

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice (including the next
paragraph) shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
