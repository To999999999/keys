#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config
# -----------------------------

# Public key URL used in YubiKey mode
PUBLIC_KEY_URL="${PUBLIC_KEY_URL:-https://raw.githubusercontent.com/To999999999/keys/main/public.asc}"

# SSH target
SSH_HOST="${SSH_HOST:-github.com}"
SSH_USER="${SSH_USER:-git}"

# Backup archive expected next to this script
BACKUP_ARCHIVE_NAME="${BACKUP_ARCHIVE_NAME:-gpg-backup.tar.gz.gpg}"

# Files expected inside the decrypted archive
SECRET_KEYS_FILE="${SECRET_KEYS_FILE:-private-keys-backup.asc}"
OWNERTRUST_FILE="${OWNERTRUST_FILE:-ownertrust.txt}"

# Shell rc files to update
ZSH_RC_FILE="${ZSH_RC_FILE:-$HOME/.zshrc}"
BASH_RC_FILE="${BASH_RC_FILE:-$HOME/.bashrc}"

# Lines to persist in shell startup
SSH_AUTH_SOCK_LINE='export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"'
GPG_TTY_LINE='export GPG_TTY="$(tty)"'

# -----------------------------
# Helpers
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

append_if_missing_exact_line() {
  local line="$1"
  local file="$2"

  touch "$file"

  if grep -Fqx "$line" "$file" 2>/dev/null; then
    msg "Line already present in $file"
  else
    msg "Adding line to $file"
    printf '\n%s\n' "$line" >> "$file"
  fi
}

choose_ssh_config_file() {
  if [ -d "$HOME/.config/ssh" ] || [ -f "$HOME/.config/ssh/config" ]; then
    printf '%s\n' "$HOME/.config/ssh/config"
  elif [ -d "$HOME/.ssh" ] || [ -f "$HOME/.ssh/config" ]; then
    printf '%s\n' "$HOME/.ssh/config"
  else
    printf '%s\n' "$HOME/.ssh/config"
  fi
}

ensure_ssh_config_block() {
  local file="$1"
  local host="$2"
  local user="$3"
  local socket="$4"

  local block
  block=$(cat <<EOF

# ${host} via GPG agent
Host ${host}
  User ${user}
  IdentityAgent ${socket}
EOF
)

  mkdir -p "$(dirname "$file")"
  chmod 700 "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file"

  if grep -Eq "^[[:space:]]*Host[[:space:]]+${host}([[:space:]]|\$)" "$file"; then
    msg "SSH config already has a block for ${host}; not modifying"
  else
    msg "Appending SSH config block to $file"
    printf '%s\n' "$block" >> "$file"
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
  gpg-connect-agent /bye >/dev/null

  SSH_SOCKET="$(gpgconf --list-dirs agent-ssh-socket)"
  export SSH_AUTH_SOCK="$SSH_SOCKET"

  if [ ! -S "$SSH_AUTH_SOCK" ]; then
    err "SSH agent socket was not created: $SSH_AUTH_SOCK"
  fi

  msg "SSH_AUTH_SOCK set to: $SSH_AUTH_SOCK"
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
  local sshcontrol_file="$1"
  local auth_keygrip="$2"

  touch "$sshcontrol_file"
  chmod 600 "$sshcontrol_file"

  if grep -Fqx "$auth_keygrip" "$sshcontrol_file" 2>/dev/null; then
    msg "Auth subkey keygrip already present in $sshcontrol_file"
  else
    msg "Adding auth subkey keygrip to $sshcontrol_file"
    printf '%s\n' "$auth_keygrip" >> "$sshcontrol_file"
  fi
}

# -----------------------------
# Dependency checks
# -----------------------------

have gpg || err "gpg is not installed"
have gpgconf || err "gpgconf is not installed"
have gpg-connect-agent || err "gpg-connect-agent is not installed"
have ssh-add || err "ssh-add is not installed"
have tar || err "tar is not installed"
have awk || err "awk is not installed"

if ! have curl && ! have wget; then
  err "Need curl or wget"
fi

# -----------------------------
# Paths
# -----------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ARCHIVE_PATH="${SCRIPT_DIR}/${BACKUP_ARCHIVE_NAME}"

GNUPGHOME_DIR="$(gpgconf --list-dirs homedir)"
mkdir -p "$GNUPGHOME_DIR"
chmod 700 "$GNUPGHOME_DIR"

msg "Using GNUPGHOME: $GNUPGHOME_DIR"

# -----------------------------
# Enable ssh support in gpg-agent
# -----------------------------

GPG_AGENT_CONF="$GNUPGHOME_DIR/gpg-agent.conf"
touch "$GPG_AGENT_CONF"
chmod 600 "$GPG_AGENT_CONF"

if ! grep -Fxq 'enable-ssh-support' "$GPG_AGENT_CONF" 2>/dev/null; then
  msg "Enabling ssh support in gpg-agent"
  printf '\nenable-ssh-support\n' >> "$GPG_AGENT_CONF"
else
  msg "gpg-agent ssh support already enabled"
fi

restart_gpg_agent

# -----------------------------
# Persist shell startup config
# -----------------------------

append_if_missing_exact_line "$SSH_AUTH_SOCK_LINE" "$ZSH_RC_FILE"
append_if_missing_exact_line "$SSH_AUTH_SOCK_LINE" "$BASH_RC_FILE"
append_if_missing_exact_line "$GPG_TTY_LINE" "$ZSH_RC_FILE"
append_if_missing_exact_line "$GPG_TTY_LINE" "$BASH_RC_FILE"

# -----------------------------
# Mode selection:
#   1) local encrypted backup archive
#   2) YubiKey + public key import
# -----------------------------

TEMP_DIR=""
USED_MODE=""
trap 'cleanup_dir "$TEMP_DIR"' EXIT

if [ -f "$BACKUP_ARCHIVE_PATH" ]; then
  USED_MODE="encrypted local backup import"

  msg "Found encrypted backup archive next to script"
  warn "This mode imports your secret keys onto this machine."

  TEMP_DIR="$(mktemp -d)"
  DECRYPTED_TAR="${TEMP_DIR}/gpg-backup.tar.gz"

  msg "Decrypting backup archive"
  gpg -d "$BACKUP_ARCHIVE_PATH" > "$DECRYPTED_TAR"

  msg "Extracting backup archive"
  tar xzf "$DECRYPTED_TAR" -C "$TEMP_DIR"

  if [ ! -f "${TEMP_DIR}/${SECRET_KEYS_FILE}" ]; then
    err "Missing ${SECRET_KEYS_FILE} inside backup archive"
  fi

  msg "Importing secret keys"
  gpg --import "${TEMP_DIR}/${SECRET_KEYS_FILE}"

  if [ -f "${TEMP_DIR}/${OWNERTRUST_FILE}" ]; then
    msg "Importing ownertrust"
    gpg --import-ownertrust "${TEMP_DIR}/${OWNERTRUST_FILE}"
  else
    warn "No ${OWNERTRUST_FILE} found in archive; continuing without it"
  fi
else
  USED_MODE="YubiKey + public key import"

  msg "No local encrypted backup archive found"
  msg "Falling back to YubiKey mode"

  if [ -n "$PUBLIC_KEY_URL" ]; then
    if have curl; then
      msg "Importing public key from URL"
      curl -fsSL "$PUBLIC_KEY_URL" | gpg --import
    else
      msg "Importing public key from URL"
      wget -qO- "$PUBLIC_KEY_URL" | gpg --import
    fi
  else
    err "PUBLIC_KEY_URL is empty"
  fi

  msg "Checking YubiKey / smartcard status"
  gpg --card-status || err "YubiKey/card not detected by GPG"
fi

# -----------------------------
# Check SSH identities exposed by agent
# If none, try adding the [A] subkey keygrip to sshcontrol
# -----------------------------

msg "Keys currently exposed to SSH"
SSH_ADD_OUTPUT="$(ssh-add -L 2>&1 || true)"
printf '%s\n' "$SSH_ADD_OUTPUT"

if grep -Fq "Error connecting to agent" <<<"$SSH_ADD_OUTPUT"; then
  err "ssh-add could not talk to the SSH agent"
elif grep -Fq "The agent has no identities." <<<"$SSH_ADD_OUTPUT"; then
  warn "The SSH agent is running, but it currently exposes no identities."
  warn "Trying to expose the [A] authentication subkey through sshcontrol."

  AUTH_KEYGRIP="$(get_auth_subkey_keygrip || true)"

  if [ -z "${AUTH_KEYGRIP:-}" ]; then
    err "Could not find an [A] authentication subkey keygrip in your GPG secret keys."
  fi

  SSHCONTROL_FILE="${GNUPGHOME_DIR}/sshcontrol"
  ensure_sshcontrol_contains_auth_keygrip "$SSHCONTROL_FILE" "$AUTH_KEYGRIP"

  restart_gpg_agent

  msg "Keys currently exposed to SSH after sshcontrol update"
  SSH_ADD_OUTPUT="$(ssh-add -L 2>&1 || true)"
  printf '%s\n' "$SSH_ADD_OUTPUT"

  if grep -Fq "Error connecting to agent" <<<"$SSH_ADD_OUTPUT"; then
    err "ssh-add could not talk to the SSH agent after sshcontrol update"
  elif grep -Fq "The agent has no identities." <<<"$SSH_ADD_OUTPUT"; then
    err "The SSH agent still exposes no identities after updating sshcontrol."
  fi
fi

# -----------------------------
# Add SSH config block
# -----------------------------

SSH_CONFIG_FILE="$(choose_ssh_config_file)"
ensure_ssh_config_block "$SSH_CONFIG_FILE" "$SSH_HOST" "$SSH_USER" "$SSH_SOCKET"

# -----------------------------
# Final instructions
# -----------------------------

cat <<EOF

Done.

Mode used:
  ${USED_MODE}

For this shell session, SSH is configured to use:
  SSH_AUTH_SOCK=${SSH_AUTH_SOCK}

Shell startup files checked:
  ${ZSH_RC_FILE}
  ${BASH_RC_FILE}

SSH config file checked:
  ${SSH_CONFIG_FILE}

Try:
  ssh -T ${SSH_USER}@${SSH_HOST}

Reload your shell config with one of:
  source "${ZSH_RC_FILE}"
  source "${BASH_RC_FILE}"

EOF
