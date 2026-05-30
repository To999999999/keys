#!/usr/bin/env bash
set -euo pipefail

PUBLIC_KEY_URL="${PUBLIC_KEY_URL:-https://raw.githubusercontent.com/To999999999/keys/main/public.asc}"

SSH_HOST="${SSH_HOST:-github.com}"
SSH_USER="${SSH_USER:-git}"

GIT_USER_NAME="${GIT_USER_NAME:-Adrien}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-96784564+To999999999@users.noreply.github.com}"

BACKUP_ARCHIVE_NAME="${BACKUP_ARCHIVE_NAME:-gpg-backup.tar.gz.gpg}"

SECRET_KEYS_FILE="${SECRET_KEYS_FILE:-secret-keys-backup.asc}"
SECRET_SUBKEYS_FILE="${SECRET_SUBKEYS_FILE:-secret-subkeys-backup.asc}"
OWNERTRUST_FILE="${OWNERTRUST_FILE:-ownertrust.txt}"

ZSH_RC_FILE="${ZSH_RC_FILE:-$HOME/.zshrc}"
BASH_RC_FILE="${BASH_RC_FILE:-$HOME/.bashrc}"

SSH_AUTH_SOCK_LINE='export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"'
GPG_TTY_LINE='export GPG_TTY="$(tty)"'
GPG_UPDATE_TTY_LINE='gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1'

have() { command -v "$1" >/dev/null 2>&1; }
msg() { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
err() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

fetch_url() {
  local url="$1"

  if have curl; then
    curl -fsSL "$url"
  elif have wget; then
    wget -qO- "$url"
  else
    err "Need curl or wget"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local answer=""

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
    msg "Line already present in $file"
  else
    msg "Adding line to $file"
    printf '\n%s\n' "$line" >> "$file"
  fi
}

restart_gpg_agent() {
  msg "Restarting gpg-agent"

  gpgconf --kill gpg-agent || true
  gpgconf --launch gpg-agent

  export SSH_AUTH_SOCK
  SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"

  export GPG_TTY
  GPG_TTY="$(tty)"

  gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true

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

ensure_gitconfig() {
  local gitconfig_file="$HOME/.gitconfig"
  local existing_name=""
  local existing_email=""

  existing_name="$(git config --global user.name 2>/dev/null || true)"
  existing_email="$(git config --global user.email 2>/dev/null || true)"

  if [[ "$existing_name" == "$GIT_USER_NAME" ]] && [[ "$existing_email" == "$GIT_USER_EMAIL" ]]; then
    msg ".gitconfig already configured correctly"
    return
  fi

  printf '\nCurrent git identity:\n'
  printf '  name:  %s\n' "${existing_name:-<unset>}"
  printf '  email: %s\n' "${existing_email:-<unset>}"

  printf '\nDesired git identity:\n'
  printf '  name:  %s\n' "$GIT_USER_NAME"
  printf '  email: %s\n' "$GIT_USER_EMAIL"

  if ask_yes_no "Update your global Git identity for GitHub commits?"; then
    if [ -f "$gitconfig_file" ]; then
      cp "$gitconfig_file" "$gitconfig_file.bak"
      msg "Backup created: $gitconfig_file.bak"
    fi

    git config --global user.name "$GIT_USER_NAME"
    git config --global user.email "$GIT_USER_EMAIL"

    msg "Updated global Git identity"
  else
    warn "Skipped Git identity update"
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

  if grep -Eq "^[[:space:]]*Host[[:space:]]+${host}([[:space:]]|$)" "$file"; then
    msg "SSH config already contains a block for ${host}"
    return
  fi

  if ask_yes_no "Add an SSH config block for GitHub using your GPG agent?"; then
    msg "Appending SSH config block to $file"
    printf '%s\n' "$block" >> "$file"
  else
    warn "Skipped SSH config modification"
  fi
}

smartcard_error() {
  warn "YubiKey/card not detected by GPG."
  warn "On Debian/Ubuntu, you may need:"
  warn "  sudo apt install -y pcscd scdaemon pcsc-tools"
  warn "  sudo systemctl enable --now pcscd"
  warn "If using a VM, also check USB passthrough."
  exit 1
}

cleanup_dir() {
  local dir="$1"

  if [ -n "${dir:-}" ] && [ -d "$dir" ]; then
    rm -rf "$dir"
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
# Paths
# -----------------------------

if [ -n "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR="$(pwd)"
fi

BACKUP_ARCHIVE_PATH="${SCRIPT_DIR}/${BACKUP_ARCHIVE_NAME}"

GNUPGHOME_DIR="$(gpgconf --list-dirs homedir)"
mkdir -p "$GNUPGHOME_DIR"
chmod 700 "$GNUPGHOME_DIR"

msg "Using GNUPGHOME: $GNUPGHOME_DIR"

# -----------------------------
# gpg-agent config
# -----------------------------

GPG_AGENT_CONF="$GNUPGHOME_DIR/gpg-agent.conf"
touch "$GPG_AGENT_CONF"
chmod 600 "$GPG_AGENT_CONF"

if ! grep -Fxq 'enable-ssh-support' "$GPG_AGENT_CONF" 2>/dev/null; then
  msg "Enabling SSH support in gpg-agent"
  printf '\nenable-ssh-support\n' >> "$GPG_AGENT_CONF"
else
  msg "gpg-agent SSH support already enabled"
fi

restart_gpg_agent

# -----------------------------
# Persist shell startup config
# -----------------------------

append_if_missing_exact_line "$SSH_AUTH_SOCK_LINE" "$ZSH_RC_FILE"
append_if_missing_exact_line "$SSH_AUTH_SOCK_LINE" "$BASH_RC_FILE"

append_if_missing_exact_line "$GPG_TTY_LINE" "$ZSH_RC_FILE"
append_if_missing_exact_line "$GPG_TTY_LINE" "$BASH_RC_FILE"

append_if_missing_exact_line "$GPG_UPDATE_TTY_LINE" "$ZSH_RC_FILE"
append_if_missing_exact_line "$GPG_UPDATE_TTY_LINE" "$BASH_RC_FILE"

# -----------------------------
# Mode selection
# -----------------------------

TEMP_DIR=""
USED_MODE=""
IMPORTED_SECRET_FILE="none"
trap 'cleanup_dir "$TEMP_DIR"' EXIT

if [ -f "$BACKUP_ARCHIVE_PATH" ]; then
  USED_MODE="encrypted local backup import"

  msg "Found encrypted backup archive: $BACKUP_ARCHIVE_PATH"

  TEMP_DIR="$(mktemp -d)"
  DECRYPTED_TAR="${TEMP_DIR}/gpg-backup.tar.gz"

  msg "Decrypting backup archive"
  gpg -d "$BACKUP_ARCHIVE_PATH" > "$DECRYPTED_TAR"

  msg "Extracting backup archive"
  tar xzf "$DECRYPTED_TAR" -C "$TEMP_DIR"

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

  msg "No local encrypted backup archive found"
  msg "Falling back to YubiKey mode"

  [ -n "$PUBLIC_KEY_URL" ] || err "PUBLIC_KEY_URL is empty"

  msg "Importing public key from URL"
  fetch_url "$PUBLIC_KEY_URL" | gpg --import

  msg "Checking YubiKey / smartcard status"
  gpg --card-status || smartcard_error
fi

# -----------------------------
# SSH identity exposure
# -----------------------------

export GPG_TTY
GPG_TTY="$(tty)"
gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true

msg "Keys currently exposed to SSH"
SSH_ADD_OUTPUT="$(ssh-add -L 2>&1 || true)"
printf '%s\n' "$SSH_ADD_OUTPUT"

if grep -Fq "Error connecting to agent" <<<"$SSH_ADD_OUTPUT"; then
  err "ssh-add could not talk to the SSH agent"
fi

if grep -Fq "The agent has no identities." <<<"$SSH_ADD_OUTPUT"; then
  warn "The SSH agent is running, but exposes no identities."
  warn "Trying to expose the [A] authentication subkey through sshcontrol."

  AUTH_KEYGRIP="$(get_auth_subkey_keygrip || true)"

  [ -n "${AUTH_KEYGRIP:-}" ] || err "Could not find an [A] authentication subkey keygrip"

  SSHCONTROL_FILE="${GNUPGHOME_DIR}/sshcontrol"
  ensure_sshcontrol_contains_auth_keygrip "$SSHCONTROL_FILE" "$AUTH_KEYGRIP"

  restart_gpg_agent

  msg "Keys currently exposed to SSH after sshcontrol update"
  SSH_ADD_OUTPUT="$(ssh-add -L 2>&1 || true)"
  printf '%s\n' "$SSH_ADD_OUTPUT"

  if grep -Fq "Error connecting to agent" <<<"$SSH_ADD_OUTPUT"; then
    err "ssh-add could not talk to the SSH agent after sshcontrol update"
  fi

  if grep -Fq "The agent has no identities." <<<"$SSH_ADD_OUTPUT"; then
    err "The SSH agent still exposes no identities after updating sshcontrol"
  fi
fi

# -----------------------------
# Git + SSH config
# -----------------------------

ensure_gitconfig

SSH_CONFIG_FILE="$HOME/.ssh/config"
ensure_ssh_config_block "$SSH_CONFIG_FILE" "$SSH_HOST" "$SSH_USER" "$SSH_AUTH_SOCK"

# -----------------------------
# Final output
# -----------------------------

cat <<EOF

Done.

Mode used:
  ${USED_MODE}

Secret material imported:
  ${IMPORTED_SECRET_FILE}

For this shell session:
  SSH_AUTH_SOCK=${SSH_AUTH_SOCK}
  GPG_TTY=${GPG_TTY}

Shell startup files checked:
  ${ZSH_RC_FILE}
  ${BASH_RC_FILE}

SSH config file checked:
  ${SSH_CONFIG_FILE}

Git identity configured as:
  ${GIT_USER_NAME}
  ${GIT_USER_EMAIL}

Test your GitHub SSH connection with:
  ssh -T git@github.com

EOF
