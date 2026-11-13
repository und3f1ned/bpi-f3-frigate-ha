#!/usr/bin/env bash
# Full update: build the latest versions (only what changed) and restart the stack.
#   ./update.sh            # build + docker compose up -d in deploy/
#   ./update.sh --no-restart
# Suitable for running on a schedule (see README: systemd timer).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
RESTART=1; [ "${1:-}" = "--no-restart" ] && RESTART=0

mkdir -p logs
exec > >(tee -a "logs/update-$(date +%Y%m%d).log") 2>&1
echo "=== $(date '+%F %T') update"
./build.sh all
if [ "$RESTART" = 1 ]; then
  (cd deploy && docker compose up -d --remove-orphans)
  docker compose -f deploy/compose.yaml ps --format '{{.Name}}\t{{.Image}}\t{{.Status}}'
fi
docker image prune -f >/dev/null
echo "=== $(date '+%F %T') done"
