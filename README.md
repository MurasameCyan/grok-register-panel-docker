# grok-register-panel-docker

[lij768423-svg/grok-register-panel](https://github.com/lij768423-svg/grok-register-panel)
的容器打包。镜像由 GitHub Actions 构建并推送到 GHCR,**本地只拉取,不构建**。

思路:**依赖烘进镜像,源码在容器启动时从上游 git 拉取**。上游是纯 Python,没有编译步骤,
所以日常代码更新只要 `restart`,不用换镜像;只有 `requirements.txt` 变动才需要新镜像。
CI 也按这个规则判断:定时任务比对上游 `requirements.txt` 的 sha256 和已发布镜像的 label,
依赖没变就不构建。

镜像:`ghcr.io/murasamecyan/grok-register-panel-docker:latest`

## 1. 首次部署

```bash
mkdir -p data/panel data/cpa_auth data/grok2api_auth data/accounts data/log

chmod 700 data/panel data/cpa_auth data/grok2api_auth data/accounts data/log
sudo chown -R 10001:10001 data          # 容器内是 uid 10001

# hex 而非 base64:base64 会产生 + / = ,compose 解析 .env 时容易出岔
printf 'MONITOR_TOKEN=%s\n' "$(openssl rand -hex 32)" > .env
chmod 600 .env

docker compose up -d --pull always      # 直接拉 GHCR 镜像,不构建
```

没有 `.env` 就 `up` 会直接报
`required variable MONITOR_TOKEN is missing a value` —— 这是故意的硬失败,不是 bug:
容器内绑 `0.0.0.0`,没 Token 启动就是个无鉴权面板。

**`.env` 不需要映射进容器。** 它是 docker compose 在**宿主**上读的变量替换文件,compose
读完把值作为真正的环境变量注入容器。上游没有任何 dotenv 依赖 —— `monitor.py`、
`security_utils.py` 全部走 `os.environ.get`,容器里没人会去读 `.env`。挂进去只会多暴露
一份 Token。(上游 `deploy/monitor.env.example` 是给 systemd `EnvironmentFile=` 用的,
在 compose 部署里由 `.env` + `environment:` 取代。)

不用手动建 `config.json` / `proxies.txt`:首次启动时 entrypoint 会在 `data/panel/` 里
自动生成(`config.json` 从上游 `config.example.json` 拷,`proxies.txt` 建空文件),再
软链进容器的 `/app/src`。所以 `up` 之前只要有 `data/panel/` 这个目录就行。

起来之后编辑 `data/panel/config.json`,至少填好邮箱服务商配置(见上游 `DEPLOYMENT.md`
第 2 节),再 `docker compose restart panel`。

宿主目录布局:

| 宿主路径 | 容器内 | 内容 |
| --- | --- | --- |
| `.env` | *(不挂载)* | compose 宿主侧变量:Token、镜像 tag、时区 |
| `data/panel/config.json` | `/app/src/config.json`(软链) | 邮箱、代理、CPA 配置 |
| `data/panel/proxies.txt` | `/app/src/proxies.txt`(软链) | 代理池(凭据材料) |
| `data/cpa_auth/` | `/app/src/cpa_auth` | CPA 授权文件 |
| `data/grok2api_auth/` | `/app/src/grok2api_auth` | grok2api 授权文件 |
| `data/accounts/` | `/app/src/accounts` | 注册产出账号、`sso_pending.txt` |
| `data/log/` | `/app/src/log` | 运行日志、`blacklist_state.json`、`monitor_control.json`、`monitor_stats.json`、`register_results.jsonl`、pid |

`log/` 是整目录挂载,面板的全部运行时写入都落在里面(核对过 `monitor.py`、
`run_until_100.py`、`blacklist_store.py` 的写入路径,没有写到目录外的)。

`config.json` 和 `proxies.txt` 挂的是 `data/panel/` **整目录**(容器内 `panel-data/`),
不是单文件 —— 单文件 bind mount 在宿主路径缺失时会被 Docker 建成目录,挂目录就没这个坑,
也让首次 `up` 免去手动 `touch`/`cp`。entrypoint 在目录里建实文件后软链到 `/app/src`。
`config.json` 目前只被桌面版 `grok_register_ttk.py` 写,Web 面板只读;真要通过面板写它,
因为现在是目录挂载,`secure_files.atomic_write_text` 的 mkstemp + `os.replace` 也不再跨
挂载点 EXDEV 失败(临时文件落在同一个 `panel-data/` 目录内)。

> 从旧版单文件挂载升级:把 `data/config.json` → `data/panel/config.json`、
> `data/proxies.txt` → `data/panel/proxies.txt` 挪进去即可,内容不变。

授权目录用 bind mount 而不是命名卷,这样 grok2api 容器可以直接挂同一个宿主目录读取:

```yaml
  grok2api:
    volumes:
      - ./data/grok2api_auth:/app/data/auth:ro   # 路径按 grok2api 实际要求调整
```

entrypoint 启动时会检查这四个目录可写,不可写就直接退出 —— 比跑完一轮注册、烧掉一个
邮箱之后才发现写不进授权文件要好。

面板地址 `http://127.0.0.1:8787`,打开后在"访问令牌"填 `.env` 里的 `MONITOR_TOKEN`。

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

依赖变动时 CI 会在几小时内(定时 04:17 UTC)自动出新镜像;想立刻要,去 Actions 手动跑
`image` workflow(`workflow_dispatch`,勾 force)。等不及也可以先 `restart` —— entrypoint
会检测到 `requirements.txt` 哈希变化并自己 `pip install` 到 `/opt/venv`,日志打
`[deps] requirements.txt changed, installing`。这是临时兜底:装出来的东西不在镜像层,
容器 recreate 就没了,新镜像出来后 `pull` 一次固化回去。

上游升 Camoufox 版本时,`pip install` 补不上浏览器包(在命名卷里),要清卷:

```bash
docker compose down && docker volume rm grok-register-panel-docker_camoufox
docker compose up -d
```

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
# 本地浏览器开 http://127.0.0.1:8787,"访问令牌"填 .env 里的 MONITOR_TOKEN
```

不要为了图方便把映射改成 `"8787:8787"` —— 那等于把内置 HTTP 服务裸放公网,上游明确说它
不替代互联网边界网关。要公网访问就放到带 TLS 和额外身份认证的反代后面。

## 4. 验证

```bash
docker compose logs --tail=30 panel     # 看 [upstream] 和 [deps] 两行
docker compose exec panel smoke.sh
curl -fsS http://127.0.0.1:8787/api/health
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8787/api/status          # 期望 401
curl -H "Authorization: Bearer $MONITOR_TOKEN" http://127.0.0.1:8787/api/status # 期望 200
```

`smoke.sh` 检查几件容易在改动 entrypoint 后悄悄坏掉的事:`.venv/bin/python` 可执行
(`monitor.py`、`run_until_100.py` 用硬编码路径拉起 worker)、运行时依赖能 import、
Camoufox 浏览器已下载、`xvfb-run` 和 `/proc` 可用(`process_utils.py` 靠 `/proc` 找进程)、
`config.json` 与 `proxies.txt` 已由 entrypoint 创建并软链成常规文件,
再做一次真实的 `git reset --hard` 确认 `log/` 下的运行数据没被冲掉。

## 5. CI

`.github/workflows/image.yml`,两个 job:

- **probe** — 只用 GitHub API:解析上游 HEAD、取 `requirements.txt` 的 sha256,和已发布镜像
  的 `io.grokpanel.reqs-sha256` label 比。定时触发且依赖没变 → 不构建。
- **build** — buildx 推 GHCR,三个 tag:`latest`、`reqs-<sha256>`、`upstream-<rev>`;
  推完 `docker run ... smoke.sh` 自检,起不来就红。

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
| 授权目录 bind mount,只有 camoufox 缓存用命名卷 | 授权文件是这个面板的产出,要能被 grok2api 读、能直接备份;camoufox 是可重下的缓存,不需要在宿主可见 |
| `config.json`/`proxies.txt` 挂目录 `panel-data/` 再软链,不直接挂单文件 | 缺失的宿主单文件会被 Docker 建成目录,首次 `up` 就崩;挂目录则由 entrypoint 兜底创建两个文件并软链进 `src/`,新部署无需手动 `touch`/`cp` |
| 非 root 运行(uid 10001) | 面板会 spawn 子进程、写凭据文件,不该有 root |

## 7. 安全边界

内置 HTTP 服务只适合单机 / LAN / tailnet。上面的 compose 只把端口发布到宿主
`127.0.0.1`,不是公网可达。要对外暴露,放到带 TLS 和额外身份认证的反向代理后面,
并保持 `PANEL_INCLUDE_TAIL=0`。`MONITOR_TOKEN` 是唯一的鉴权凭据,别写进 URL、
命令行参数或仓库。

`/opt/venv` 对 app 用户可写,这样上游升依赖时能先跑起来、不必等 CI 出镜像。代价是面板进程
理论上能改 `site-packages`。不接受的话:设 `AUTO_PIP_INSTALL=0`,依赖变动一律等 CI 新镜像。

`.env` 里是 `MONITOR_TOKEN`,`chmod 600`,已在 `.gitignore` 里。`data/` 同样不入库。

启动时源码从上游 `main` 拉取,等于信任上游仓库的每个新 commit。要审过再上,用
`UPSTREAM_REF` 钉 tag 或 `UPSTREAM_AUTO_UPDATE=0` 冻结。
