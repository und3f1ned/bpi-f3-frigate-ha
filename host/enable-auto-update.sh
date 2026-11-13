#!/usr/bin/env bash
# Scheduled stack auto-update: a systemd timer runs update.sh (builds newly released
# Home Assistant / Frigate versions and restarts the stack; does nothing if nothing is new). Idempotent.
#
#   sudo ./host/enable-auto-update.sh                  # Sundays at 03:00
#   sudo ./host/enable-auto-update.sh "Sat 04:30"      # custom schedule (OnCalendar format)
#   sudo ./host/enable-auto-update.sh --disable        # turn it off
#
# Next run: systemctl list-timers k1-update.timer
# Logs: journalctl -u k1-update.service, plus logs/update-DATE.log in the stack directory.
# Run it right now: sudo systemctl start --no-block k1-update.service
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
STACK=$(dirname "$(dirname "$(readlink -f "$0")")")
USER_NAME=${SUDO_USER:-$(stat -c %U "$STACK")}

if [ "${1:-}" = --disable ]; then
  systemctl disable --now k1-update.timer
  echo "auto-update disabled"; exit 0
fi
WHEN=${1:-"Sun 03:00"}
systemd-analyze calendar "$WHEN" >/dev/null || { echo "invalid schedule: '$WHEN'" >&2; exit 1; }
id -nG "$USER_NAME" | grep -qw docker \
  || { echo "$USER_NAME is not in the docker group (see host/setup-host.sh)" >&2; exit 1; }

cat > /etc/systemd/system/k1-update.service <<EOF
[Unit]
Description=bpi-f3-frigate-ha: build new releases and restart the stack
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
User=$USER_NAME
ExecStart=$STACK/update.sh
# building a new Frigate or HA version from scratch takes hours
TimeoutStartSec=infinity
EOF

cat > /etc/systemd/system/k1-update.timer <<EOF
[Unit]
Description=bpi-f3-frigate-ha: auto-update ($WHEN)

[Timer]
OnCalendar=$WHEN
# if a run was missed because the board was off, run it after power-on
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now k1-update.timer >/dev/null
echo "auto-update enabled: $WHEN (user $USER_NAME, $STACK/update.sh)"
systemctl list-timers k1-update.timer --no-pager
