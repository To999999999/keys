#!/usr/bin/env bash
set -euo pipefail

USER_NAME="${SUDO_USER:-$USER}"

sudo apt update
sudo apt install -y gnupg scdaemon pcscd yubikey-manager git

sudo systemctl enable --now pcscd.socket

sudo tee /usr/share/polkit-1/rules.d/03-polkit-pcscd.rules >/dev/null <<EOF
polkit.addRule(function(action, subject) {
    if ((action.id == "org.debian.pcsc-lite.access_pcsc" ||
         action.id == "org.debian.pcsc-lite.access_card") &&
        subject.user == "$USER_NAME") {
        return polkit.Result.YES;
    }
});
EOF

mkdir -p "$HOME/.gnupg"
chmod 700 "$HOME/.gnupg"

cat > "$HOME/.gnupg/scdaemon.conf" <<'EOF'
disable-ccid
pcsc-shared
EOF

chmod 600 "$HOME/.gnupg/scdaemon.conf"

sudo systemctl restart polkit
sudo systemctl restart pcscd.socket

gpgconf --kill gpg-agent || true
gpgconf --kill scdaemon || true

echo "Done. Log out/in over SSH, then test:"
echo "  ykman info"
echo "  gpg --card-status"
