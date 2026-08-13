# WARP Web Tool

一个基于 FastAPI + Playwright 的 WARP ZERO 节点提取与优选 IP Web 工具。

本项目已支持 Docker 一键部署：任何人只要有一台 VPS，就可以通过安装脚本完成 Docker、Docker Compose、项目服务与可选 Caddy HTTPS 反代配置。

## 一键安装

> 建议使用 Debian / Ubuntu / CentOS / Rocky / AlmaLinux 等常见 Linux VPS，并使用 `root` 用户执行。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SIJULY/WARP-Web-Tool/main/install.sh)
```

如果你的仓库地址不同，可以用环境变量覆盖：

```bash
GIT_REPO_URL="https://github.com/你的用户名/你的仓库.git" bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/你的仓库/main/install.sh)
```

## 安装模式

安装脚本会交互式询问访问方式：

### 1. IP + 端口模式

不输入域名时可选择该模式，默认开放端口为 `8000`：

```text
http://服务器IP:8000
```

### 2. 域名 + 自动 HTTPS 模式

输入已经解析到 VPS 的域名后，脚本会自动配置 Caddy：

- 如果检测到宿主机已有 `caddy.service`：追加本项目配置到 `/etc/caddy/Caddyfile`，并 reload Caddy。
- 如果检测到已有 Docker Caddy，且 `/etc/caddy/Caddyfile` 是宿主机文件挂载：追加本项目配置并 reload 容器内 Caddy；此模式下应用端口会监听到宿主机网络，供已有 Caddy 容器反代访问。
- 如果未检测到任何 Caddy：自动启用本项目自带的 Caddy 容器，占用 `80/443` 并签发 HTTPS 证书。
- 如果检测到已有 Docker Caddy 但无法安全编辑其 Caddyfile：脚本会中止，避免影响 VPS 上已有项目。

脚本写入已有 Caddy 时会使用如下标记块，卸载时只删除本项目配置，不影响其他站点：

```caddyfile
# WARP Web Tool Config Start
example.com {
    encode gzip
    reverse_proxy 127.0.0.1:8001
}
# WARP Web Tool Config End
```

## 管理项目

再次运行安装脚本即可打开管理菜单：

```bash
cd /root/warp-web-tool
bash install.sh
```

菜单包含：

```text
1. 新安装
2. 更新（保留部署配置）
3. 卸载
0. 退出
```

## 手动 Docker 运行

如果你只想在本地或服务器手动启动：

```bash
docker compose up -d --build
```

默认访问：

```text
http://服务器IP:8000
```

查看日志：

```bash
docker logs -f warp-web-tool
```

停止服务：

```bash
docker compose down
```

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `Dockerfile` | 构建 FastAPI + Playwright Chromium 运行环境 |
| `docker-compose.yml` | 默认 IP + 端口模式 Compose 配置 |
| `Caddyfile` | 项目自带 Caddy 的默认配置模板 |
| `install.sh` | 一键安装 / 更新 / 卸载管理脚本 |
| `main.py` | FastAPI 应用入口，监听容器内 `8000` 端口 |

## 注意事项

1. 域名模式需要域名 A 记录提前解析到 VPS IP。
2. 域名 HTTPS 模式需要 VPS 的 `80`、`443` 端口可访问。
3. 首次构建会安装 Playwright Chromium 与系统依赖，耗时较长属于正常情况。
4. 如果 VPS 已有 Caddy，脚本只追加带标记的本项目配置块，不会覆盖原有配置。