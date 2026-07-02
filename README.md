# SDN-Tunnel-Kit


在两台**互不可直连**(可能都在 NAT 后、出口地址族相反、需经中继)的 Linux 主机之间,一键搭建:

- **ipip + FOU** 三层隧道(点到点 `tun-fou`),由 **Xray**(reverse portal/bridge + dokodemo)承载、可穿透只放行裸 TCP 的中继;
- **BIRD / BGP** 统一路由,自动互换各自 LAN 前缀;
- **按前缀的双向策略出口**(某端可作为任意前缀的互联网出口)。

一端 `ROLE=portal`(监听),另一端 `ROLE=bridge`(拨号)。传输可在 **vmess / vless / reality** 间热切换。

## 文件

| 文件 | 说明 |
|---|---|
| `sdn-tunnel.sh` | 主脚本(配置驱动的一键管理器) |
| `examples/portal.conf.example` | portal 端配置示例 |
| `examples/bridge.conf.example` | bridge 端配置示例 |
| `PoC2-report.html` | 概念验证报告(架构 + 双向策略出口实验) |

## 依赖

`iproute2`、`xray`(≥1.8 / 26.x)、`bird2`、`nft` 或 `iptables`。两端 root。

## 快速开始

```bash
chmod +x sdn-tunnel.sh
# 建议放到 PATH: cp sdn-tunnel.sh /usr/local/sbin/

# ---- Portal 端(可被访问/监听方)----
./sdn-tunnel.sh init                 # 生成 /etc/sdn-tunnel/tunnel.conf
./sdn-tunnel.sh keys                 # 生成 UUID + REALITY 密钥对 + shortId(记下)
vi /etc/sdn-tunnel/tunnel.conf       # 参考 examples/portal.conf.example
./sdn-tunnel.sh install
./sdn-tunnel.sh gen-peer             # 打印对端(bridge)起步配置

# ---- Bridge 端(NAT 后/拨号方)----
./sdn-tunnel.sh init
vi /etc/sdn-tunnel/tunnel.conf       # 参考 examples/bridge.conf.example；UUID/端口与 portal 一致
./sdn-tunnel.sh install
./sdn-tunnel.sh diag                 # 全面链路诊断
```

> 两端 `UUID`、`FOU_ENCAP_PORT/DECAP_PORT`、`TRANSPORT` 必须一致;`TUN_LOCAL_IP`/`TUN_PEER_IP`、
> `LOCAL_ASN`/`PEER_ASN`、`ROUTER_ID`、`LAN_PREFIX`/`DUMMY_IP` 两端相应对调/区分。
> reality 需匹配同一对密钥(portal 私钥、bridge 对应公钥)。

## 命令

| 命令 | 作用 |
|---|---|
| `init` / `keys` | 生成配置模板 / 生成 UUID+REALITY 密钥+shortId |
| `install` | 全量部署:模块→fou/tun-fou/dummy→xray→bird→systemd 持久化 |
| `transport vmess\|vless\|reality` | 热切协议(重渲染+重启,失败回滚)。**两端都要切** |
| `diag` | 全面诊断:模块/接口/fou/监听/对端可达/隧道/BGP/跨LAN/时钟,不通时给修复提示 |
| `status` / `bgp` | 快速状态 / BGP 邻居+路由 |
| `egress-add <cidr>` | 宣告前缀 + 开转发 + NAT,让**本机**做该前缀的互联网出口 |
| `egress-del <cidr>` / `egress-list` | 撤销 / 查看 |
| `gen-peer` | 打印对端起步配置(镜像本端,含 TODO) |
| `push` | scp 本脚本到对端(需 `PEER_SSH` + SSH 免密) |
| `up`/`down`/`render`/`restart`/`uninstall` | 底层/渲染/重启/卸载 |

## 策略出口(示例)

让"谁"上网从哪个节点出去,就在**那个节点**执行:

```bash
./sdn-tunnel.sh egress-add 5.161.7.195      # 本机成为 5.161.7.195 的出口
./sdn-tunnel.sh egress-add 203.0.113.0/24   # 也支持网段
./sdn-tunnel.sh egress-del 5.161.7.195      # 撤销
```

对端会经 BGP 学到该前缀并把流量送进隧道到本机,由本机 NAT 出网。

## 传输选型(重要)

某些跨境中继会**破坏 TLS 握手**(REALITY/WS+TLS 因此失败),但放行裸 TCP。若 `reality` 连不上而 `vless`(明文)能通,即属此类 —— 用 **`vmess`**(AEAD 加密、无 TLS 握手、可穿透)。`diag` 会在这种情况下给出提示。

## 注意

- 脚本**接管 `/etc/bird/bird.conf`**(install 时先备份 `.sdnbak.*`)。若该机 bird 另有用途,先合并。
- 若目标机已有 s-ui/官方 xray 服务,本脚本另建 `sdn-xray.service` —— 注意端口不要冲突。
- `install` / `egress-*` 会改内核转发与防火墙(nft/iptables),请在可控环境使用。

## 卸载

```bash
./sdn-tunnel.sh uninstall            # 停服务、拆接口/规则(保留配置与 bird.conf,可手动清)
```
