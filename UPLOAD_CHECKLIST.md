# HMLight GitHub 上传清单（GPLv3 合规）

> 原则：只要最终 HAP 里包含了某份代码，就必须提供对应源码。
> 本工程链接了 moonlight-common-c、ENet、mbedTLS、Opus、nanors，因此这些第三方源码必须随仓库提供（或使用固定 commit 的 submodule + 我们对 moonlight-common-c 的补丁）。

## 一、必须上传（源码与构建配置）

### 根目录
- [ ] `AppScope/app.json5`
- [ ] `AppScope/resources/**`（应用名、深浅色图标、startIcon）
- [ ] `build-profile.json5` **（上传前删除 signingConfigs / 密码字段）**
- [ ] `hvigorfile.ts`
- [ ] `code-linter.json5`
- [ ] `oh-package.json5`
- [ ] `oh-package-lock.json5`
- [ ] `hvigor/hvigor-config.json5`（若存在）
- [ ] `LICENSE`（GPLv3 全文，需新增）
- [ ] `README.md`（构建步骤、依赖、非官方声明、源码地址、修改说明，需新增）
- [ ] `NOTICE` 或 README 中的第三方许可证清单（需新增）
- [ ] `UPLOAD_CHECKLIST.md`（本文件）

### entry 模块
- [ ] `entry/build-profile.json5`（externalNativeOptions 等，确认无签名信息）
- [ ] `entry/hvigorfile.ts`
- [ ] `entry/oh-package.json5`
- [ ] `entry/oh-package-lock.json5`
- [ ] `entry/obfuscation-rules.txt`
- [ ] `entry/src/main/module.json5`
- [ ] `entry/src/main/resources/**`（字符串、颜色、深浅色资源、图标、main_pages）
- [ ] `entry/src/main/ets/**`（12 个文件：EntryAbility、页面、服务、主题、路由参数等）
- [ ] `entry/src/main/cpp/CMakeLists.txt`
- [ ] `entry/src/main/cpp/types/libmoonbridge/**`（NAPI 类型声明）
- [ ] `entry/src/main/cpp/bridge/**`（11 个文件：bridge_napi、nvhttp、videodec、audiodec、diag、gamepad 及头文件）

### 第三方源码（必须）
- [ ] `entry/src/main/cpp/third_party/moonlight-common-c/**`（已修改，见下）
- [ ] `entry/src/main/cpp/third_party/enet/**`
- [ ] `entry/src/main/cpp/third_party/mbedtls/**`
- [ ] `entry/src/main/cpp/third_party/opus/**`
- [ ] `entry/src/main/cpp/third_party/nanors/**`

> 若改为 submodule：必须额外提供 `patches/0001-udp-rx-counter.patch`，并在 README 写明固定 commit 与 patch 应用步骤。

### 其他建议上传
- [ ] `scripts/setup_deps.sh`（依赖拉取脚本）
- [ ] `patches/0001-udp-rx-counter.patch`（moonlight-common-c 的修改补丁，已生成）
- [ ] `Icon/`（原始 1024 设计稿：深浅图标 + splash_logo）
- [ ] `scripts/moonlight_diag.sh`（可选，诊断采集脚本）

## 二、禁止上传

- [ ] `entry/build/`、`.hvigor/`、`oh_modules/`、`.idea/`、`.cxx/`
- [ ] `.sign/`（含签名配置）
- [ ] `local.properties`（本机 SDK 路径）
- [ ] 任何 `*.p12`、`*.p7b`、`*.cer`、`*.csr`、`*.hap`
- [ ] `build-profile.json5` / `.sign` 中的签名密码与证书路径
- [ ] `diagnostics/`（用户日志采集产物）
- [ ] `moonlight-android-12.2/`（仅作参考，非本工程构建所需；如要保留请说明用途）
- [ ] 备份包、`moonlight_backups/`、`.DS_Store`

## 三、上传前必须处理的敏感项

1. `build-profile.json5` 的 `signingConfigs` 整段删除（或替换为 README 中的占位示例）
2. `entry/build-profile.json5` 检查是否含本机绝对路径
3. 搜索 `/Users/<用户名>`，全部改为相对路径或文档说明
4. 搜索签名密码相关字段（password / keyPassword / storePassword），确认无残留
5. 删除 third_party 内的 `.git` 目录（体积与嵌套仓库问题）：
   `find entry/src/main/cpp/third_party -name .git -type d -prune -exec rm -rf {} +`

## 四、GPLv3 合规要点

- [ ] 仓库根目录放置 GPLv3 全文
- [ ] README 注明：基于 Moonlight（GPLv3）修改，列出主要修改点
- [ ] 应用「关于」页中的源码地址与仓库地址一致
- [ ] 保留第三方许可证文件：
  - moonlight-common-c：GPLv3
  - mbedTLS：Apache-2.0
  - Opus：BSD-3-Clause
  - ENet：MIT
  - nanors：MIT
- [ ] 不使用 Moonlight 官方名称/图标作为产品名与图标；关于页保留事实性署名

## 五、已修改文件（需在 README 中列出）

- `entry/src/main/cpp/third_party/moonlight-common-c/src/PlatformSockets.c`：新增 UDP 接收字节计数接口
- `entry/src/main/cpp/bridge/nvhttp.cpp`：mTLS 客户端证书、配对、launch、appasset、UDP 读取上限修正
- `entry/src/main/cpp/bridge/videodec.cpp`：Native AVCodec Surface 解码、关键帧等待、色彩范围
- `entry/src/main/cpp/bridge/audiodec.cpp`：Opus 多流 + OHAudio、立体声/5.1/7.1
- `entry/src/main/cpp/bridge/bridge_napi.cpp`：NAPI 桥、输入、诊断、控制器
- `entry/src/main/cpp/bridge/diag.cpp`：默认关闭的 JSONL 诊断（开发者模式）
- `entry/src/main/ets/**`：全部 UI、设置、主题、应用列表、串流页

## 六、建议的仓库结构

```
README.md
LICENSE
NOTICE
UPLOAD_CHECKLIST.md
AppScope/
build-profile.json5        # 无签名信息
hvigorfile.ts
oh-package.json5
entry/
  build-profile.json5
  oh-package.json5
  src/main/
    ets/
    resources/
    module.json5
    cpp/
      CMakeLists.txt
      bridge/
      types/
      third_party/          # 或 submodule + patches/
scripts/
Icon/
```
