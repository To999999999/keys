#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Utilities
# -----------------------------

have() {
  command -v "$1" >/dev/null 2>&1
}

msg() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf '\nWARNING: %s\n' "$*" >&2
}

err() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

update_gpg_tty_if_available() {
  if tty -s; then
    export GPG_TTY="$(tty)"
    gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true
  fi
}

ask_yes_no() {
  local prompt="$1"
  local answer

  printf '\n%s [y/N]: ' "$prompt" > /dev/tty
  read -r answer < /dev/tty

  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

append_if_missing_exact_line() {
  local line="$1"
  local file="$2"

  touch "$file"

  if grep -Fqx "$line" "$file" 2>/dev/null; then
    msg "$Line already present in $file"
  else
    msg "Adding $line to $file"
    printf '\n%s\n' "$line" >> "$file"
  fi
}

cleanup_dir() {
  local dir="$1"
  if [ -n "${dir:-}" ] && [ -d "$dir" ]; then
    rm -rf "$dir"
  fi
}

restart_gpg_agent() {
  msg "Restarting gpg-agent"

  gpgconf --kill gpg-agent || true
  gpgconf --launch gpg-agent

  export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"

  update_gpg_tty_if_available

  if [ ! -S "$SSH_AUTH_SOCK" ]; then
    err "SSH agent socket was not created: $SSH_AUTH_SOCK"
  fi
}

get_auth_subkey_keygrip() {
  gpg -K --with-keygrip 2>/dev/null | awk '
    /^\s*ssb/ {
      current_is_auth = ($0 ~ /\[A\]/)
      next
    }
    /Keygrip = / {
      if (current_is_auth) {
        sub(/^.*Keygrip = /, "", $0)
        print $0
        exit
      }
    }
  '
}

ensure_sshcontrol_contains_auth_keygrip() {

    AUTH_KEYGRIP="$(get_auth_subkey_keygrip || true)"
    if [ -z "${AUTH_KEYGRIP:-}" ]; then
        err "Could not find an [A] authentication subkey keygrip in your GPG secret keys."
    fi
    
    SSHCONTROL_FILE="${GNUPGHOME_DIR}/sshcontrol"
    touch "$SSHCONTROL_FILE"
    chmod 600 "$SSHCONTROL_FILE"

    if grep -Fqx "$AUTH_KEYGRIP" "$SSHCONTROL_FILE" 2>/dev/null; then
        msg "Auth subkey keygrip already present in $SSHCONTROL_FILE"
    else
        msg "Adding auth subkey keygrip to $SSHCONTROL_FILE"
        printf '%s\n' "$AUTH_KEYGRIP" >> "$SSHCONTROL_FILE"
    fi
}

ensure_ssh_config_block_for_github() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"

    if grep -Eq "^[[:space:]]*Host[[:space:]]+github.com([[:space:]]|$)" "$HOME/.ssh/config"; then
        msg "SSH config already contains a block for github.com"
    else
    
        msg "Appending SSH config block to $HOME/.ssh/config for github"
        
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        touch "$HOME/.ssh/config"
        chmod 600 "$HOME/.ssh/config"

    cat >> "$HOME/.ssh/config" <<EOF

# github.com via GPG agent
Host github.com
  User git
  IdentityAgent $(gpgconf --list-dirs agent-ssh-socket)
EOF

    fi
}

# -----------------------------
# Dependency checks
# -----------------------------

for cmd in \
  gpg \
  gpgconf \
  gpg-connect-agent \
  ssh \
  ssh-add \
  tar \
  awk \
  grep \
  git \
  chmod \
  mkdir \
  mktemp \
  rm \
  cp \
  touch \
  dirname \
  tty
do
  have "$cmd" || err "$cmd is not installed"
done

if ! have curl && ! have wget; then
  err "Need curl or wget"
fi

# -----------------------------
# Config
# -----------------------------

PUBLIC_KEY_URL="https://raw.githubusercontent.com/To999999999/keys/main/public.asc"

BACKUP_ARCHIVE_PATH="$(pwd)/gpg-backup.tar.gz.gpg"

SECRET_KEYS_FILE="secret-keys-backup.asc"
SECRET_SUBKEYS_FILE="secret-subkeys-backup.asc"
OWNERTRUST_FILE="ownertrust.txt"

ZSH_RC_FILE="$HOME/.zshrc"
BASH_RC_FILE="$HOME/.bashrc"

GNUPGHOME_DIR="$(gpgconf --list-dirs homedir)"
mkdir -p "$GNUPGHOME_DIR"
chmod 700 "$GNUPGHOME_DIR"

ssh_enabled=false

# -----------------------------
# Importing the keys (with backup archive or yubikey)
# -----------------------------

TEMP_DIR=""
USED_MODE=""
IMPORTED_SECRET_FILE=""
trap 'cleanup_dir "$TEMP_DIR"' EXIT

if [ -f "$BACKUP_ARCHIVE_PATH" ]; then

  USED_MODE="encrypted local backup import"

  msg "Found encrypted backup archive next to script"

  TEMP_DIR="$(mktemp -d)"

  msg "Decrypting backup archive"
  gpg -d "$BACKUP_ARCHIVE_PATH" > "${TEMP_DIR}/gpg-backup.tar.gz"

  msg "Extracting backup archive"
  tar xzf "${TEMP_DIR}/gpg-backup.tar.gz" -C "$TEMP_DIR"

  if [ -f "${TEMP_DIR}/${SECRET_KEYS_FILE}" ]; then
  
    IMPORTED_SECRET_FILE="${TEMP_DIR}/${SECRET_KEYS_FILE}"
    warn "Found full secret-key backup: ${SECRET_KEYS_FILE}"
    warn "This imports your primary secret key onto this machine."
    
  elif [ -f "${TEMP_DIR}/${SECRET_SUBKEYS_FILE}" ]; then
  
    IMPORTED_SECRET_FILE="${TEMP_DIR}/${SECRET_SUBKEYS_FILE}"
    msg "Found subkeys-only backup: ${SECRET_SUBKEYS_FILE}"
    msg "This imports secret subkeys only; the primary secret key remains absent."
    
  else
    err "Missing both ${SECRET_KEYS_FILE} and ${SECRET_SUBKEYS_FILE} inside backup archive"
  fi

  msg "Importing secret key material"
  gpg --import "$IMPORTED_SECRET_FILE"

  if [ -f "${TEMP_DIR}/${OWNERTRUST_FILE}" ]; then
  
    msg "Importing ownertrust"
    gpg --import-ownertrust "${TEMP_DIR}/${OWNERTRUST_FILE}"
    
  else
    warn "No ${OWNERTRUST_FILE} found in archive; continuing without it"
  fi
else

  USED_MODE="YubiKey + public key import"

  msg "YubiKey mode"

  if [ -n "$PUBLIC_KEY_URL" ]; then
  
    msg "Importing public key from URL"
    
    if have curl; then
      curl -fsSL "$PUBLIC_KEY_URL" | gpg --import
    else
      wget -qO- "$PUBLIC_KEY_URL" | gpg --import
    fi
  else
    err "PUBLIC_KEY_URL is empty"
  fi

  msg "Checking YubiKey / smartcard status"
  if ! gpg --card-status; then
    msg "YubiKey/card not detected by GPG."
    msg "If this is a fresh Debian system, you may need:"
    msg "  sudo apt install -y pcscd scdaemon pcsc-tools"
    msg "  sudo systemctl enable --now pcscd"
    err "Cannot continue without a detected YubiKey/card."
  fi
fi

# Importing secret keys or creating smartcard stubs can change what gpg-agent sees.
restart_gpg_agent

# -----------------------------
# Enable ssh (enable-ssh-support, add persistance to zsh/bash, add ssh config for github)
# -----------------------------

if ask_yes_no "Want to enable ssh with the authentication key? (for GitHub)"; then

    ssh_enabled=true

    GPG_AGENT_CONF="$GNUPGHOME_DIR/gpg-agent.conf"

    append_if_missing_exact_line "enable-ssh-support" "$GPG_AGENT_CONF"
    chmod 600 "$GPG_AGENT_CONF"
    
    append_if_missing_exact_line 'export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"' "$ZSH_RC_FILE"
    append_if_missing_exact_line 'export GPG_TTY="$(tty)"' "$ZSH_RC_FILE"
    append_if_missing_exact_line 'gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1' "$ZSH_RC_FILE"

    append_if_missing_exact_line 'export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"' "$BASH_RC_FILE"
    append_if_missing_exact_line 'export GPG_TTY="$(tty)"' "$BASH_RC_FILE"
    append_if_missing_exact_line 'gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1' "$BASH_RC_FILE"

    ensure_ssh_config_block_for_github

    ensure_sshcontrol_contains_auth_keygrip

    restart_gpg_agent
    
    SSH_ADD_OUTPUT="$(ssh-add -L 2>&1 || true)"
    printf '%s\n' "$SSH_ADD_OUTPUT"

    if grep -Fq "Error connecting to agent" <<<"$SSH_ADD_OUTPUT"; then
        err "ssh-add could not talk to the SSH agent after sshcontrol update"
    elif grep -Fq "The agent has no identities." <<<"$SSH_ADD_OUTPUT"; then
        err "The SSH agent still exposes no identities after updating sshcontrol."
    fi
    msg "Key currently exposed to SSH"

else
    msg "Skipping ssh support"
fi

# -----------------------------
# Git configuration
# -----------------------------

gitconfig_file="$HOME/.gitconfig"
existing_name=""
existing_email=""

if [ -f "$gitconfig_file" ]; then
    existing_name="$(git config --global user.name 2>/dev/null || true)"
    existing_email="$(git config --global user.email 2>/dev/null || true)"
fi

if [[ "$existing_name" == "Adrien" ]] && [[ "$existing_email" == "96784564+To999999999@users.noreply.github.com" ]]; then
    msg ".gitconfig already configured correctly"
else

    printf '\nCurrent git identity:\n'
    printf '  name:  %s\n' "${existing_name:-<unset>}"
    printf '  email: %s\n' "${existing_email:-<unset>}"

    printf '\nDesired git identity:\n'
    printf '  name:  %s\n' "Adrien"
    printf '  email: %s\n' "96784564+To999999999@users.noreply.github.com"

    if ask_yes_no "Update your global Git identity for GitHub commits?"; then
        if [ -f "$gitconfig_file" ]; then
            cp "$gitconfig_file" "$gitconfig_file.bak"
            msg "Backup created: $gitconfig_file.bak"
        fi

        git config --global user.name "Adrien"
        git config --global user.email "96784564+To999999999@users.noreply.github.com"
        msg "Updated global Git identity"
    else
        msg "Skipped Git identity update"
    fi
fi


# -----------------------------
# Final instructions
# -----------------------------

echo "!! TO ACTIVATE EVERYTHING EXIT THIS SESSION AND COME BACK !!"

if $ssh_enabled; then
    echo "To test your GitHub SSH connection :"
    echo "ssh -T github.com"
fi

# -----------------------------
# -----------------------------
