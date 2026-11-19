# Git 提交清单（HMLight，第二轮修订）

> 原则：**不删除本地文件**，只通过 `.gitignore` + 精确的 `git add` 控制进仓库的内容。
> 关键：`third_party` 里 5 个目录含 `.git`，**不要使用 `git add -A` / `git add third_party`**，
> 否则 git 会把它们记成 submodule（`mode 160000`），源码不会进仓库。

## 0. 风险说明（先看）

- 在 `git push` 之前，所有操作都可撤销（删文件、改提交都能恢复）。
- 真正不可逆的是 **把敏感信息 push 到公开仓库**：之后即使 force-push，缓存/镜像仍可能保留。
- 因此：先 `git add`、再跑验收命令、再 `git commit`，最后才 `git push`。
- 如果误把 `.git` 目录加成了 submodule：`git rm --cached <dir>` 后按第 3 节重新添加即可，本地源码不受影响。

## 1. 首次初始化

```bash
git init
git config user.name  "Entai23"
git config user.email "Entai23@users.noreply.github.com"
```

## 2. 应提交内容

### 构建与配置

```bash
git add .gitignore entry/.gitignore .clangd .clang-tidy
git add AppScope build-profile.json5 hvigorfile.ts code-linter.json5 \
        oh-package.json5 oh-package-lock.json5 hvigor
```

### entry 模块（含测试目录）

```bash
git add entry/build-profile.json5 entry/hvigorfile.ts \
        entry/oh-package.json5 entry/oh-package-lock.json5 \
        entry/obfuscation-rules.txt
git add entry/src/main/module.json5
git add entry/src/main/ets
git add entry/src/main/resources
git add entry/src/main/cpp/CMakeLists.txt
git add entry/src/main/cpp/bridge
git add entry/src/main/cpp/types
git add entry/src/ohosTest entry/src/test entry/src/mock
```

### 第三方源码（GPL 合规，必须）

`.git` 元数据已移除（6 个，含 gitfile；备份：`~/moonlight_backups/third_party_git_dirs.tar.gz`），
因此可以直接整目录添加：

```bash
git add entry/src/main/cpp/third_party
```

> ⚠️ 禁止再用 `find ... | xargs git add`：目录内只要存在 `.git`（哪怕是 gitfile），
> git 会**静默跳过**其下所有文件，`exit 0` 且无任何警告。
> 同理禁止在 `.git` 存在时 `git add` 目录——那会写成 `mode 160000` 的 submodule 指针。
> 版本信息见 `entry/src/main/cpp/third_party/VERSIONS.md`。

### 文档、补丁、素材

```bash
git add UPLOAD_CHECKLIST.md GIT_PUBLISH_LIST.md
git add patches
git add scripts
git add Icon
```

### 待补充（提交硬前置）

- `LICENSE`：GPLv3 全文
- `README.md`：非官方声明、构建步骤、依赖说明、源码地址、修改点
- `NOTICE`：第三方许可证（moonlight-common-c GPLv3 / mbedTLS Apache-2.0 / Opus BSD-3 / ENet MIT / nanors MIT）

## 3. 不应提交（已在 `.gitignore`，本地保留）

- `.sign/`（已移出本地工程）
- `diagnostics/`（已移出本地工程）
- `PRIVACY_AUDIT*.md`（两份审查文件，本地保留）
- `local.properties`、`.idea/`、`entry/build/`、`.hvigor/`、`oh_modules/`、`.cxx/`
- `moonlight-android-12.2/`
- `*.p12` / `*.p7b` / `*.cer` / `*.hap` / `*.jsonl` / `hilog_*.txt`
- `__pycache__/`、`*.pyc`（本地保留，不删除）

## 4. 可选瘦身（不做也不影响合规）

```bash
# 确认不参与构建后再执行；默认不执行
# rm -rf entry/src/main/cpp/third_party/mbedtls/tests
# rm -rf entry/src/main/cpp/third_party/opus/dnn/torch
```

## 5. 验收（`git add` 之后、`commit` 之前）

```bash
# 0) 计数断言：third_party 必须真的进来了（最容易被静默跳过）
git ls-files | grep -c "third_party"      # 期望 2931（实测），绝不能是 0
# 说明：磁盘上是 2936，少 5 个是上游自带 .gitignore 排除的
#   mbedtls/.gitignore 的 "Testing" → docs/architecture/testing/
#   opus/.gitignore 的 "Makefile"  → celt/dump_modes/Makefile
# 二者均不参与构建，属正常。


# 1) 不应有本机绝对路径
#    注意用带后缀的正则，否则会匹配到本文件里那条命令自身
grep -rnE "/Users/[A-Za-z0-9._-]+/" . \
  --exclude-dir=build --exclude-dir=oh_modules --exclude-dir=.hvigor \
  --exclude-dir=.cxx --exclude-dir=.idea --exclude-dir=.cache \
  --exclude-dir=moonlight-android-12.2 \
  --exclude="*.pyc" --exclude="PRIVACY_AUDIT*.md"

# 2) 不应有私网 IP（third_party 内为上游注释/测试向量，允许命中）
grep -rnE "192\.168\.[0-9]+\.[0-9]+" . \
  --exclude-dir=build --exclude-dir=oh_modules --exclude-dir=.hvigor \
  --exclude-dir=.cxx --exclude-dir=.idea --exclude-dir=.cache \
  --exclude-dir=moonlight-android-12.2 \
  --exclude="PRIVACY_AUDIT*.md"

# 3) 不应有签名密码
grep -rnE "keyPassword[[:space:]]*[:=]|storePassword[[:space:]]*[:=]" . \
  --exclude-dir=build --exclude-dir=oh_modules --exclude-dir=.hvigor \
  --exclude-dir=.cxx --exclude-dir=.idea \
  --exclude="PRIVACY_AUDIT*.md"

# 4) 不应有 submodule 指针（关键）
git ls-files -s | awk '$1=="160000"'
# 期望：无输出

# 5) 暂存区里不应出现敏感文件
git status --short | grep -E "\.sign/|diagnostics/|PRIVACY_AUDIT|\.jsonl|\.p12|\.p7b|\.cer|\.hap"
# 期望：无输出
```

## 6. 提交

```bash
git commit -m "Initial open-source release of HMLight (GPLv3)"
git branch -M main
git remote add origin https://github.com/Entai23/<repo>.git
git push -u origin main
```

## 7. 提交前人工确认

- [ ] `git ls-files | grep third_party | wc -l` 数量与本地文件数基本一致（不是 0/极少）
- [ ] `git ls-files -s | awk '$1=="160000"'` 无输出
- [ ] `build-profile.json5` 无 `signingConfigs`
- [ ] 仓库里没有 `.sign`、`diagnostics`、`PRIVACY_AUDIT*`
- [ ] `LICENSE` / `README.md` / `NOTICE` 已存在
- [ ] 「关于」页源码链接与仓库地址一致
