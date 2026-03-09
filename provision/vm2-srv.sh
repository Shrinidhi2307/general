#!/bin/bash
# =============================================================================
# VM2 (Stockholm Server) — Provisioner
# Installs: nginx, bind9, docker, python3
# Configures: inter-VLAN routes through VM1
# =============================================================================
set -euo pipefail

echo ">>> Provisioning VM2 (Server)..."

# ── Packages ──
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    iptables iproute2 iputils-ping net-tools tcpdump curl \
    nginx bind9 bind9utils \
    docker.io docker-compose python3-pip python3-venv

# ── Inter-VLAN routes via VM1 gateway ──
# Without these, traffic to other VLANs would go via the Vagrant NAT
# (bypassing VM1's firewall). These routes ensure inter-VLAN traffic
# is routed through VM1 where firewall rules are enforced.
cat > /etc/netplan/99-acme-routes.yaml << 'YAML'
network:
  version: 2
  ethernets:
    enp0s8:
      routes:
        - to: 10.0.1.128/26
          via: 10.0.1.1
        - to: 10.0.1.240/28
          via: 10.0.1.1
YAML
netplan apply 2>/dev/null || true

echo ">>> VM2 (Server) provisioned."

echo ">>> 1. Importing Certificates from VM3..."
# 从共享文件夹把证书复制到 VM2 的系统目录中
mkdir -p /etc/nginx/ssl
cp /vagrant/shared_certs/ca.crt /etc/nginx/ssl/
cp /vagrant/shared_certs/vm2-srv.crt /etc/nginx/ssl/
cp /vagrant/shared_certs/vm2-srv.key /etc/nginx/ssl/
chmod 600 /etc/nginx/ssl/*.key

echo ">>> 2. Configuring BIND9 (Internal DNS)..."
# 让域名 secure.acme.com 指向 VM2 自己 (10.0.1.2)
cat > /etc/bind/named.conf.local << 'EOF'
zone "acme.com" {
    type master;
    file "/etc/bind/zones/db.acme.com";
};
EOF

mkdir -p /etc/bind/zones
cat > /etc/bind/zones/db.acme.com << 'EOF'
$TTL    604800
@       IN      SOA     ns1.acme.com. admin.acme.com. (
                              2         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      ns1.acme.com.
ns1     IN      A       10.0.1.2
secure  IN      A       10.0.1.2   ; 我们的核心安全网站
EOF

systemctl restart named
systemctl enable named


echo ">>> 3. Configuring Nginx (Secure Web Server with mTLS)..."
# 配置 Nginx 启用 HTTPS，并要求客户端出示 VM3 签发的证书
cat > /etc/nginx/sites-available/secure_site << 'EOF'
server {
    listen 443 ssl;
    server_name secure.acme.com;

    # 服务器自己的证书
    ssl_certificate /etc/nginx/ssl/vm2-srv.crt;
    ssl_certificate_key /etc/nginx/ssl/vm2-srv.key;

    # 双向认证 (mTLS)：要求验证客户端证书
    ssl_client_certificate /etc/nginx/ssl/ca.crt;
    ssl_verify_client on; # on 表示强制要求，如果没有证书直接拒绝访问！

    location / {
        root /var/www/html/secure;
        index index.html;
    }
}
EOF

# 创建一个测试网页
mkdir -p /var/www/html/secure
echo "<h1>Welcome to ACME Secure Headquarters Data (mTLS Authenticated)</h1>" > /var/www/html/secure/index.html

# 启用站点并重启 Nginx
ln -s /etc/nginx/sites-available/secure_site /etc/nginx/sites-enabled/ || true
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx
systemctl enable nginx

echo ">>> VM2 Provisioning Complete!"