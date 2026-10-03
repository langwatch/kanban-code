#!/bin/bash
# After the owner-only secrets are sealed (Settings > Vault > Owner Keys), copies
# of the vault from before the seal still hold those values under the machine
# key: backup folders next to the vault, and the box's restic snapshots, which
# carry vault.age together with identity.txt.
#
#   Scripts/vault-owner-cleanup.sh [user@box]                    report only, changes nothing
#   Scripts/vault-owner-cleanup.sh [user@box] --delete-backups   remove the pre-seal backup folders on the Mac and the box
#   Scripts/vault-owner-cleanup.sh [user@box] --restic           keep identity.txt and the backup folders out of the box's
#                                                                restic backup, and out of its existing snapshots
#
# The two changing modes ask for a typed "yes" at a terminal and refuse to run
# without one. Run from a Mac terminal, not from an agent session.
set -uo pipefail

BOX="root@100.114.220.85"
MODE=report
for arg in "$@"; do
  case "$arg" in
    --delete-backups) MODE=delete ;;
    --restic) MODE=restic ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) BOX="$arg" ;;
  esac
done

REPO=$(cd "$(dirname "$0")/.." && pwd)
MAC_VAULT="$HOME/.kanban-code/vault"
BOX_VAULT=/root/.kanban-code/vault
BOX_BACKUP_SCRIPT=/opt/rchaves-platform/backup/backup.sh
KV=${KV:-$HOME/.local/bin/kv}

mac_copies() {
  ls -d "$MAC_VAULT"/backup-* "$REPO"/.claude/tmp/vault3/backup "$REPO"/.claude/tmp/vault-enclave/backup-* 2>/dev/null
}

box() { ssh -o ConnectTimeout=10 "$BOX" "$@"; }

box_copies() { box "ls -d $BOX_VAULT/backup-* 2>/dev/null"; }

confirm() {
  if [ ! -t 0 ]; then echo "This needs a terminal: run it yourself." >&2; exit 2; fi
  printf '%s\nType yes to go on: ' "$1"
  read -r answer
  [ "$answer" = "yes" ] || { echo "Nothing changed."; exit 1; }
}

sealed_everywhere() {
  local mac box_status
  mac=$("$KV" owner --json 2>/dev/null) || return 1
  box_status=$(box '~/.local/bin/kv owner --json' 2>/dev/null) || return 1
  python3 - "$mac" "$box_status" <<'EOF'
import json, sys
for name, raw in zip(("Mac", "box"), sys.argv[1:]):
    s = json.loads(raw)
    print(f"{name}: {'sealing' if s['active'] else 'NOT sealing'}, {s['sealed']} sealed, {s['plain']} still plain")
    if not s["active"] or s["plain"] > 0 or s["sealed"] == 0:
        sys.exit(1)
EOF
}

echo "Owner keys:"
if sealed_everywhere; then SEALED=1; else SEALED=0; echo "The owner-only secrets are not sealed on both machines yet."; fi

echo
echo "Vault copies from before the seal, on this Mac:"
mac_copies | sed 's/^/  /'
echo "On $BOX:"
box_copies | sed 's/^/  /'

echo
echo "restic on $BOX:"
box "grep -q 'kanban-code/vault/identity.txt' $BOX_BACKUP_SCRIPT && echo '  identity.txt is excluded from new backups' || echo '  identity.txt is in every backup, next to vault.age'
set -a; . /opt/rchaves-platform/.env; set +a
restic snapshots --compact 2>/dev/null | tail -n +3 | grep -c '^[0-9a-f]\{8\}' | sed 's/^/  snapshots: /'
restic version | sed 's/^/  /'"

case "$MODE" in
  report)
    echo
    echo "Nothing was changed. Until the old copies are gone, the values those secrets had before the seal"
    echo "can still be read with the machine key. Changing a secret's value (kv set) also ends that for it."
    ;;

  delete)
    [ "$SEALED" = 1 ] || { echo "Refusing: seal first."; exit 1; }
    confirm "This removes the folders listed above on this Mac and on $BOX. The recovery key must be in 1Password."
    mac_copies | while read -r dir; do /bin/rm -r "$dir" && echo "removed $dir"; done
    box "for d in $BOX_VAULT/backup-*; do [ -d \"\$d\" ] && command rm -r \"\$d\" && echo \"removed \$d\"; done"
    ;;

  restic)
    [ "$SEALED" = 1 ] || { echo "Refusing: seal first."; exit 1; }
    confirm "This edits $BOX_BACKUP_SCRIPT on $BOX to leave identity.txt and the vault backup folders out of
new backups, and removes them from the existing snapshots when the box's restic can rewrite (0.15 or newer).
The Mac keychain then holds the only other copy of the machine key."
    box "python3 - $BOX_BACKUP_SCRIPT $BOX_VAULT" <<'EOF' || exit 1
import sys
path, vault = sys.argv[1], sys.argv[2]
text = open(path).read()
if "kanban-code/vault/identity.txt" not in text:
    head = "restic backup --one-file-system --exclude-caches \\\n"
    if head not in text:
        sys.exit("could not find the restic backup line; add the two --exclude lines by hand")
    extra = f"  --exclude '{vault}/identity.txt' \\\n  --exclude '{vault}/backup-*' \\\n"
    open(path, "w").write(text.replace(head, head + extra, 1))
print("\n".join(l for l in open(path).read().splitlines() if "kanban-code/vault" in l))
EOF
    box "set -a; . /opt/rchaves-platform/.env; set +a
if restic rewrite --help >/dev/null 2>&1; then
  restic rewrite --forget --exclude '$BOX_VAULT/identity.txt' --exclude '$BOX_VAULT/backup-*' && restic prune
else
  echo 'This restic has no rewrite command (it came with 0.15). The existing snapshots keep identity.txt until they age out'
  echo '(7 daily, 4 weekly, 6 monthly), or until restic is upgraded and this is run again.'
fi"
    echo "Make the same two --exclude lines part of backup/backup.sh in the rchaves-platform repository."
    ;;
esac
