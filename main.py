import os
import json
import base64
import secrets
import asyncio
import time
import ipaddress
import random
import re
import httpx
import datetime
import logging
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from fastapi.requests import Request
from playwright.async_api import async_playwright

app = FastAPI(title="ZERO-Sijuly Web Tool")
templates = Jinja2Templates(directory="templates")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("warp-web-tool")
logger.setLevel(logging.INFO)


async def send_log(websocket: WebSocket, msg: str):
    logger.info(msg)
    await websocket.send_json({"type": "log", "msg": msg})

# ==========================================
# 1. 核心加密与工具函数
# ==========================================
_P = 2 ** 255 - 19
_A24 = 121665


def _decode_scalar(k): k = bytearray(k); k[0] &= 248; k[31] &= 127; k[31] |= 64; return int.from_bytes(k, "little")


def _decode_u(u): u = bytearray(u); u[31] &= 127; return int.from_bytes(u, "little")


def _x25519(s, p):
    k = _decode_scalar(s);
    x1 = _decode_u(p);
    x2, z2 = 1, 0;
    x3, z3 = x1, 1;
    swap = 0
    for t in range(254, -1, -1):
        kt = (k >> t) & 1;
        swap ^= kt
        if swap: x2, x3 = x3, x2; z2, z3 = z3, z2
        swap = kt
        A = (x2 + z2) % _P;
        AA = (A * A) % _P;
        B = (x2 - z2) % _P;
        BB = (B * B) % _P
        E = (AA - BB) % _P;
        C = (x3 + z3) % _P;
        D = (x3 - z3) % _P
        DA = (D * A) % _P;
        CB = (C * B) % _P
        x3 = ((DA + CB) % _P) ** 2 % _P;
        z3 = (x1 * (((DA - CB) % _P) ** 2)) % _P
        x2 = (AA * BB) % _P;
        z2 = (E * ((AA + (_A24 * E) % _P) % _P)) % _P
    if swap: x2, x3 = x3, x2; z2, z3 = z3, z2
    return ((x2 * pow(z2, _P - 2, _P)) % _P).to_bytes(32, "little")


def generate_keypair():
    priv = bytearray(os.urandom(32));
    priv[0] &= 248;
    priv[31] &= 127;
    priv[31] |= 64
    pub = _x25519(bytes(priv), bytes([9] + [0] * 31))
    return base64.b64encode(priv).decode(), base64.b64encode(pub).decode()


def random_install_id():
    alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    return "".join(secrets.choice(alphabet) for _ in range(22))


def client_id_to_reserved(client_id):
    if not client_id: return None
    parts = client_id.split("/")
    if len(parts) == 3 and all(p.isdigit() for p in parts):
        nums = [int(p) for p in parts]
        if all(0 <= n <= 255 for n in nums): return nums
    return None


# ==========================================
# 2. WARP 异步优选 IP
# ==========================================
CF_WARP_IPV4_CIDRS = ["162.159.192.0/24", "162.159.193.0/24", "162.159.195.0/24", "188.114.96.0/24", "188.114.97.0/24"]


def get_random_ips(count=100):
    all_ips = []
    for cidr in CF_WARP_IPV4_CIDRS:
        network = ipaddress.ip_network(cidr)
        all_ips.extend([str(ip) for ip in network.hosts()])
    return random.sample(all_ips, min(count, len(all_ips)))


async def async_tcp_ping(ip, port=2408, timeout=1.0):
    try:
        start_time = time.perf_counter()
        fut = asyncio.open_connection(ip, port)
        reader, writer = await asyncio.wait_for(fut, timeout=timeout)
        writer.close()
        await writer.wait_closed()
        return ip, (time.perf_counter() - start_time) * 1000
    except Exception:
        return ip, -1


async def scan_warp_ips(websocket: WebSocket, sample_size=100):
    await send_log(websocket, f"📦 正在抽取 {sample_size} 个 IP 进行并发连通性测试...")
    ips = get_random_ips(sample_size)
    tasks = [async_tcp_ping(ip) for ip in ips]
    results = await asyncio.gather(*tasks)

    valid_results = [(ip, lat) for ip, lat in results if lat != -1]
    valid_results.sort(key=lambda x: x[1])

    if not valid_results:
        await send_log(websocket, "❌ 未发现存活 IP，使用默认兜底 IP。")
        return "162.159.193.10"

    await send_log(websocket, f"✅ 成功找到 {len(valid_results)} 个存活 IP！")
    for i, (ip, lat) in enumerate(valid_results[:10]):
        await send_log(websocket, f"[{i + 1}] 延迟: {lat:.1f}ms => {ip}")

    return valid_results[0][0]


# ==========================================
# 3. 异步 Playwright 提取流程 (强化容错机制)
# ==========================================
async def extract_cloudflare_token(websocket: WebSocket, org: str, email: str, state: dict):
    access_jwt = None

    def extract_from_text(text):
        if not text: return None, None
        url_match = re.search(r"com\.cloudflare\.warp://[^\s\"'<>]+", text)
        url = url_match.group(0) if url_match else None
        jwt_match = re.search(r"token=([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)", text)
        jwt = jwt_match.group(1) if jwt_match else None
        return url, jwt

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True, args=["--disable-blink-features=AutomationControlled"])
        context = await browser.new_context(
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/121.0.0.0 Safari/537.36")

        max_retries = 3
        for attempt in range(max_retries):
            # 每次重试都创建一个全新的页面，彻底抛弃旧的失效 Session
            page = await context.new_page()
            warp_auth_url = access_jwt = cf_authorization = None

            def capture_token_from_url(url):
                nonlocal warp_auth_url, access_jwt
                found_url, found_jwt = extract_from_text(url)
                if found_url: warp_auth_url = found_url
                if found_jwt: access_jwt = found_jwt

            page.on("request", lambda req: capture_token_from_url(req.url))
            page.on("response", lambda resp: capture_token_from_url(resp.url))

            await send_log(websocket, f"🌍 [后台] 正在初始化安全会话 (第 {attempt + 1} 次尝试)...")
            await page.goto(f"https://{org}.cloudflareaccess.com/warp")

            await send_log(websocket, "⏳ [后台] 正在向 Cloudflare 请求发送全新验证码...")
            try:
                email_input = page.get_by_placeholder("example@email.com")
                await email_input.wait_for(state="visible", timeout=10000)
                await email_input.fill(email)
                await page.get_by_role("button", name="Send login code").click()
            except Exception as e:
                await page.close()
                raise Exception("无法加载页面或提交邮箱，请检查 Team Name 是否正确。")

            # 重新挂起等待前端输入的 Future 拦截器
            if state["otp_future"].done():
                state["otp_future"] = asyncio.Future()

            await websocket.send_json({"type": "prompt_otp"})
            await send_log(websocket, "⏳ [等待输入] 全新验证码已发送至邮箱，请查收并输入...")

            try:
                otp = await asyncio.wait_for(state["otp_future"], timeout=300)
            except asyncio.TimeoutError:
                raise Exception("等待验证码输入超时，请重新开始提取任务。")
            await send_log(websocket, "⏳ [后台] 已收到验证码，正在提交并校验...")

            try:
                code_input = page.locator('input[name="code"]')
                await code_input.wait_for(state="visible", timeout=5000)
                await code_input.fill(otp)
            except:
                await page.locator('input').first.fill(otp)

            await page.locator('button[type="submit"]').click()

            # 急速轮询等待 Token。Cloudflare 有时跳转较慢，最多等待 30 秒。
            for i in range(60):
                capture_token_from_url(page.url)
                cookies = await context.cookies()
                for c in cookies:
                    if c['name'] == 'CF_Authorization':
                        if not access_jwt: access_jwt = c['value']
                        break
                if access_jwt:
                    break
                if i in (9, 29):
                    await send_log(websocket, "⏳ [后台] 仍在等待 Cloudflare 校验跳转，请稍候...")
                await asyncio.sleep(0.5)

            # 关闭当前页面，为潜在的下一次重试清理环境
            await page.close()

            if access_jwt:
                break
            else:
                if attempt < max_retries - 1:
                    await send_log(websocket, "❌ 验证失败：验证码错误、已过期或 Cloudflare 未完成跳转，即将重新获取...")
                else:
                    raise Exception("连续 3 次验证失败，流程中断。")

        await browser.close()

    if not access_jwt:
        raise Exception("未能截获 Token。可能是系统限流或遭隐形盾拦截。")
    return access_jwt


# ==========================================
# 4. Web 路由与 WebSocket 通信
# ==========================================
@app.get("/", response_class=HTMLResponse)
async def get_index(request: Request):
    return templates.TemplateResponse(request, "index.html")


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    state = {"otp_future": None}

    async def process_extraction(data):
        org = data.get("org")
        email = data.get("email")
        proxy_name = data.get("proxy_name", "WARP")
        state["otp_future"] = asyncio.Future()

        try:
            # 1. 提取 Token
            access_jwt = await extract_cloudflare_token(websocket, org, email, state)
            await send_log(websocket, "✅ 成功截获 Access JWT！")

            # 2. 优选 IP
            best_ip = await scan_warp_ips(websocket, sample_size=30)

            # 3. 注册 Cloudflare 设备
            await send_log(websocket, "⏳ 正在生成本地密钥并注册设备...")
            priv_key, pub_key = generate_keypair()
            install_id = random_install_id()
            fcm_token = f"{install_id}:APA91b{''.join(secrets.choice('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789') for _ in range(134))}"

            cf_api = "https://api.cloudflareclient.com/v0a2158"
            headers = {"User-Agent": "okhttp/3.12.1", "CF-Client-Version": "a-6.10-2158",
                       "Content-Type": "application/json"}

            reg_body = {
                "key": pub_key, "install_id": install_id, "fcm_token": fcm_token,
                "tos": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                "model": "PC", "serial_number": install_id, "locale": "zh_CN"
            }

            reg_headers = dict(headers)
            reg_headers["Cf-Access-Jwt-Assertion"] = access_jwt

            async with httpx.AsyncClient() as client:
                resp = await client.post(f"{cf_api}/reg", headers=reg_headers, json=reg_body, timeout=15.0)
                reg_data = resp.json()
                device_id = reg_data.get("id")
                device_token = reg_data.get("token")

                auth_headers = dict(headers)
                auth_headers["Authorization"] = f"Bearer {device_token}"

                await send_log(websocket, "⏳ 正在拉取最终路由配置...")
                conf_resp = await client.get(f"{cf_api}/reg/{device_id}", headers=auth_headers, timeout=10.0)
                config = conf_resp.json()["config"]

            client_id = config.get("client_id", "")
            self_ipv4 = config["interface"]["addresses"]["v4"]
            self_ipv6 = config["interface"]["addresses"].get("v6") or "2606:4700:cf1:1000::2"
            peer_pub = config["peers"][0]["public_key"]
            reserved = client_id_to_reserved(client_id)

            # 4. 生成所有客户端的配置
            peer_line = f"peer = (public-key = {peer_pub}, allowed-ips = 0.0.0.0/0, endpoint = {best_ip}:2408, keepalive = 45"
            peer_line += f", client-id = {client_id})" if client_id else ")"

            surge_conf = f"# 把下面这行放进 [Proxy] 段\n{proxy_name} = wireguard, section-name=ZERO\n\n# 把下面整段放进配置文件（可放独立分区）\n[WireGuard ZERO]\nprivate-key = {priv_key}\nself-ip = {self_ipv4}\ndns-server = 1.1.1.1\nmtu = 1280\n{peer_line}"

            res_str = f"\n    reserved: [{reserved[0]}, {reserved[1]}, {reserved[2]}]" if reserved else ""
            stash_conf = f"# Stash / Mihomo / Clash Meta 可参考下面这段放进 proxies:\n  - name: {proxy_name}\n    type: wireguard\n    server: {best_ip}\n    port: 2408\n    ip: {self_ipv4}\n    ipv6: {self_ipv6}\n    private-key: {priv_key}\n    public-key: {peer_pub}{res_str}\n    dns: [1.1.1.1]\n    mtu: 1280\n    udp: true\n    benchmark-url: http://cp.cloudflare.com/generate_204"

            res_loon = f", reserved={reserved[0]}/{reserved[1]}/{reserved[2]}" if reserved else ""
            loon_conf = f"# 把下面这段放进 [Proxy] 段:\n{proxy_name} = wireguard, server={best_ip}, port=2408, ip={self_ipv4}, ipv6={self_ipv6}, private-key={priv_key}, public-key={peer_pub}, dns=1.1.1.1, mtu=1280, keepalive=45, udp=true{res_loon}"

            sr_conf = f"# 把下面这行放进 [Proxy] 段\n{proxy_name} = wireguard, section-name=ZERO\n\n# 把下面整段放进配置文件，可放在 [MITM] 前后独立分区\n[WireGuard ZERO]\nprivate-key = {priv_key}\nself-ip = {self_ipv4}\nself-ip-v6 = {self_ipv6}\ndns-server = 1.1.1.1\nmtu = 1280\n{peer_line}"

            await websocket.send_json({
                "type": "result",
                "configs": {
                    "Surge": surge_conf,
                    "Stash / Meta": stash_conf,
                    "Loon": loon_conf,
                    "Shadowrocket": sr_conf
                }
            })
            await send_log(websocket, "🎉 节点提取与配置生成完毕！")

        except Exception as e:
            logger.exception("提取任务失败")
            await websocket.send_json({"type": "log", "msg": f"❌ {str(e)}"})
        finally:
            state["otp_future"] = None

    async def process_scan():
        try:
            best_ip = await scan_warp_ips(websocket, sample_size=100)
            await send_log(websocket, f"🎯 最优直连网关: {best_ip}:2408")
        except Exception as e:
            logger.exception("扫描任务失败")
            await websocket.send_json({"type": "log", "msg": f"❌ 扫描中断: {str(e)}"})

    try:
        while True:
            data = await websocket.receive_json()
            action = data.get("action")

            if action == "submit_otp" and state["otp_future"] and not state["otp_future"].done():
                logger.info("收到前端提交的验证码")
                state["otp_future"].set_result(data.get("otp"))
            elif action == "start_scan":
                asyncio.create_task(process_scan())
            elif action == "start_extract":
                asyncio.create_task(process_extraction(data))

    except WebSocketDisconnect:
        pass


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)