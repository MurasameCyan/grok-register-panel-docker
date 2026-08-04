# grok-register-panel-docker

[lij768423-svg/grok-register-panel](https://github.com/lij768423-svg/grok-register-panel)
的容器打包。镜像由 GitHub Actions 构建并推送到 GHCR,**本地只拉取,不构建**。

思路:**依赖烘进镜像,源码在容器启动时从上游 git 拉取**。上游是纯 Python,没有编译步骤,
所以日常代码更新只要 `restart`,不用换镜像;只有 `requirements.txt` 变动才需要新镜像。
CI 也按这个规则判断:定时任务比对上游 `requirements.txt` 的 sha256 和已发布镜像的 label,
依赖没变就不构建。

镜像:`ghcr.io/murasamecyan/grok-register-panel-docker:latest`

## 1. 首次部署

一个空目录,取一份 `docker-compose.yml`,起:

```bash
curl -fsSLO https://raw.githubusercontent.com/MurasameCyan/grok-register-panel-docker/main/docker-compose.yml
docker compose up -d
```

不用建目录、不用 `chown`、不用写 `.env`、不用先生成 Token。数据存在命名卷里,首次启动时
entrypoint 会把 `config.json`(从上游 `config.example.json` 拷)、空的 `proxies.txt` 和一个
随机 Token 都建好。

`docker-compose.yml` 和镜像是配套的,升级时两个都要更新 —— 只 `pull` 镜像、留着旧
compose 文件会挂在旧的单文件挂载上,见下面"从旧版升级"。

取 Token:

```bash
docker compose exec panel cat panel-data/monitor_token
# 或从日志里看,首次启动会打印一次
docker compose logs panel | grep '\[token\]'
```

浏览器开 `http://127.0.0.1:8787`,在"访问令牌"填进去。

想用自己的 Token 就写 `.env`,entrypoint 不会覆盖它:

```bash
printf 'MONITOR_TOKEN=%s\n' "$(openssl rand -hex 32)" > .env    # hex,不是 base64
chmod 600 .env
docker compose up -d
```

> **`.env` 不需要映射进容器。** 它是 docker compose 在**宿主**上读的变量替换文件,compose
> 读完把值作为真正的环境变量注入容器。上游没有任何 dotenv 依赖 —— `monitor.py`、
> `security_utils.py` 全部走 `os.environ.get`,容器里没人会去读 `.env`。挂进去只会多暴露
> 一份 Token。

起来之后按需编辑配置(邮箱服务商见上游 `DEPLOYMENT.md` 第 2 节)。**优先在面板里改** ——
邮箱服务商那一栏面板会直接写 `config.json`(`/api/email-provider`),即时生效,不用 restart。

要在命令行直接改也行,但**镜像里没有编辑器**(`python:3.12-slim` 基础镜像不带 `vi`/`nano`)。
拷出来改完再拷回去,然后 restart:

```bash
docker compose cp panel:/app/src/panel-data/config.json ./config.json
# 用宿主上你惯用的编辑器改 ./config.json
docker compose cp ./config.json panel:/app/src/panel-data/config.json
docker compose restart panel
```

面板里想看到日志原文(默认那张卡片写着 `raw log tail disabled`),在 `.env` 里打开:

```bash
printf 'PANEL_INCLUDE_TAIL=1\n' >> .env
docker compose up -d       # 不是 restart:改环境变量要重建容器才生效
```

### 环境变量

上游代码里能读的环境变量,`docker-compose.yml` 全部列成了 `${VAR:-默认值}`,所以都能在
`.env` 里覆盖,不必改 compose 文件。`.env.example` 是同一份清单,每行都注在默认值上。

这份清单是从上游源码里的 `os.environ.get` / `os.getenv` / `os.environ[...]` 逐个找出来的,
不是抄文档 —— 所以它等于代码真正会读的东西。**改任何一个都要 `docker compose up -d`**,
`restart` 不会重建容器,新值进不去。

面板服务:

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `MONITOR_TOKEN` | *(自动生成)* | 留空则首次启动生成 64 位 hex 存进 `panel-data/monitor_token` |
| `PANEL_INCLUDE_TAIL` | `0` | `1` 显示日志原文卡片(上游过 `redact_log_line` 脱敏) |
| `MONITOR_CORS_ORIGIN` | *(空)* | 精确 origin;上游不认 `*`,空即同源 |

`MONITOR_HOST`/`MONITOR_PORT` 固定成 `0.0.0.0:8787`,那是容器内部地址;对外暴露改
`ports:` 那行,见第 3 节。

注册运行参数:

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `GROK_BATCH_IDLE_TIMEOUT` | `360` | 多少秒没有日志输出就重建 batch 子进程,上游下限 60 |
| `GROK_BATCH_MAX_RESTARTS` | `8` | 一批里最多自动恢复几次 |
| `PROXY_NETWORK_COOLDOWN_SECONDS` | `90` | 网络失败冷却,上游下限 10 |
| `PROXY_RISK_COOLDOWN_SECONDS` | `1800` | 风控冷却,上游下限 60 |
| `REGISTER_WORKERS` | `2` | **面板启动的运行不看它** —— 只有手动跑 `run_xvfb_smoke.py` 时读 |
| `ORCH_BASE_CPA` | `0` | 同上,面板写过 `monitor_control.json` 之后就被覆盖 |
| `ORCH_ADD_COUNT` | `100` | 同上 |

后三个映射出来是为了"上游能读的都能设",但**并发数和目标数量请在面板里改**:面板的"并发数"
和"再跑 N 个"写进 `log/monitor_control.json`,`run_until_100.py` 的 `apply_control()` 会用它
覆盖 `ORCH_*`;并发数则从来只走 `monitor_control.json` 的 `workers`,`REGISTER_WORKERS` 在
这条路径上完全不参与。

浏览器运行时:

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `GROK_USE_XVFB` | `auto` | 只接受 `auto`/`1`/`0`,别的值启动就抛 `RuntimePlatformError`。镜像里有 xvfb 且无 X display,`auto` 会解析成 `xvfb-run` |
| `GROK_PYTHON_BIN` | *(空)* | 覆盖 worker 用的 `.venv/bin/python`;entrypoint 已把 `.venv` 软链到 `/opt/venv`,一般不用动 |

状态文件路径。这几个都进 `Path()`,**空值会解析成 `.`**,也就是写进 `/app/src` —— 而
entrypoint 每次启动都 `git reset --hard` 那个目录,写进去的东西会被清掉。所以 compose 给的
是绝对路径而不是 `${VAR:-}`,你要改也请给挂载目录下的绝对路径:

| 变量 | 默认 |
| --- | --- |
| `CPA_AUTH_DIR` | `/app/src/cpa_auth` |
| `EMAIL_PROVIDER_CONFIG_FILE` | `/app/src/panel-data/config.json` |
| `PROXY_POOL_STATE_FILE` | `/app/src/log/proxy_pool.json` |
| `PROXY_POOL_LEGACY_FILE` | `/app/src/panel-data/proxies.txt` |
| `BLACKLIST_STATE_FILE` | `/app/src/log/blacklist_state.json` |
| `EMAIL_DOMAIN_POOL_STATE_FILE` | `/app/src/log/email_domain_pool.json` |
| `BATCH_LOG` | *(空 = 取 `log/` 里最新的 `batch*.log`)* |

`EMAIL_PROVIDER_CONFIG_FILE` 特意指向 `panel-data/` 里的**真实文件**,不是 `/app/src` 里的
软链:面板存邮箱服务商配置走 `atomic_write_json`,里面的 `os.replace(临时文件, 目标)` 会把
软链本身替换成普通文件,而下次启动 entrypoint 的 `ln -sfn` 又会把它覆盖掉 —— 刚存的配置就
没了。写在 `panel-data/` 里同时让 `mkstemp` 和目标同挂载点,不会 EXDEV。

邮箱服务商凭据 —— `CLOUDMAIL_URL`、`CLOUDMAIL_ADMIN_EMAIL`、`CLOUDMAIL_PASSWORD`、
`MOEMAIL_API_BASE`、`MOEMAIL_API_URL`、`MOEMAIL_API_KEY`,默认全空。`MOEMAIL_API_URL` 是旧
别名,只在 `MOEMAIL_API_BASE` 为空时才读。

**建议留空,在面板里填。** 上游是 `os.environ.get(X) or config.get(x)` —— 环境变量优先级
高于 `config.json`,所以这里一旦设了值,你在面板里改同一项会像是"改了没反应"(存进
`config.json` 了,但读的时候还是环境变量赢)。另外写在这里的密码会进 `docker inspect` 输出
和执行 compose 那个人的 shell 历史。

出站代理 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` / `NO_PROXY` 默认空,**但它们不会给注册
走代理**:
`run_batch_headless._run_child` 在 import 上游模块之前就把 `http_proxy`/`https_proxy`/
`ALL_PROXY`(大小写都算)从环境里 pop 掉了,worker 一律从干净环境起,代理只认 `config.json`
的 `proxy` 和面板的代理池 —— 要给注册配代理请填那两处。这三个变量实际生效的地方是
entrypoint 自己的 `git`/`pip`,以及账号恢复(`recovery_ops` 起的 `sso_to_auth_json.py`,它
继承 `os.environ`,`config.json` 没设 proxy 时 urllib 会认环境变量)。另外有些调用点故意用
`ProxyHandler({})` / `trust_env = False` 绕开代理 —— geo 查询和连通性探测必须直连。

镜像自己的开关(上游不读):`UPSTREAM_REF`(默认 `main`)、`UPSTREAM_AUTO_UPDATE`
(`1`)、`AUTO_PIP_INSTALL`(`1`,`0` 跳过装上游新依赖)、`PANEL_FIX_OWNERSHIP`(`1`)、
`IMAGE_TAG`(`latest`)、`TZ`(`Asia/Shanghai`)。

故意没有映射出来的:`DISPLAY` / `WAYLAND_DISPLAY` 和 `GROK_BATCH_PROGRESS_FILE` 由
`xvfb-run` 和 `batch_supervisor` 按子进程设(而且在这里设 `DISPLAY` 会让
`GROK_USE_XVFB=auto` 误判成"有真实显示");`LOCALAPPDATA` / `DPE_REEXEC_DONE` /
`TK_SILENCE_DEPRECATION` 只对桌面版 Tk 有意义;`GITHUB_TOKEN` / `GH_TOKEN` /
`GITHUB_REPOSITORY` 是上游自己 CI 脚本用的;`PANEL_DATA_DIR` 则是因为 compose 的卷正好挂在
那个路径上,从 `.env` 改它只会把 `config.json` 写到挂载点外面去。

对账方式:上游树里(排除 `tests/`)一共 30 个被读取的环境变量,除上面这几个之外全部映射了。
`GROK_REGISTER_THEME` / `_APP_VIEW` / `_HELP_TAB` 看着像变量,其实是前端 localStorage 的
key,不是环境变量。

### 想让数据直接落在宿主目录

默认用命名卷是为了"拉了就能跑"。要把授权文件和日志放到宿主上(方便给 grok2api 挂、方便
`tar` 备份),叠加 `docker-compose.bind.yml`:

```bash
docker compose -f docker-compose.yml -f docker-compose.bind.yml up -d
```

数据落在 `./data/`。同样不需要预先 `mkdir` 或 `chown`:Docker 会把缺失的挂载源建成
`root:root`,entrypoint 以 root 启动时把它们 chown 成 `10001:10001`,然后用 gosu 降到
uid 10001 再跑面板 —— 面板进程本身不是 root(`docker compose exec panel id` 可验证)。

要自己管属主(宿主用了别的 uid、或不接受容器短暂持有 root):

```bash
# 二选一,都会跳过自动 chown,并在属主不对时直接报错退出
PANEL_FIX_OWNERSHIP=0 docker compose up -d
# 或在 docker-compose.yml 的 panel 下加 user: "10001:10001"
```

数据布局(默认命名卷;叠加 `docker-compose.bind.yml` 后同一列变成 `./data/<名字>`):

| 卷 / 宿主路径 | 容器内 | 内容 |
| --- | --- | --- |
| `panel-data` | `/app/src/panel-data` | `config.json` + `proxies.txt`(软链到 `/app/src/`)、`monitor_token` |
| `cpa_auth` | `/app/src/cpa_auth` | CPA 授权文件 |
| `grok2api_auth` | `/app/src/grok2api_auth` | grok2api 授权文件 |
| `accounts` | `/app/src/accounts` | 注册产出账号、`sso_pending.txt` |
| `log` | `/app/src/log` | 运行日志、`blacklist_state.json`、`monitor_control.json`、`monitor_stats.json`、`register_results.jsonl`、pid |
| `camoufox` | `/home/app/.cache/camoufox` | 浏览器缓存(可重下,不必备份) |
| `.env` | *(不挂载)* | compose 宿主侧变量:Token、镜像 tag、时区 |

看/改命名卷里的文件不用先找宿主路径:

```bash
docker compose exec panel ls -la panel-data log accounts
docker compose exec panel cat panel-data/config.json
# 备份
docker compose exec -T panel tar cf - panel-data cpa_auth grok2api_auth accounts > backup.tar
```

`log` 是整目录,面板的全部运行时写入都落在里面(核对过 `monitor.py`、
`run_until_100.py`、`blacklist_store.py` 的写入路径,没有写到目录外的)。

`config.json` 和 `proxies.txt` 放在 `panel-data/` **目录**里再软链进 `/app/src`,不是各挂
一个单文件 —— 单文件 bind mount 在宿主路径缺失时会被 Docker 建成目录,挂目录就没这个坑,
也让首次 `up` 免去手动 `touch`/`cp`。Web 面板存邮箱服务商配置(`/api/email-provider` →
`save_email_provider_config`)会写 `config.json`,走 `secure_files.atomic_write_json`
(mkstemp + `os.replace`)—— 因为现在是目录挂载,临时文件落在同一个目录内,不再跨挂载点
EXDEV 失败。这也是 `EMAIL_PROVIDER_CONFIG_FILE` 必须指向 `panel-data/` 里的真实文件、而不是
`/app/src` 软链的原因(见上面环境变量一节):`os.replace` 会把软链替换成普通文件,下次启动的
`ln -sfn` 再把它覆盖,刚存的配置就没了。

> **从旧版升级:`docker-compose.yml` 也要一起换。**
>
> 只 `docker compose pull` 是不够的:旧 compose 把 `config.json`、`proxies.txt` 当**单文件**
> 挂载,而 Docker 在宿主路径不存在时会把挂载源建成**目录**。所以删掉 `data/` 再拉新镜像会
> 撞上这个,而且容器内无法自救(`umount` 需要 `CAP_SYS_ADMIN`):
>
> ```
> ln: failed to create symbolic link 'config.json/config.json': Permission denied
> ```
>
> 新镜像遇到这个形状会直接报"你的 docker-compose.yml 版本过旧"并退出,不再在 `ln` 上打转。
> 修法是把 compose 文件也更新:
>
> ```bash
> docker compose down
> curl -fsSLO https://raw.githubusercontent.com/MurasameCyan/grok-register-panel-docker/main/docker-compose.yml
> docker compose up -d
> ```
>
> 数据在 `./data/` 里、想继续留在宿主上,则再取一份 bind 覆盖文件,并把两个文件挪进
> `data/panel/`:
>
> ```bash
> docker compose down
> curl -fsSLO https://raw.githubusercontent.com/MurasameCyan/grok-register-panel-docker/main/docker-compose.yml
> curl -fsSLO https://raw.githubusercontent.com/MurasameCyan/grok-register-panel-docker/main/docker-compose.bind.yml
> mkdir -p data/panel && mv data/config.json data/proxies.txt data/panel/   # 若还是旧布局
> docker compose -f docker-compose.yml -f docker-compose.bind.yml up -d
> ```
>
> 不用手工 `chown`:entrypoint 会把 `data/` 下这几个目录的属主一并修好,包括旧部署里
> 被 Docker 建成 `root:root` 的那些。
>
> 想改用命名卷(默认),先按上面第一段换掉 compose 文件,再把 `data/` 里的内容拷进去:
>
> ```bash
> docker compose up -d      # 先让卷建出来
> docker compose cp data/panel/. panel:/app/src/panel-data/
> docker compose cp data/cpa_auth/. panel:/app/src/cpa_auth/
> docker compose cp data/grok2api_auth/. panel:/app/src/grok2api_auth/
> docker compose cp data/accounts/. panel:/app/src/accounts/
> docker compose restart panel
> ```

要把授权目录给 grok2api 之类的另一个容器读,两种都行 —— 共享命名卷:

```yaml
  grok2api:
    volumes:
      - grok2api_auth:/app/data/auth:ro          # 路径按 grok2api 实际要求调整
```

或者用 `docker-compose.bind.yml` 落到宿主再挂:

```yaml
  grok2api:
    volumes:
      - ./data/grok2api_auth:/app/data/auth:ro   # 路径按 grok2api 实际要求调整
```

用命名卷时属主天然是对的:Docker 建新卷会从镜像里的挂载点继承属主(uid 10001)。bind
mount 才需要 entrypoint 出手 chown。两种情况下 entrypoint 都会在启动时确认这几个目录可写,
不可写就直接退出 —— 比跑完一轮注册、烧掉一个邮箱之后才发现写不进授权文件要好。

面板地址 `http://127.0.0.1:8787`,打开后在"访问令牌"填 Token
(`docker compose exec panel cat panel-data/monitor_token`,或 `.env` 里你自己设的)。

## 2. 跟随上游更新

```bash
docker compose restart panel        # 日志打印 [upstream] abc1234 -> def5678
```

启动时 entrypoint 先 `git ls-remote` 问一次远端 hash(一次往返,不下载对象),和本地
`git rev-parse HEAD` 比:相同就完全不碰工作树,只打印 `[upstream] up to date at abc1234`;
不同才 `git fetch --depth 1` + `git reset --hard`。

**没有单独的 hash 记录文件。** git 自己就存着当前 revision(`.git/HEAD`),再存一份的话,
`reset` 半路失败(磁盘满、权限、fetch 断)时哈希文件已经更新了,下次启动会误判"已是最新"
并从此不再自愈。同一份状态存两处就一定有对不上的那天。

不确定该 restart 还是 pull:

```bash
docker/check-update.sh
#   up to date at abc1234                     → 退出码 0,什么都不用做
#   source-only change -> restart is enough   → 退出码 11
#   requirements.txt changed -> pull          → 退出码 10
```

它查 GitHub API 比对 commit hash,再看两个 revision 之间 `requirements.txt` 有没有动 ——
源码变动不需要新镜像(启动时 git pull 就够),只有依赖变动才要拉镜像。退出码可以直接用在
cron 里。

`docker compose pull` 时顺手把 compose 文件也拉一次,它和镜像是配套的(挂载布局变过一次,
只换镜像会起不来):

```bash
curl -fsSLO https://raw.githubusercontent.com/MurasameCyan/grok-register-panel-docker/main/docker-compose.yml
docker compose pull && docker compose up -d
```

依赖变动时 CI 会在几小时内(定时 04:17 UTC)自动出新镜像;想立刻要,去 Actions 手动跑
`image` workflow(`workflow_dispatch`,勾 force)。等不及也可以先 `restart` —— entrypoint
会检测到 `requirements.txt` 哈希变化并自己 `pip install` 到 `/opt/venv`,日志打
`[deps] requirements.txt changed, installing`。这是临时兜底:装出来的东西不在镜像层,
容器 recreate 就没了,新镜像出来后 `pull` 一次固化回去。

上游升 Camoufox 版本时,`pip install` 补不上浏览器包(在命名卷里),要清卷。卷名带
compose 项目名前缀(默认是目录名),先查一下再删,别手写:

```bash
docker volume ls --filter name=camoufox     # 先看实际卷名,通常是 <目录名>_camoufox
docker compose down
docker volume rm <上一步看到的卷名>
docker compose up -d
```

只删 `camoufox` 卷是安全的,里面只有可重新下载的浏览器二进制。**别用
`docker compose down -v`** —— 那会连账号、Token、`config.json` 一起删掉。

想固定版本、不跟随:

```bash
UPSTREAM_REF=v0.2.0 docker compose up -d       # 钉在 tag/分支
UPSTREAM_AUTO_UPDATE=0 docker compose up -d    # 冻结在镜像构建时的快照
```

注意 `UPSTREAM_REF` 用 `ls-remote refs/heads/<ref>` 查,所以钉 tag 时它查不到远端 ref,
会走"unreachable, running pinned"分支 —— 效果是不更新,符合预期,但日志有点误导。

## 3. 从远程访问面板

端口只发布到宿主 `127.0.0.1:8787`,云主机上不能直接从外网打开。用 SSH 隧道:

```bash
# 在你本地机器上执行
ssh -N -L 8787:127.0.0.1:8787 root@<服务器IP>
# 本地浏览器开 http://127.0.0.1:8787,"访问令牌"填 monitor_token 里的值
```

不要为了图方便把映射改成 `"8787:8787"` —— 那等于把内置 HTTP 服务裸放公网,上游明确说它
不替代互联网边界网关。要公网访问就放到带 TLS 和额外身份认证的反代后面。

## 4. 验证

```bash
docker compose logs --tail=30 panel     # 看 [upstream]、[deps]、[token] 几行
docker compose exec panel smoke.sh
docker compose exec panel id            # 期望 uid=10001,不是 0

tok="$(docker compose exec -T panel cat panel-data/monitor_token)"
curl -fsS http://127.0.0.1:8787/api/health
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8787/api/status          # 期望 401
curl -H "Authorization: Bearer $tok" http://127.0.0.1:8787/api/status           # 期望 200
```

`smoke.sh` 检查几件容易在改动 entrypoint 后悄悄坏掉的事:`.venv/bin/python` 可执行
(`monitor.py`、`run_until_100.py` 用硬编码路径拉起 worker)、运行时依赖能 import、
Camoufox 浏览器已下载、`xvfb-run` 和 `/proc` 可用(`process_utils.py` 靠 `/proc` 找进程)、
`config.json` 与 `proxies.txt` 已由 entrypoint 创建并软链成常规文件、
当前 uid 不是 0(确认 entrypoint 真的降权了),
再做一次真实的 `git reset --hard` 确认 `log/` 下的运行数据没被冲掉。

## 5. CI

`.github/workflows/image.yml`,两个 job:

- **probe** — 只用 GitHub API:解析上游 HEAD、取 `requirements.txt` 的 sha256,和已发布镜像
  的 `io.grokpanel.reqs-sha256` label 比。定时触发且依赖没变 → 不构建。
- **build** — buildx 推 GHCR,三个 tag:`latest`、`reqs-<sha256>`、`upstream-<rev>`;
  推完跑五组自检,任一失败就红:
  - `docker run ... smoke.sh`,两个架构各一遍。
  - 挂一组 `root:root` 的宿主目录进去,验证 entrypoint 能自动修属主、`config.json` 真的
    落在挂载的宿主侧。
  - `PANEL_FIX_OWNERSHIP=0` 再跑一次,确认退出码非 0 且报错点出了不可写的挂载。
  - 按旧 compose 的样子挂两个单文件进去(宿主侧是 `root:root` 目录),确认容器**指出
    compose 文件过旧**而不是死在 `ln: failed to create symbolic link` 上。
  - **在空临时目录里只放一份 `docker-compose.yml` 就 `up -d --wait`** —— 没有 `.env`、
    没有 `data/`、没有预建卷,复刻用户拉取即用的路径。等 HEALTHCHECK 转绿后校验生成的
    Token 是 64 位 hex、`/api/status` 不带 Token 401 带 Token 200,再 `down`/`up` 一次
    确认 Token 没变(即命名卷真的持久化了)。

触发:每天 04:17 UTC 定时、改 `Dockerfile`/`docker/**` 时 push、手动 dispatch。

平台:`linux/amd64` + `linux/arm64`。Camoufox 上游同时发 `lin.x86_64` 和 `lin.arm64`
的 Firefox 构建,所以两边 `camoufox fetch` 都能拿到原生二进制,**运行时不需要模拟**。
arm64 的镜像层是在 amd64 runner 上用 QEMU 构建的(只影响构建耗时,约 20~30 分钟)。
`docker compose pull` 会按宿主架构自动选,不用指定。

**GHCR package 默认是 private。** 第一次构建完要手动改一次:
https://github.com/users/MurasameCyan/packages/container/grok-register-panel-docker/settings
→ Change visibility → Public。不改也能用,但宿主 `pull` 前得先:

```bash
echo <你的PAT> | docker login ghcr.io -u MurasameCyan --password-stdin
```

## 6. 设计取舍

| 决定 | 原因 |
| --- | --- |
| 镜像只装依赖,源码启动时 git pull | 上游是纯 Python 无编译步骤;源码天天变、依赖很少变,分开后日常更新只要 `restart`,CI 也只在依赖变动时才构建 |
| `.env` 不挂进容器 | 上游无 dotenv 依赖,全走 `os.environ`;compose 在宿主读它并注入环境变量,挂进去只多暴露一份 Token |
| venv 放 `/opt/venv`,启动时软链到 `src/.venv` | `git reset --hard` 永远碰不到依赖;而上游硬编码 `ROOT/.venv/bin/python`,软链是唯一不改上游代码的解法 |
| 源码保留 `.git`,启动时 `ls-remote` 比 hash,不同才 reset | 跟随上游只需重启;不额外存哈希文件是因为 git 自己就存着 revision,存两处会在 reset 半失败时永久误判"已最新" |
| `shm_size: 1gb` | Firefox/Camoufox 在默认 64 MB `/dev/shm` 上会崩 |
| 容器内 `MONITOR_HOST=0.0.0.0`,端口只发布到 `127.0.0.1` | 容器网络里绑 loopback 就没法从宿主访问;隔离交给端口发布,不是绑定地址 |
| 镜像内装 xvfb + procps | 注册流程走 `xvfb-run`,面板停止进程要读 `/proc` 和 `ps` |
| 同时出 amd64 和 arm64 | Camoufox 两个架构都有原生 Firefox 构建,ARM 云主机(Ampere、Graviton)能原生跑,不必 QEMU |
| 默认命名卷,bind mount 放到单独的覆盖文件里 | 拉了就能 `up -d` 是首要目标;新建命名卷会从镜像继承 uid 10001,而缺失的 bind mount 源被 Docker 建成 `root:root`,正是那个把首次部署卡进重启循环的坑。要宿主可见(给 grok2api 挂、`tar` 备份)时叠加 `docker-compose.bind.yml` |
| 没有 `MONITOR_TOKEN` 就自动生成一个,存进 `panel-data/` | 原来是硬失败,等于强制用户先写 `.env` 才能启动,"拉取即用"做不到;而上游 `check_token_optional_read` 在 token 为空时**放行所有读接口**,所以"总是有 token"比"没 token 就拒绝启动"更安全 |
| `config.json`/`proxies.txt` 挂目录 `panel-data/` 再软链,不直接挂单文件 | 缺失的宿主单文件会被 Docker 建成目录,首次 `up` 就崩;挂目录则由 entrypoint 兜底创建两个文件并软链进 `src/`,新部署无需手动 `touch`/`cp` |
| 非 root 运行(uid 10001) | 面板会 spawn 子进程、写凭据文件,不该有 root |
| entrypoint 以 root 起,chown 完挂载后 gosu 降权 | Docker 把缺失的挂载源建成 `root:root`,靠文档要求用户先 chown 是行不通的(删掉 `data/` 重来就会复现);容器自己修,面板进程仍是 uid 10001 |
| 启动时先检测"旧 compose 的单文件挂载",命中就退出并指名 | 这是唯一容器内修不了的失败:`umount` 要 `CAP_SYS_ADMIN`。不检测的话症状是 `ln: failed to create symbolic link 'config.json/config.json'`,指向 `ln` 而不是指向真正要动的那个文件,用户会以为是镜像的 bug |

## 7. 安全边界

内置 HTTP 服务只适合单机 / LAN / tailnet。上面的 compose 只把端口发布到宿主
`127.0.0.1`,不是公网可达。要对外暴露,放到带 TLS 和额外身份认证的反向代理后面,
并保持 `PANEL_INCLUDE_TAIL=0`。`MONITOR_TOKEN` 是唯一的鉴权凭据,别写进 URL、
命令行参数或仓库。

**日志尾部默认关闭,是可以打开的。** 面板"日志尾部"卡片显示
`(raw log tail disabled; set PANEL_INCLUDE_TAIL=1)` 时,在 `.env` 里写
`PANEL_INCLUDE_TAIL=1` 再 `docker compose up -d`(`restart` 不够 —— 改环境变量要重建容器)。
它是面板里唯一逐行回显日志原文的地方,所以默认关;上游每行都过 `redact_log_line`,会盖掉
邮箱、JWT、代理 URL 和 `token=`/`password=` 这类键值,但那是兜底,不是理由。面板本身暴露在
公网时保持 `0`。

**自动生成的 Token 是真鉴权,不是占位。** 32 字节 `/dev/urandom` 转 hex,`0600` 存在
`panel-data/monitor_token`(命名卷或 `data/panel/`,不入库)。要点在于上游
`check_token_optional_read` 对读接口是"没配 token 就放行":Token 为空时 `/api/status`
等接口无需鉴权即可读。所以这里的选择不是"生成 vs 不生成",而是"生成 vs 裸奔"。
自己在 `.env` 里设 `MONITOR_TOKEN` 时不会被覆盖,也不会写这个文件。
CI 每次构建都验一遍:不带 Token 请求 `/api/status` 必须 401,带上必须 200。

**容器启动的头几毫秒是 root。** entrypoint 只用这段时间 `chown` 那几个挂载目录,随即
`gosu` 降到 uid 10001 再 exec 面板 —— 上游代码、`git` 同步、浏览器子进程全部在降权之后,
没有一行以 root 跑(`smoke.sh` 里有 `id -u != 0` 的断言守着)。不接受这个窗口的话用
`PANEL_FIX_OWNERSHIP=0` 或 compose `user:`,代价是属主要你自己在宿主上管。

`/opt/venv` 对 app 用户可写,这样上游升依赖时能先跑起来、不必等 CI 出镜像。代价是面板进程
理论上能改 `site-packages`。不接受的话:设 `AUTO_PIP_INSTALL=0`,依赖变动一律等 CI 新镜像。

默认布局下 Token 和账号数据都在命名卷里,压根不在仓库目录中。叠加
`docker-compose.bind.yml` 后落到 `./data/`,和自己写的 `.env` 一样已在 `.gitignore` 里。

启动时源码从上游 `main` 拉取,等于信任上游仓库的每个新 commit。要审过再上,用
`UPSTREAM_REF` 钉 tag 或 `UPSTREAM_AUTO_UPDATE=0` 冻结。
