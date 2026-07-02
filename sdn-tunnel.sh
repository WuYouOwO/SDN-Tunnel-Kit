#!/usr/bin/env bash
# =============================================================================
#  sdn-tunnel.sh — FOU-over-Xray L3 overlay + BIRD/BGP，一键通用管理脚本
# -----------------------------------------------------------------------------
#  在两台(可能都在 NAT 后、地址族相反、需经中继)主机间搭 ipip+FOU 三层隧道，
#  用 Xray(reverse portal/bridge + dokodemo)承载、BIRD/BGP 统一路由，并支持
#  按前缀的双向策略出口。一端 ROLE=portal(监听)，另一端 ROLE=bridge(拨号)。
#
#  端口方案两端对称：本地 tun-fou 发到 FOU_ENCAP_PORT(xray dokodemo 监听同端口)，
#  xray 投递到对端 FOU_DECAP_PORT(内核 fou 解封)。两端 ENCAP/DECAP 用同一对数字即可。
#
#  用法：
#    sdn-tunnel.sh init                 # 生成配置模板 /etc/sdn-tunnel/tunnel.conf
#    sdn-tunnel.sh keys                 # 生成 UUID + REALITY 密钥对 + shortId
#    sdn-tunnel.sh install              # 按配置全量部署(接口/xray/bird/systemd)
#    sdn-tunnel.sh transport <t>        # 热切协议：vmess | vless | reality
#    sdn-tunnel.sh diag                 # 全面链路诊断
#    sdn-tunnel.sh status               # 快速状态
#    sdn-tunnel.sh egress-add <cidr>    # 宣告前缀并让【本机】做该前缀的出口
#    sdn-tunnel.sh egress-del <cidr>    # 撤销
#    sdn-tunnel.sh egress-list          # 查看
#    sdn-tunnel.sh gen-peer             # 打印对端起步配置(镜像本端，含 TODO)
#    sdn-tunnel.sh push                 # scp 本脚本到对端(需 PEER_SSH + SSH 免密)
#    sdn-tunnel.sh up | down | render | restart | bgp | uninstall
#
#  依赖：iproute2、xray(>=1.8/26.x)、bird2、nft 或 iptables。
# =============================================================================

CONF="${SDN_CONF:-/etc/sdn-tunnel/tunnel.conf}"
STATE_DIR="/etc/sdn-tunnel"
EGRESS_LIST="$STATE_DIR/egress.list"
XRAY_CONF="/usr/local/etc/xray/sdn-tunnel.json"
BIRD_CONF="/etc/bird/bird.conf"
UNDERLAY="/usr/local/sbin/sdn-fou-up.sh"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# ---------- 输出helpers ----------
if [ -t 1 ]; then C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else C_R=; C_G=; C_Y=; C_B=; C_D=; C_0=; fi
log(){ printf '%s\n' "${C_B}==>${C_0} $*"; }
ok(){  printf '%s\n' "  ${C_G}✔${C_0} $*"; }
warn(){printf '%s\n' "  ${C_Y}!${C_0} $*"; }
bad(){ printf '%s\n' "  ${C_R}✗${C_0} $*"; }
die(){ printf '%s\n' "${C_R}error:${C_0} $*" >&2; exit 1; }
need_root(){ [ "$(id -u)" = 0 ] || die "需要 root。"; }
have(){ command -v "$1" >/dev/null 2>&1; }

load_conf(){ [ -f "$CONF" ] || die "找不到配置 $CONF，先跑：$0 init"; . "$CONF";
  : "${DUMMY_IF:=dummy0}" "${TUN_MTU:=1400}" "${TRANSPORT:=vmess}"
  [ -n "${WAN_IF:-}" ] || WAN_IF="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
}

xray_bin(){ command -v xray || echo /usr/local/bin/xray; }
xray_test(){ local f="$1" x; x="$(xray_bin)"; "$x" test -c "$f" >/dev/null 2>&1 || "$x" -test -config "$f" >/dev/null 2>&1; }

# =============================================================================
#  init / keys
# =============================================================================
cmd_init(){
  need_root; mkdir -p "$STATE_DIR"
  [ -f "$CONF" ] && die "$CONF 已存在(不覆盖)。"
  cat > "$CONF" <<'EOF'
# ===== sdn-tunnel 配置 =====
ROLE=bridge                 # bridge=拨号端(常在 NAT 后)  portal=监听端(可被访问)
TRANSPORT=vmess             # vmess(推荐,能穿中继) | vless(明文) | reality(需干净TLS路径)
UUID=REPLACE-WITH-UUID      # 两端必须一致，用 `sdn-tunnel.sh keys` 生成

# --- 连接 ---
PEER_DIAL_ADDR=example.com  # bridge 用：要拨的地址(对端/中继前端；可域名/IPv6/IPv4)
PEER_DIAL_PORT=21122        # bridge 用：要拨的端口
LISTEN_PORT=21122           # portal 用：监听端口

# --- REALITY(仅 TRANSPORT=reality 时需要) ---
REALITY_SNI=www.microsoft.com
REALITY_DEST=www.microsoft.com:443
REALITY_SHORTID=8f
REALITY_FINGERPRINT=chrome
REALITY_PUBLIC_KEY=         # bridge 用：对端(portal)私钥对应的公钥
REALITY_PRIVATE_KEY=        # portal 用：本机私钥

# --- L3 底层(两端对称同值) ---
TUN_LOCAL_IP=10.0.100.2/30  # 本端 tun-fou 地址(对端用 10.0.100.1/30)
TUN_PEER_IP=10.0.100.1      # 对端 tun-fou 地址(= BGP 邻居)
FOU_ENCAP_PORT=40000        # 本地 tun-fou 发送 & xray dokodemo 监听(两端同值)
FOU_DECAP_PORT=40001        # 内核 fou 解封 & xray 投递目标(两端同值)
TUN_MTU=1400

# --- BGP(BIRD 2.x) ---
LOCAL_ASN=65002
PEER_ASN=65001
ROUTER_ID=10.0.100.2
LAN_PREFIX=172.19.2.0/24    # 本端宣告的 LAN(挂到 dummy0)
DUMMY_IP=172.19.2.1/24
DUMMY_IF=dummy0

# --- 策略出口 NAT ---
WAN_IF=                     # 留空=自动探测默认路由网卡

# --- 对端 SSH(可选：push 用，基于你的 SSH 免密) ---
PEER_SSH=                   # 例 root@203.0.113.5
PEER_SSH_PORT=22

# --- 诊断(可选) ---
PEER_TEST_IP=              # 对端某个可 ping 的 IP(如对端 dummy0)，用于跨 LAN 诊断
EOF
  ok "已写模板 $CONF —— 改好后执行：$0 install"
  warn "对端机器把 ROLE 改成对方角色、TUN_LOCAL_IP/PEER 对调、ASN/ROUTER_ID/LAN 相应修改，UUID 和端口保持一致。"
}

cmd_keys(){
  local x; x="$(xray_bin)"; have "$x" || die "未找到 xray。"
  echo "UUID        : $("$x" uuid)"
  echo "SHORTID     : $(head -c1 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  echo "--- REALITY x25519 (portal 用 PrivateKey，bridge 用对应 PublicKey) ---"
  "$x" x25519
}

# =============================================================================
#  渲染：xray / bird / underlay / systemd
# =============================================================================
render_xray(){
  load_conf; mkdir -p "$(dirname "$XRAY_CONF")"
  local OB_PROTO OB_SET OB_STREAM IB_PROTO IB_SET IB_STREAM
  case "$TRANSPORT" in
    vmess)
      OB_PROTO=vmess; IB_PROTO=vmess
      OB_SET="\"settings\":{\"vnext\":[{\"address\":\"$PEER_DIAL_ADDR\",\"port\":$PEER_DIAL_PORT,\"users\":[{\"id\":\"$UUID\",\"security\":\"auto\"}]}]}"
      IB_SET="\"settings\":{\"clients\":[{\"id\":\"$UUID\"}]}"
      OB_STREAM="\"streamSettings\":{\"network\":\"tcp\",\"security\":\"none\"}"
      IB_STREAM="$OB_STREAM" ;;
    vless)
      OB_PROTO=vless; IB_PROTO=vless
      OB_SET="\"settings\":{\"vnext\":[{\"address\":\"$PEER_DIAL_ADDR\",\"port\":$PEER_DIAL_PORT,\"users\":[{\"id\":\"$UUID\",\"encryption\":\"none\"}]}]}"
      IB_SET="\"settings\":{\"clients\":[{\"id\":\"$UUID\"}],\"decryption\":\"none\"}"
      OB_STREAM="\"streamSettings\":{\"network\":\"tcp\",\"security\":\"none\"}"
      IB_STREAM="$OB_STREAM" ;;
    reality)
      OB_PROTO=vless; IB_PROTO=vless
      OB_SET="\"settings\":{\"vnext\":[{\"address\":\"$PEER_DIAL_ADDR\",\"port\":$PEER_DIAL_PORT,\"users\":[{\"id\":\"$UUID\",\"encryption\":\"none\"}]}]}"
      IB_SET="\"settings\":{\"clients\":[{\"id\":\"$UUID\"}],\"decryption\":\"none\"}"
      OB_STREAM="\"streamSettings\":{\"network\":\"tcp\",\"security\":\"reality\",\"realitySettings\":{\"fingerprint\":\"${REALITY_FINGERPRINT:-chrome}\",\"serverName\":\"$REALITY_SNI\",\"publicKey\":\"$REALITY_PUBLIC_KEY\",\"shortId\":\"$REALITY_SHORTID\"}}"
      IB_STREAM="\"streamSettings\":{\"network\":\"tcp\",\"security\":\"reality\",\"realitySettings\":{\"show\":false,\"dest\":\"$REALITY_DEST\",\"xver\":0,\"serverNames\":[\"$REALITY_SNI\"],\"privateKey\":\"$REALITY_PRIVATE_KEY\",\"shortIds\":[\"$REALITY_SHORTID\"]}}" ;;
    *) die "未知 TRANSPORT=$TRANSPORT (应为 vmess|vless|reality)";;
  esac

  if [ "$ROLE" = bridge ]; then
    cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "reverse": { "bridges": [ { "tag": "bridge", "domain": "fou.private" } ] },
  "inbounds": [
    { "tag": "fwd-in", "listen": "127.0.0.1", "port": $FOU_ENCAP_PORT, "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1", "port": $FOU_DECAP_PORT, "network": "udp" } }
  ],
  "outbounds": [
    { "tag": "tunnel-out", "protocol": "$OB_PROTO", $OB_SET, $OB_STREAM },
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": { "rules": [
    { "type": "field", "inboundTag": ["bridge"], "domain": ["full:fou.private"], "outboundTag": "tunnel-out" },
    { "type": "field", "inboundTag": ["fwd-in"], "outboundTag": "tunnel-out" },
    { "type": "field", "inboundTag": ["bridge"], "outboundTag": "direct" }
  ] }
}
EOF
  elif [ "$ROLE" = portal ]; then
    cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "reverse": { "portals": [ { "tag": "portal", "domain": "fou.private" } ] },
  "inbounds": [
    { "tag": "tunnel-in", "listen": "0.0.0.0", "port": $LISTEN_PORT, "protocol": "$IB_PROTO", $IB_SET, $IB_STREAM },
    { "tag": "fou-loopback-in", "listen": "127.0.0.1", "port": $FOU_ENCAP_PORT, "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1", "port": $FOU_DECAP_PORT, "network": "udp" } }
  ],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" } ],
  "routing": { "rules": [
    { "type": "field", "inboundTag": ["tunnel-in"], "domain": ["full:fou.private"], "outboundTag": "portal" },
    { "type": "field", "inboundTag": ["tunnel-in"], "port": $FOU_DECAP_PORT, "outboundTag": "direct" },
    { "type": "field", "inboundTag": ["fou-loopback-in"], "outboundTag": "portal" }
  ] }
}
EOF
  else die "未知 ROLE=$ROLE (应为 bridge|portal)"; fi

  xray_test "$XRAY_CONF" && ok "xray 配置校验通过 ($TRANSPORT / $ROLE)" || { bad "xray 配置校验失败"; "$(xray_bin)" test -c "$XRAY_CONF" 2>&1 | tail -5; return 1; }
}

render_bird(){
  load_conf
  local statics="" rejects=""
  if [ -s "$EGRESS_LIST" ]; then
    while read -r p; do [ -n "$p" ] || continue; statics+="  route $p blackhole;\n"; rejects+="$p, "; done < "$EGRESS_LIST"
  fi
  { echo "# auto-generated by sdn-tunnel.sh — 勿手改(用 egress-add/del)"
    echo "router id $ROUTER_ID;"
    echo "log syslog all;"
    echo
    echo "protocol device { }"
    echo "protocol direct { ipv4; interface \"$DUMMY_IF\"; }"
    if [ -n "$statics" ]; then
      echo "protocol static sdn_egress {"; echo "  ipv4;"; printf "%b" "$statics"; echo "}"
    fi
    echo "protocol kernel {"
    echo "  ipv4 {"
    echo "    import none;"
    if [ -n "$rejects" ]; then echo "    export filter { if net ~ [ ${rejects%, } ] then reject; accept; };"
    else echo "    export all;"; fi
    echo "  };"
    echo "}"
    echo "protocol bgp peer {"
    echo "  local ${TUN_LOCAL_IP%/*} as $LOCAL_ASN;"
    echo "  neighbor $TUN_PEER_IP as $PEER_ASN;"
    echo "  ipv4 { import all; export all; };"
    echo "}"
  } > "$BIRD_CONF"
}

render_underlay(){
  load_conf; mkdir -p "$(dirname "$UNDERLAY")"
  cat > "$UNDERLAY" <<EOF
#!/usr/bin/env bash
# auto-generated by sdn-tunnel.sh — L3 底层(fou/ipip/dummy) + 策略出口重放
. "$CONF"
: "\${DUMMY_IF:=dummy0}" "\${TUN_MTU:=1400}"
modprobe fou 2>/dev/null||true; modprobe ipip 2>/dev/null||true; modprobe dummy 2>/dev/null||true
ip fou show 2>/dev/null | grep -q "port \$FOU_DECAP_PORT" || ip fou add port \$FOU_DECAP_PORT ipproto 4
ip link show tun-fou >/dev/null 2>&1 || ip link add name tun-fou type ipip remote 127.0.0.1 local 127.0.0.1 encap fou encap-dport \$FOU_ENCAP_PORT
ip addr replace \$TUN_LOCAL_IP dev tun-fou
ip link set tun-fou mtu \$TUN_MTU up
ip link show \$DUMMY_IF >/dev/null 2>&1 || ip link add \$DUMMY_IF type dummy
ip addr replace \$DUMMY_IP dev \$DUMMY_IF
ip link set \$DUMMY_IF up
"$SELF" egress-apply 2>/dev/null || true
EOF
  chmod +x "$UNDERLAY"
}

render_systemd(){
  cat > /etc/systemd/system/sdn-fou.service <<EOF
[Unit]
Description=SDN FOU/ipip L3 underlay
After=network-online.target
Wants=network-online.target
Before=sdn-xray.service bird.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$UNDERLAY
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/sdn-xray.service <<EOF
[Unit]
Description=SDN Xray (FOU-over-tunnel)
After=network-online.target sdn-fou.service
Wants=network-online.target
Requires=sdn-fou.service
[Service]
Type=simple
ExecStart=$(xray_bin) run -config $XRAY_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# =============================================================================
#  install / render / up / down / restart / uninstall
# =============================================================================
cmd_render(){ need_root; render_xray && render_bird && render_underlay && ok "已渲染 xray/bird/underlay"; }

cmd_install(){
  need_root; load_conf
  have "$(xray_bin)" || die "未安装 xray。"; have bird || warn "未检测到 bird(BGP 将不可用)。"
  [ "$UUID" = "REPLACE-WITH-UUID" ] && die "请先在 $CONF 填 UUID(可用 $0 keys 生成)。"
  log "渲染配置"
  [ -f "$BIRD_CONF" ] && cp -a "$BIRD_CONF" "$BIRD_CONF.sdnbak.$(date +%s 2>/dev/null||echo x)" 2>/dev/null
  render_xray || die "xray 配置无效"; render_bird; render_underlay; render_systemd
  log "启动底层 + 服务"
  systemctl enable --now sdn-fou.service >/dev/null 2>&1 && ok "sdn-fou active"
  systemctl enable --now sdn-xray.service >/dev/null 2>&1 && ok "sdn-xray active"
  if have birdc; then systemctl enable --now bird >/dev/null 2>&1; birdc configure >/dev/null 2>&1 || systemctl restart bird; ok "bird active"; fi
  echo; cmd_status
}

cmd_up(){ need_root; render_underlay; "$UNDERLAY" && ok "底层已建立"; }
cmd_down(){ need_root; ip link del tun-fou 2>/dev/null && ok "删 tun-fou" || true
  load_conf; ip fou del port "$FOU_DECAP_PORT" ipproto 4 2>/dev/null || true; warn "dummy0/LAN 保留(如需删: ip link del $DUMMY_IF)"; }
cmd_restart(){ need_root; render_xray && systemctl restart sdn-xray 2>/dev/null; have birdc && birdc configure >/dev/null 2>&1; ok "已重启 xray + 重载 bird"; }

cmd_uninstall(){
  need_root; load_conf
  log "停用服务"; systemctl disable --now sdn-xray sdn-fou 2>/dev/null || true
  rm -f /etc/systemd/system/sdn-xray.service /etc/systemd/system/sdn-fou.service; systemctl daemon-reload
  log "拆接口/规则"; ip link del tun-fou 2>/dev/null||true; ip fou del port "$FOU_DECAP_PORT" ipproto 4 2>/dev/null||true
  fw_flush
  warn "保留:$CONF、$BIRD_CONF、$DUMMY_IF(如需彻底清理请手动删)。"
  ok "已卸载 sdn-tunnel(bird 未动)。"
}

# =============================================================================
#  transport 热切换
# =============================================================================
cmd_transport(){
  need_root; local t="${1:-}"; case "$t" in vmess|vless|reality);; *) die "用法: transport vmess|vless|reality";; esac
  load_conf
  if [ "$t" = reality ]; then
    [ "$ROLE" = portal ] && [ -z "${REALITY_PRIVATE_KEY:-}" ] && die "portal 需要 REALITY_PRIVATE_KEY(见 $0 keys)。"
    [ "$ROLE" = bridge ] && [ -z "${REALITY_PUBLIC_KEY:-}" ] && die "bridge 需要 REALITY_PUBLIC_KEY。"
  fi
  sed -i "s/^TRANSPORT=.*/TRANSPORT=$t/" "$CONF"
  log "切换 TRANSPORT → $t"; render_xray || { sed -i "s/^TRANSPORT=.*/TRANSPORT=$TRANSPORT/" "$CONF"; die "渲染失败,已回滚。"; }
  systemctl restart sdn-xray 2>/dev/null || warn "sdn-xray 未运行(先 install)。"
  ok "本机已切到 $t。"; warn "对端必须切到相同协议(reality 还需匹配同一对密钥)才能通。"
  sleep 2; diag_tunnel_quick
}

# =============================================================================
#  策略出口 egress
# =============================================================================
fw_backend(){ if have nft; then echo nft; elif have iptables; then echo iptables; else echo none; fi; }
norm_cidr(){ case "$1" in */*) echo "$1";; *) echo "$1/32";; esac; }

fw_masq_add(){ # $1=cidr
  load_conf; local p="$1" b; b="$(fw_backend)"; [ -n "$WAN_IF" ] || die "无法确定 WAN_IF。"
  case "$b" in
    nft)
      nft list table ip sdn_nat >/dev/null 2>&1 || nft add table ip sdn_nat
      nft list chain ip sdn_nat postrouting >/dev/null 2>&1 || nft "add chain ip sdn_nat postrouting { type nat hook postrouting priority srcnat ; policy accept ; }"
      nft list chain ip sdn_nat postrouting | grep -q "daddr ${p%/*} " || nft add rule ip sdn_nat postrouting ip daddr "$p" oifname "$WAN_IF" masquerade ;;
    iptables)
      iptables -t nat -C POSTROUTING -d "$p" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -d "$p" -o "$WAN_IF" -j MASQUERADE
      iptables -C FORWARD -i tun-fou -o "$WAN_IF" -j ACCEPT 2>/dev/null || iptables -I FORWARD -i tun-fou -o "$WAN_IF" -j ACCEPT
      iptables -C FORWARD -i "$WAN_IF" -o tun-fou -j ACCEPT 2>/dev/null || iptables -I FORWARD -i "$WAN_IF" -o tun-fou -j ACCEPT ;;
    *) die "既无 nft 也无 iptables。";;
  esac
}
fw_masq_del(){ # $1=cidr
  load_conf; local p="$1" b h; b="$(fw_backend)"
  case "$b" in
    nft)
      h="$(nft -a list chain ip sdn_nat postrouting 2>/dev/null | awk -v ip="${p%/*}" '$0 ~ ip {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}')"
      [ -n "$h" ] && nft delete rule ip sdn_nat postrouting handle "$h" 2>/dev/null || true ;;
    iptables)
      iptables -t nat -D POSTROUTING -d "$p" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true ;;
  esac
}
fw_flush(){ if have nft; then nft delete table ip sdn_nat 2>/dev/null||true; fi; }

cmd_egress_add(){
  need_root; load_conf; [ -n "${1:-}" ] || die "用法: egress-add <ip|cidr>"
  local p; p="$(norm_cidr "$1")"; mkdir -p "$STATE_DIR"; touch "$EGRESS_LIST"
  grep -qxF "$p" "$EGRESS_LIST" || echo "$p" >> "$EGRESS_LIST"
  log "宣告 $p 并让本机做其出口"
  render_bird; have birdc && { birdc configure >/dev/null 2>&1 || systemctl restart bird; }
  sysctl -w net.ipv4.ip_forward=1 >/dev/null; echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-sdn-tunnel.conf
  fw_masq_add "$p"
  ok "已宣告 + 转发 + NAT($p 出 $WAN_IF)。对端会经隧道把该前缀路由到本机。"
}
cmd_egress_del(){
  need_root; load_conf; [ -n "${1:-}" ] || die "用法: egress-del <ip|cidr>"
  local p; p="$(norm_cidr "$1")"; [ -f "$EGRESS_LIST" ] && grep -vxF "$p" "$EGRESS_LIST" > "$EGRESS_LIST.tmp" 2>/dev/null && mv "$EGRESS_LIST.tmp" "$EGRESS_LIST"
  render_bird; have birdc && { birdc configure >/dev/null 2>&1 || systemctl restart bird; }
  fw_masq_del "$p"
  ok "已撤销 $p(对端 BGP 撤回后其路由自动消失)。"
}
cmd_egress_apply(){ # 供 underlay 开机重放
  load_conf; [ -s "$EGRESS_LIST" ] || exit 0
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  while read -r p; do [ -n "$p" ] && fw_masq_add "$p"; done < "$EGRESS_LIST"
}
cmd_egress_list(){ [ -s "$EGRESS_LIST" ] && { echo "本机作为出口宣告的前缀:"; cat "$EGRESS_LIST"; } || echo "(无)"; }

# =============================================================================
#  诊断 / 状态
# =============================================================================
CHK_OK=0; CHK_BAD=0
chk(){ local s="$1"; shift; case "$s" in ok) ok "$*"; CHK_OK=$((CHK_OK+1));; warn) warn "$*";; bad) bad "$*"; CHK_BAD=$((CHK_BAD+1));; esac; }
port_open(){ timeout "${3:-5}" bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

diag_tunnel_quick(){ load_conf; if ping -c2 -W2 "$TUN_PEER_IP" >/dev/null 2>&1; then ok "隧道 ping $TUN_PEER_IP 通"; else bad "隧道 ping $TUN_PEER_IP 不通"; fi; }

cmd_diag(){
  load_conf
  log "配置: ROLE=$ROLE TRANSPORT=$TRANSPORT WAN_IF=${WAN_IF:-?}"
  log "内核模块"; for m in fou ipip; do lsmod 2>/dev/null | grep -q "^$m" && chk ok "$m 已加载" || chk bad "$m 未加载"; done
  log "L3 接口"
    if ip link show tun-fou >/dev/null 2>&1; then
      ip -d link show tun-fou 2>/dev/null | grep -q "encap-dport $FOU_ENCAP_PORT" && chk ok "tun-fou encap-dport=$FOU_ENCAP_PORT" || chk bad "tun-fou encap-dport 不符(应 $FOU_ENCAP_PORT)"
      ip addr show tun-fou | grep -q "${TUN_LOCAL_IP%/*}" && chk ok "tun-fou 地址 $TUN_LOCAL_IP" || chk bad "tun-fou 地址缺失"
    else chk bad "tun-fou 不存在(先 up/install)"; fi
    ip fou show 2>/dev/null | grep -q "port $FOU_DECAP_PORT" && chk ok "内核 fou 解封端口 $FOU_DECAP_PORT" || chk bad "内核 fou $FOU_DECAP_PORT 缺失"
    ip addr show "$DUMMY_IF" 2>/dev/null | grep -q "${DUMMY_IP%/*}" && chk ok "$DUMMY_IF 地址 $DUMMY_IP" || chk warn "$DUMMY_IF/LAN 缺失"
  log "Xray"
    if pgrep -x xray >/dev/null 2>&1 || systemctl is-active --quiet sdn-xray 2>/dev/null; then chk ok "xray 运行中"; else chk bad "xray 未运行"; fi
    ss -ulnp 2>/dev/null | grep -q "127.0.0.1:$FOU_ENCAP_PORT" && chk ok "dokodemo 监听 udp/$FOU_ENCAP_PORT" || chk warn "未见 dokodemo udp/$FOU_ENCAP_PORT"
    [ "$ROLE" = portal ] && { ss -tlnp 2>/dev/null | grep -q ":$LISTEN_PORT" && chk ok "portal 监听 tcp/$LISTEN_PORT" || chk bad "portal 未监听 $LISTEN_PORT"; }
    if [ "$ROLE" = bridge ]; then
      if port_open "$PEER_DIAL_ADDR" "$PEER_DIAL_PORT" 6; then chk ok "可达对端 $PEER_DIAL_ADDR:$PEER_DIAL_PORT (TCP)"; else chk bad "无法 TCP 连到 $PEER_DIAL_ADDR:$PEER_DIAL_PORT"; fi
    fi
  log "隧道 & 路由"
    if ping -c3 -W2 "$TUN_PEER_IP" >/dev/null 2>&1; then chk ok "隧道 ping $TUN_PEER_IP 通"
    else chk bad "隧道 ping $TUN_PEER_IP 不通"
      if [ "$ROLE" = bridge ] && port_open "$PEER_DIAL_ADDR" "$PEER_DIAL_PORT" 5; then
        warn "TCP 能连但隧道不通 → 多为协议/认证不匹配或中继破坏 TLS。"
        journalctl -u sdn-xray -n 40 --no-pager 2>/dev/null | grep -iE 'available destination|EOF|reality|handshak' | tail -3
        [ "$TRANSPORT" = reality ] && warn "REALITY 常被中转打断 → 试：$0 transport vmess (两端都切)。"
      fi
    fi
    if have birdc; then
      birdc show protocols 2>/dev/null | grep -q Established && chk ok "BGP Established" || chk bad "BGP 未 Established"
      local n; n=$(birdc show route 2>/dev/null | grep -c 'via .* tun-fou' 2>/dev/null); [ "${n:-0}" -gt 0 ] && chk ok "学到 $n 条经隧道的路由" || chk warn "尚未学到隧道路由"
    else chk warn "无 birdc(BGP 未装/未用)"; fi
    [ -n "${PEER_TEST_IP:-}" ] && { ping -c2 -W2 "$PEER_TEST_IP" >/dev/null 2>&1 && chk ok "跨 LAN 到 $PEER_TEST_IP 通" || chk warn "跨 LAN 到 $PEER_TEST_IP 不通"; }
  log "时间(REALITY/VMess 对时钟敏感)"; date -u '+  UTC %F %T'
  echo; log "小结: ${C_G}$CHK_OK 通过${C_0} / ${C_R}$CHK_BAD 失败${C_0}"
  [ -s "$EGRESS_LIST" ] && { echo; log "策略出口前缀"; cat "$EGRESS_LIST"; }
}

cmd_status(){
  load_conf
  printf "%-14s %s / %s\n" "角色/协议" "$ROLE" "$TRANSPORT"
  for s in sdn-fou sdn-xray bird; do printf "%-14s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null||echo n/a)"; done
  printf "%-14s %s → %s  " "tun-fou" "$TUN_LOCAL_IP" "$TUN_PEER_IP"; ping -c1 -W2 "$TUN_PEER_IP" >/dev/null 2>&1 && echo "${C_G}up${C_0}" || echo "${C_R}down${C_0}"
  have birdc && printf "%-14s %s\n" "BGP" "$(birdc show protocols 2>/dev/null | awk '/BGP/{print $1"="$6}' | tr '\n' ' ')"
  [ -s "$EGRESS_LIST" ] && printf "%-14s %s\n" "出口前缀" "$(tr '\n' ' ' < "$EGRESS_LIST")"
}

cmd_bgp(){ have birdc || die "无 birdc"; echo "== protocols =="; birdc show protocols; echo "== routes =="; birdc show route; }

# =============================================================================
#  对端:生成起步配置 / 推送脚本
# =============================================================================
cmd_gen_peer(){
  load_conf
  local prole mask conn
  if [ "$ROLE" = bridge ]; then prole=portal; else prole=bridge; fi
  mask="${TUN_LOCAL_IP#*/}"
  if [ "$prole" = portal ]; then
    conn="LISTEN_PORT=${PEER_DIAL_PORT:-$LISTEN_PORT}"
  else
    conn="PEER_DIAL_ADDR=TODO-本机对外可达地址(本机无法自知)
PEER_DIAL_PORT=${LISTEN_PORT:-$PEER_DIAL_PORT}"
  fi
  cat <<EOF
# ===== 对端起步配置(ROLE=$prole)——复制到对端的 $CONF，改完 TODO 再 install =====
ROLE=$prole
TRANSPORT=$TRANSPORT
UUID=$UUID
$conn
REALITY_SNI=$REALITY_SNI
REALITY_DEST=$REALITY_DEST
REALITY_SHORTID=$REALITY_SHORTID
REALITY_FINGERPRINT=${REALITY_FINGERPRINT:-chrome}
REALITY_PUBLIC_KEY=$([ "$prole" = bridge ] && echo "TODO-portal私钥对应的公钥")
REALITY_PRIVATE_KEY=$([ "$prole" = portal ] && echo "TODO-portal私钥")
TUN_LOCAL_IP=$TUN_PEER_IP/$mask
TUN_PEER_IP=${TUN_LOCAL_IP%/*}
FOU_ENCAP_PORT=$FOU_ENCAP_PORT
FOU_DECAP_PORT=$FOU_DECAP_PORT
TUN_MTU=$TUN_MTU
LOCAL_ASN=$PEER_ASN
PEER_ASN=$LOCAL_ASN
ROUTER_ID=$TUN_PEER_IP
LAN_PREFIX=TODO-对端LAN(勿与本端 $LAN_PREFIX 重叠)
DUMMY_IP=TODO-对端dummy地址/掩码
DUMMY_IF=dummy0
WAN_IF=
PEER_SSH=
PEER_SSH_PORT=22
PEER_TEST_IP=${DUMMY_IP%/*}
EOF
}

cmd_push(){
  load_conf; [ -n "${PEER_SSH:-}" ] || die "先在 $CONF 设 PEER_SSH(如 root@1.2.3.4)。"
  local P="${PEER_SSH_PORT:-22}" dst="/usr/local/sbin/sdn-tunnel.sh"
  log "scp 脚本 → $PEER_SSH:$dst  (使用你的 SSH 免密/agent)"
  scp -P "$P" "$SELF" "$PEER_SSH:$dst" || die "scp 失败(检查 SSH 免密与网络)。"
  ssh -p "$P" "$PEER_SSH" "chmod +x $dst" 2>/dev/null || true
  ok "已推送到对端。到对端执行:"
  echo "    ssh -p $P $PEER_SSH"
  echo "    $dst init   # 或把本机 '$0 gen-peer' 的输出粘进 $CONF"
  echo "    # 改好配置后: $dst install && $dst diag"
}

# =============================================================================
#  dispatch
# =============================================================================
usage(){ sed -n '2,40p' "$SELF" | sed 's/^# \{0,1\}//'; }
case "${1:-}" in
  init) cmd_init ;;
  keys) cmd_keys ;;
  render) cmd_render ;;
  install) cmd_install ;;
  up) cmd_up ;;
  down) cmd_down ;;
  restart) cmd_restart ;;
  transport) shift; cmd_transport "$@" ;;
  egress-add) shift; cmd_egress_add "$@" ;;
  egress-del) shift; cmd_egress_del "$@" ;;
  egress-apply) cmd_egress_apply ;;
  egress-list) cmd_egress_list ;;
  diag) cmd_diag ;;
  status) cmd_status ;;
  bgp) cmd_bgp ;;
  gen-peer) cmd_gen_peer ;;
  push) cmd_push ;;
  uninstall) cmd_uninstall ;;
  ""|-h|--help|help) usage ;;
  *) die "未知命令: $1 (用 -h 看帮助)";;
esac
