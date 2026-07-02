#!/usr/bin/env bash
set -euo pipefail

USER_NAME="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo "~$USER_NAME")"

sudo apt update
sudo apt install -y gnupg scdaemon pcscd yubikey-manager

sudo systemctl enable --now pcscd.socket

if [[ -n "${SSH_CONNECTION:-}" ]]; then
    echo "SSH detected: adding PC/SC Polkit rule for user: $USER_NAME"

    sudo tee /usr/share/polkit-1/rules.d/03-polkit-pcscd.rules >/dev/null <<EOF
polkit.addRule(function(action, subject) {
    if ((action.id == "org.debian.pcsc-lite.access_pcsc" ||
         action.id == "org.debian.pcsc-lite.access_card") &&
        subject.user == "$USER_NAME") {
        return polkit.Result.YES;
    }
});
EOF

    sudo systemctl restart polkit
fi

sudo systemctl restart pcscd.socket

echo "Testing GnuPG YubiKey access..."

if sudo -u "$USER_NAME" gpg --card-status >/dev/null 2>&1; then
    echo "GnuPG works without extra scdaemon config."
else
    echo "GnuPG needs PC/SC mode; creating scdaemon.conf..."

    sudo -u "$USER_NAME" mkdir -p "$USER_HOME/.gnupg"
    chmod 700 "$USER_HOME/.gnupg"

    sudo -u "$USER_NAME" tee "$USER_HOME/.gnupg/scdaemon.conf" >/dev/null <<'EOF'
disable-ccid
pcsc-shared
EOF

    chmod 600 "$USER_HOME/.gnupg/scdaemon.conf"

    sudo -u "$USER_NAME" gpgconf --kill gpg-agent || true
    sudo -u "$USER_NAME" gpgconf --kill scdaemon || true
fi

echo
echo "Done."
echo "!!! If from SSH quit and come back !!!"
echo "!!! Unplug/replug the YubiKey, then run: !!!"
echo "  ykman info"
echo "  gpg --card-status"
