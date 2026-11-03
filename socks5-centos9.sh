#!/usr/bin/env bash
set -Eeuo pipefail

PORT=44445
SSHD_CONFIG=/etc/ssh/sshd_config

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ "$EUID" -eq 0 ]] || die "Jalankan skrip sebagai root."
[[ -r /etc/os-release ]] || die "Tidak bisa membaca versi sistem."

# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == centos && "${VERSION_ID:-}" == 9* ]] \
    || die "Skrip ini ditujukan untuk CentOS 9 / CentOS Stream 9."

clear
echo "Updating system..."

dnf install -y epel-release epel-next-release dnf-plugins-core
/usr/bin/crb enable
dnf install -y dante-server net-tools curl iproute

echo "========================================"
echo "   MASUKKAN USER DAN PASS NYA BRE!!!"
echo "========================================"

[[ -r /dev/tty ]] || die "Jalankan dari terminal interaktif."
exec </dev/tty

read -r -p "Enter username: " user
[[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || die "Username tidak valid."

read -r -s -p "Enter password: " pass
printf '\n'
[[ -n "$pass" ]] || die "Password tidak boleh kosong."
[[ "$pass" != *:* ]] || die "Password tidak boleh mengandung tanda titik dua (:)."

nologin="$(command -v nologin || true)"
[[ -n "$nologin" ]] || die "Program nologin tidak ditemukan."

if getent passwd "$user" >/dev/null; then
    old_shell="$(getent passwd "$user" | cut -d: -f7)"
    [[ "${old_shell##*/}" == nologin ]] \
        || die "Username sudah dipakai akun yang bukan nologin."
else
    useradd -M -s "$nologin" "$user"
fi

printf '%s:%s\n' "$user" "$pass" | chpasswd

# Tambahkan akun ke DenyUsers jika belum ada
if ! awk -v u="$user" '
    $1 == "DenyUsers" {
        for (i = 2; i <= NF; i++) if ($i == u) found = 1
    }
    END { exit !found }
' "$SSHD_CONFIG"; then
    if grep -Eq '^[[:space:]]*DenyUsers[[:space:]]+' "$SSHD_CONFIG"; then
        sed -i -E "/^[[:space:]]*DenyUsers[[:space:]]+/ s/[[:space:]]*$/ $user/" "$SSHD_CONFIG"
    else
        printf '\nDenyUsers %s\n' "$user" >>"$SSHD_CONFIG"
    fi
fi

sshd -t
systemctl restart sshd

iface="$(
    ip -4 route get 1.1.1.1 |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
)"
[[ -n "$iface" ]] || die "Tidak bisa menentukan interface jaringan."

vpsip="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$vpsip" ]] || vpsip="cek IP publik dari panel VPS"

cat >/etc/sockd.conf <<EOF
logoutput: syslog
internal: 0.0.0.0 port = ${PORT}
external: ${iface}
socksmethod: username
user.privileged: root
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}
EOF

sockd -V -f /etc/sockd.conf
systemctl restart sockd

# Izinkan port SOCKS jika firewalld sedang aktif
if command -v firewall-cmd >/dev/null 2>&1 &&
   systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${PORT}/tcp"
    firewall-cmd --reload
fi

echo "   AUTO SOCKS BY DMSRYN 🔥"
echo "========================================"
echo "SOCKS : $vpsip:$PORT:$user:$pass"
echo "========================================"
echo "   GUNAKAN DENGAN BIJAK YA BREEE :)"
