# 建大竞赛罗盘 · Compass 2

原生 HTML / CSS / JavaScript 的校园竞赛工具，带 Node.js 24 同源模型服务与 SQLite 试用额度管理。

## 本地运行

```powershell
npm run build
npm start
```

打开 `http://127.0.0.1:4173`。服务默认只监听本机。基础查询、目录比较、本机任务和规则参考无需模型密钥。

Windows 可双击根目录的 `启动竞赛罗盘.cmd`。它会检查已有服务，或启动独立后台预览进程，再打开页面。关闭命令窗口不会停止后台服务；电脑重启后可再次双击启动。本轮未添加开机自启。

运行时只使用 Node.js 内置模块。`npm ci` 安装的是浏览器验收所需开发依赖，不是运行服务的前提。

## 账号、云端计划与管理后台

正式站点右上角提供注册与登录。用户名使用 3—32 位字母、数字、下划线或短横线；密码至少 10 个字符。密码保存为独立盐值的 PBKDF2-SHA256 哈希，另有仅服务端持有的 `AUTH_PEPPER`。登录会话采用 HttpOnly、SameSite Cookie，正式 HTTPS 站点启用 Secure。

登录后，任务、收藏与画像按账号保存到服务端。首次登录如发现访客数据，会询问是否导入；成功导入后移到账号，避免退出后仍在访客页面显示。设备上的账号缓存与访客数据分开，多设备同时修改会触发版本冲突，允许选择本机或云端版本，并先下载被替换版本的备份。

旧卡密继续有效，但需要先登录再兑换。首次兑换后绑定账号，一张卡密只能属于一个账号；重复兑换不重置用量。多张卡密分别计算每日额度，管理员可另外赠送每日额度。账号停用后，所有会话失效。

管理入口是 `/#admin`，也可从右上角“我的账号”进入。只有服务器确认的管理员可以使用：用户状态与角色、每日赠送、临时密码重置、卡密生成、停用与每日额度调整。普通用户即使直接请求管理 API，也会被拒绝。密码重置会使其他会话失效，用户需先修改临时密码再访问私有数据。

初始管理员凭据保存在本机 `runtime/管理员账号.txt`，不应提交或公开。维护命令：

```powershell
npm run admin:setup
# 只有管理员密码丢失、且维护者持有部署管理凭据时，才显式恢复：
npm run admin:setup -- --recover
```

第一次设置不会覆盖现有管理员。恢复会生成新的随机密码并注销旧会话。正式站点没有邮箱验证或自动邮件找回服务，普通用户忘记密码由管理员在后台重置。

`AUTH_PEPPER` 是账号服务的长期秘密，创建账号后应保持稳定；直接替换它会导致原密码无法验证。生产值存于 Worker Secrets，本机值存于被忽略的 `.env`。本机 Node 预览与正式 Cloudflare 站点使用独立数据库；可用 `npm run admin:local` 初始化本机管理员，正式卡密仍应在线上发放。

账号与管理后台验证：`npm test`、`npm run test:accounts`。详细记录见 `docs/账号系统验收.md`。

## 模型配置

将 `.env.example` 复制为 `.env`，在本地编辑器填写：

```dotenv
LLM_BASE_URL=https://your-provider.example/v1
LLM_MODEL=your-model
LLM_API_KEY=your-private-key
```

`LLM_BASE_URL` 填到 `/v1` 等 API 基地址；服务会追加 `/chat/completions`。当前适配 Chat Completions，要求支持 `messages`、`max_tokens` 与非流式响应。供应商返回的文本需要是有效 JSON。

修改后重启服务。密钥只在服务端使用；不要写进网页、备份、Git 或聊天。`.env` 已被忽略。尚未配置时，页面明确提供基础推荐，不能视为 AI 结果。

### 发放与停用试用码

```powershell
npm run trial -- create 5
npm run trial -- list
npm run trial -- revoke 3
npm run report
```

创建时只显示一次原始试用码；数据库仅保存其哈希。`list` 显示编号与状态，`revoke 3` 停用编号 3 及其已有会话。勿把运行目录或原始试用码公开。

默认每码每天 3 次有效方案，全站每天最多 100 次上游调用，最多 2 个并发任务；均可在 `.env` 修改。日期按北京时间。失败不扣有效生成次数，但仍消耗模型调用额度。重复请求 ID 可重放已保存结果，不再次调用模型。

## 使用能力与事实边界

- **首页**：罗盘路径视觉、真实目录数量、本机下一项任务。
- **发现**：横向赛事目录、名称搜索、方向与单位筛选、收藏、最多三项比较、详情抽屉。手机采用连续目录与全屏详情。
- **规划**：四步画像、基础推荐或智能规划、替换候选、四周准备任务、保存与打印。
- **计划**：完成/撤销、日期与优先级、本机备份恢复、ICS 日历导出。
- **规则**：目录收录查询、限定学院及年级的单项参考计算；特殊赛道和未知条件不会猜测数值。

现有 247 条记录来自项目中的 2025 目录资料。本轮未逐项核验当届赛事网站。所有原有赛程均标为历年参考，方向标签由名称关键词关联，资格缺失时提示待确认。目录收录不是当届报名资格证明。

当前不收款、不承诺获奖、不将综测参考值当作推免加分。任务与画像保存在当前浏览器，清理浏览器数据会删除本机记录，应定期备份。

## 数据迁移

右上角「本机档案与数据」可导入同一浏览器来源下的旧版 `xauat_plan_*` 与画像。只读取计划与画像，不读取旧密码；重复导入不会重复添加任务。损坏数据会保留并阻止覆盖，可先导出原始数据，再恢复有效备份。

旧版若位于另一个域名、端口或 `file://` 来源，浏览器会隔离存储。先在旧地址导出计划，保留原始副本，再在同源旧档案中迁移；本版 JSON 恢复入口只接收明确的 v2 格式，不能将任意旧 JSON 强行导入。

## 离线交付

`npm run build` 从 `competitions_enriched.json` 生成 `public/data.js` 和：

`dist/建大竞赛罗盘_离线版.html`

离线文件包含数据、样式、脚本与 SVG，可直接双击打开。模型 API、反馈提交、原文 PDF 需要服务端或项目原始文件。页面会明确显示离线状态。

根目录原有 `建大竞赛罗盘_XAUAT_Compass.html` 是历史文件，不是本轮新产物。小程序与旧脚本均未修改。

## 验证

```powershell
npm test
npm ci
npm run test:browser
```

浏览器脚本默认使用本机 Chrome，要求 `npm start` 已运行。可通过 `TEST_URL` 指定服务、`BROWSER_CHANNEL` 指定 Playwright 浏览器通道。未安装 Chrome 时可执行 `npx playwright install chromium` 并设置 `BROWSER_CHANNEL=chromium`。

需要录屏时，先安装 Playwright 的 FFmpeg：`npx playwright install ffmpeg`，再设置 `RECORD_VIDEO=1`。这只用于测试，不进入产品运行依赖。

测试截图、浏览器报告与录屏保存在 `output/playwright/`。模型接口测试使用显式测试夹具，不代表真实供应商已联调。详细证据见 `docs/验收记录.md` 和 `docs/上线记录.md`。

## 当前线上部署

正式地址：`https://compass.lzso.top`，对应原有 Cloudflare Worker `xauat-compass`。新版静态资源与 API 同域，生产卡密、额度和反馈使用 SQLite-backed Durable Object `CompassStore` 持久化，不依赖本机 Node 服务持续在线。

现有 21 张卡密已迁入生产数据库。模型密钥和管理凭据保存在 Worker Secrets 中，不进入静态资源或 Git。

仓库部署配置是 `wrangler.jsonc`，Node 构建版本由 `.node-version` 指定。Cloudflare 的 Git 构建可使用 `npm ci`、`npm run build` 与 `npm run deploy`；重新发布不会重新导入或清空卡密。Worker 的 SQLite 类名和迁移标签应保持稳定。

手动发布：

```powershell
npm ci
npm run build
npm run deploy
```

后续新增线上卡密应使用云端管理命令，不要仅在本机数据库生成：

```powershell
npm run trial:cloud -- create 20
npm run trial:cloud -- list
npm run trial:cloud -- revoke 3
```

云端管理凭据位于本机被忽略的 `runtime/deploy/cloudflare-secrets.json`，管理脚本只在本地读取它。新卡密会写入本机 `runtime/云端试用卡密-批次N.txt`，不会在命令输出中展示。其他维护设备需要通过安全的本地方式配置同一管理凭据。

最初迁移数据由 `tools/export-cloudflare.mjs` 导出，仅在首次部署执行。备份与迁移数据保存在被忽略的 `runtime/deploy/`，不应提交到公开仓库。

## 自托管 Node 服务的运行约束

以下仅适用于选择另行自托管 Node 服务的情况：
- 使用单个 Node 服务进程与持久化 SQLite 目录；并发限制为进程内实现，不支持多个进程共享同一数据库运行服务。
- 通过 HTTPS 反向代理对外开放，将 `APP_ORIGIN` 设置为用户实际访问的精确来源；默认绑定 `127.0.0.1`。HTTPS 来源会设置 Secure 会话 Cookie。
- 反向代理对 `/api/plans/generate` 关闭响应缓冲，并让读取超时大于 `LLM_TIMEOUT_MS`。请求 Origin 必须保留。
- 只开放应用服务端口；服务使用静态文件白名单，不提供 `.env`、源码服务器目录或数据库下载。
- 当前试用码限速按直连 IP 执行；反向代理后可能共享代理 IP 限额。首批小规模试用适用，扩大规模前需根据可信代理拓扑调整，不能直接信任任意 `X-Forwarded-For`。
- 数据库包含会话哈希、试用记录、有效方案重放缓存和主动提交的反馈。访客数据不自动上传，登录后按账号同步计划；不记录完整模型原始输入。方案缓存包含用户提供的非身份画像，运维时应保护并按需清理。
- 使用进程管理器维持服务，并备份运行目录。切勿在公开服务器运行测试夹具或分享测试输出中的试用凭证。

## 代码组织

| 位置 | 内容 |
|---|---|
| `public/` | 界面、样式、数据产物、本机存储与原生运动模块 |
| `shared/core.js` | 数据规范化、候选筛选、模型校验、规则参考、任务与日历格式 |
| `server/` | 同源接口、模型适配、SQLite 试用管理 |
| `tools/` | 构建、试用码管理、匿名汇总报告 |
| `tests/` | 规则/迁移/接口测试与浏览器流程 |
| `docs/` | 验收证据和后续变现验证方案 |
