# HMLight

HarmonyOS NEXT 上的 Moonlight 游戏串流客户端。

> **非官方项目。** 本项目基于 [Moonlight](https://github.com/moonlight-stream/moonlight-common-c)
> 的协议实现修改而来，与 Moonlight 官方不存在隶属、赞助或背书关系。
> 项目名称、图标均为自有，不使用 Moonlight 的名称与图标作为产品标识。

---

## 特性

- 主机管理：手动添加 IP、配对、长按删除
- 应用列表：从主机拉取可串流应用，支持自定义封面
- 串流：H.264 / H.265 硬件解码（AVCodec → Surface 零拷贝），支持 1080p 及更高分辨率
- 音频：Opus 解码 + OHAudio 低延迟输出，支持立体声 / 5.1 / 7.1
- 输入：触摸（虚拟鼠标）、物理手柄
- 界面：浅色 / 深色主题，深浅色两套应用图标
- 诊断：开发者模式下可开启 JSONL 日志（默认关闭，不写入任何网络内容）

## 环境要求

| 项 | 要求 |
| --- | --- |
| 开发环境 | DevEco Studio，HarmonyOS SDK **26.0.0** 及以上 |
| 编译目标 | `compatibleSdkVersion 26.0.0` / `targetSdkVersion 26.0.1` |
| 设备 | HarmonyOS NEXT 手机或平板，**arm64-v8a** |
| 服务端 | [Sunshine](https://github.com/LizardByte/Sunshine)（NVIDIA GameStream 已停止服务） |

> 本工程只编译 `arm64-v8a`，不支持 32 位设备。

## 构建

1. 用 DevEco Studio 打开本工程
2. `File → Project Structure → Signing Configs`，勾选 **Automatically generate signature**（需登录华为账号）
3. `Build → Build Hap(s) / App(s)`

或使用命令行（需先配置好签名）：

```bash
hvigorw assembleHap --mode module -p product=default
```

> 仓库中**不包含**任何签名材料（证书、profile、密码），这是有意为之。
> 未配置签名时构建会失败，属预期行为。

## 目录结构

```
AppScope/                  应用级配置与图标资源
entry/
  src/main/ets/            ArkTS 界面与服务（页面、主题、主机存储、NAPI 封装）
  src/main/resources/      字符串、颜色、图标、启动页
  src/main/cpp/
    CMakeLists.txt         原生构建入口
    bridge/                NAPI 桥：nvhttp / videodec / audiodec / gamepad / diag
    types/                 NAPI 类型声明（libmoonbridge）
    third_party/           随仓库分发的第三方源码（见下）
patches/                   对 upstream 的补丁
scripts/                   依赖拉取与诊断采集脚本
Icon/                      图标设计稿
```

## 第三方源码

`third_party/` 下的源码**随仓库直接分发**，不使用 submodule，克隆后无需额外拉取：

| 组件 | 许可证 | 版本 |
| --- | --- | --- |
| moonlight-common-c | GPL-3.0 | `94c65fd`（含本项目补丁） |
| ENet | MIT | `98dbb89` |
| Mbed TLS（含 framework） | Apache-2.0 / GPL-2.0-or-later | `82e6999` / `ced3149` |
| Opus | BSD-3-Clause | `31b4b36` |
| nanors | MIT | `a9b1636` |

完整 commit、来源与许可证见 [`entry/src/main/cpp/third_party/VERSIONS.md`](entry/src/main/cpp/third_party/VERSIONS.md)
与 [`NOTICE`](NOTICE)。

> `scripts/setup_deps.sh` 仅用于**从零初始化** `third_party/`。本仓库已包含全部源码，
> 目录非空时脚本会自动跳过，正常开发无需运行它。

## 修改说明

相对 upstream 的主要修改：

- `third_party/moonlight-common-c/src/PlatformSockets.c`
  新增 UDP 接收字节计数接口（供诊断页统计码率）
- `bridge/nvhttp.cpp`
  mTLS 客户端证书生成与持久化、配对流程、`launch` / `appasset` 请求、UDP 读取上限修正
- `bridge/videodec.cpp`
  改用 HarmonyOS Native AVCodec + Surface 输出，加入关键帧等待与色彩范围处理
- `bridge/audiodec.cpp`
  Opus 多流解码 + OHAudio 输出，支持立体声 / 5.1 / 7.1
- `bridge/bridge_napi.cpp`
  NAPI 桥接层、输入事件、控制器、诊断接口
- `bridge/diag.cpp`
  JSONL 诊断日志（默认关闭，仅在开发者模式开启）
- `entry/src/main/ets/**`
  全部界面：主页、应用列表、串流页、设置、帮助、封面裁剪、主题

## 许可证

本项目以 **GNU General Public License v3.0** 发布，全文见 [LICENSE](LICENSE)。

由于链接了 GPLv3 的 moonlight-common-c，本项目整体（含所有修改）同样以 GPLv3 授权。
分发二进制时请同时提供对应源码。

## 已知限制

- 仅支持 arm64-v8a
- 未实现 HDR 串流
- 未实现自动发现（需手动输入主机 IP）
- 未实现多显示器 / 多会话切换
- 诊断日志默认关闭，需在设置页连点版本号进入开发者模式后开启

## 反馈

欢迎提交 Issue。涉及串流问题请附上：设备型号、HarmonyOS 版本、服务端类型与版本、
以及开发者模式导出的诊断日志（请先自行检查其中是否包含不希望公开的网络信息）。
