#!/usr/bin/env bash
set -Eeuo pipefail

PORT=44445
CONF=/etc/sockd.conf
SSH_DROPIN=/etc/ssh/sshd_config.d/90-socks-proxy.conf

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ "$EUID" -eq 0 ]] || die "Jalankan sebagai root: sudo bash centos9-socks5.sh"
[[ -r /etc/os-release ]] || die "Tidak bisa membaca versi sistem."

# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == centos && "${VERSION_ID:-}" == 9* ]] \
    || die "Skrip ini untuk CentOS 9 / CentOS Stream 9."

echo "Memasang repository dan paket Dante..."
dnf install -y epel-release epel-next-release dnf-plugins-core
dnf config-manager --set-enabled crb
dnf makecache --refresh
dnf install -y dante-server curl iproute

[[ -r /dev/tty ]] || die "Jalankan dari terminal interaktif."
exec </dev/tty

read -r -p "Username SOCKS: " user
[[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || die "Username tidak valid. Gunakan huruf kecil, angka, _ atau -."

nologin="$(command -v nologin || true)"
[[ -n "$nologin" ]] || die "Program nologin tidak ditemukan."

if getent passwd "$user" >/dev/null; then
    shell_lama="$(getent passwd "$user" | cut -d: -f7)"
    [[ "${shell_lama##*/}" == nologin ]] \
        || die "Akun '$user' sudah ada dan bukan akun proxy nologin."
    echo "Akun nologin '$user' ditemukan; password-nya akan diperbarui."
else
    useradd -M -s "$nologin" "$user"
fi

read -r -s -p "Password baru (minimal 12 karakter): " pass
printf '\n'
read -r -s -p "Ulangi password: " pass2
printf '\n'

[[ "$pass" == "$pass2" ]] || die "Password tidak cocok."
(( ${#pass} >= 12 )) || die "Password harus minimal 12 karakter."
[[ "$pass" != *:* ]] || die "Password tidak boleh mengandung tanda titik dua (:)."

printf '%s:%s\n' "$user" "$pass" | chpasswd
unset pass pass2

iface="$(
    ip -4 route get 1.1.1.1 |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
)"
[[ -n "$iface" ]] || die "Tidak bisa menentukan interface jaringan."

if [[ -e "$CONF" ]]; then
    backup="${CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$CONF" "$backup"
    echo "Konfigurasi lama dicadangkan ke $backup"
fi

tmp_conf="$(mktemp /etc/sockd.conf.XXXXXX)"
trap 'rm -f "$tmp_conf"' EXIT

cat >"$tmp_conf" <<EOF
logoutput: syslog
internal: 0.0.0.0 port = ${PORT}
external: ${iface}

clientmethod: none
socksmethod: username

user.privileged: root
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect
    socksmethod: username
    log: connect disconnect error
}
EOF

echo "Memeriksa konfigurasi Dante..."
sockd -V -f "$tmp_conf"
install -o root -g root -m 0644 "$tmp_conf" "$CONF"

echo "Membatasi akun proxy dari login SSH..."
install -d -m 0755 /etc/ssh/sshd_config.d
touch "$SSH_DROPIN"
chmod 600 "$SSH_DROPIN"

grep -Fqx "DenyUsers $user" "$SSH_DROPIN" \
    || printf 'DenyUsers %s\n' "$user" >>"$SSH_DROPIN"

sshd -t
sshd -T 2>/dev/null |
    awk -v u="$user" '$1 == "denyusers" { for (i = 2; i <= NF; i++) if ($i == u) found = 1 } END { exit !found }' \
    || die "sshd tidak membaca aturan DenyUsers."

if systemctl is-active --quiet sshd.service; then
    systemctl reload sshd.service
fi

systemctl enable --now sockd.service

if systemctl is-active --quiet firewalld.service; then
    firewall-cmd --permanent --add-port="${PORT}/tcp"
    firewall-cmd --reload
else
    echo "firewalld tidak aktif. Pastikan TCP port ${PORT} dibuka di firewall panel VPS."
fi

vpsip="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"

printf '\n========================================\n'
printf ' SOCKS5 siap\n'
printf 'IP publik : %s\n' "${vpsip:-cek IP di panel VPS}"
printf 'Port      : %s\n' "$PORT"
printf 'Username  : %s\n' "$user"
printf 'Password  : gunakan password yang tadi dimasukkan\n'
printf '========================================\n'
