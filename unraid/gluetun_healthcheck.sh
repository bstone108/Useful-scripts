#!/bin/bash

echo "[$(date)] 🔍 Checking containers directly linked to GluetunVPN..."

TEST_URL="https://1.1.1.1"
TEST_HOST="1.1.1.1"
TEST_PORT="443"
TIMEOUT=5

GLUETUN_NAME="GluetunVPN"
GLUETUN_ID=$(docker inspect -f '{{.Id}}' "$GLUETUN_NAME" 2>/dev/null)

if [ -z "$GLUETUN_ID" ]; then
    echo "❌ Failed to get ID of $GLUETUN_NAME. Is it running?"
    exit 1
fi

# --- Detect Unraid "Appdata Backup" plugin activity -----------------------------------------
# We avoid interfering with backups by NOT starting/restarting containers while a backup runs.
is_appdatabackup_running() {
    # 1) Any process mentioning the plugin path/name
    if ps auxww | grep -Eqi '/usr/local/emhttp/plugins/appdata\.backup|appdata\.backup|ca\.backup2'; then
        # Filter out the grep itself; if anything else matches, it's running.
        if ps auxww | grep -Ei '/usr/local/emhttp/plugins/appdata\.backup|appdata\.backup|ca\.backup2' | grep -vq 'grep'; then
            return 0
        fi
    fi

    # 2) Any tar/rsync currently writing to "Appdata Backup/ab_..." (common output naming)
    if ps auxww | grep -Eqi 'tar .*Appdata Backup/ab_|rsync .*Appdata Backup/ab_'; then
        if ps auxww | grep -Ei 'tar .*Appdata Backup/ab_|rsync .*Appdata Backup/ab_' | grep -vq 'grep'; then
            return 0
        fi
    fi

    return 1
}

if is_appdatabackup_running; then
    echo "🧰 Appdata Backup appears to be running. Skipping ALL start/restart actions to avoid interference."
    echo "[$(date)] ✅ Check complete (no changes made due to backup activity)."
    exit 0
fi
# -------------------------------------------------------------------------------------------

echo "➡️ Checking for stopped containers that should use $GLUETUN_NAME network..."
for container in $(docker ps -a --format '{{.Names}}'); do
    RUNNING=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)
    NET_MODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$container" 2>/dev/null)

    if [ "$RUNNING" = "false" ] && [[ "$NET_MODE" == "container:$GLUETUN_ID" ]]; then
        echo "⚠️ Starting stopped container: $container"
        docker start "$container" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "✅ Started $container"
        else
            echo "❌ Failed to start $container"
        fi
        echo
    fi
done

# Helper: test network inside a container with multiple fallbacks
container_net_ok() {
    local c="$1"

    # curl
    docker exec "$c" sh -lc "command -v curl >/dev/null 2>&1 && curl -s --head --max-time $TIMEOUT '$TEST_URL' >/dev/null 2>&1"
    [ $? -eq 0 ] && return 0

    # wget
    docker exec "$c" sh -lc "command -v wget >/dev/null 2>&1 && wget -q --spider --timeout=$TIMEOUT '$TEST_URL' >/dev/null 2>&1"
    [ $? -eq 0 ] && return 0

    # busybox wget (common in minimal images)
    docker exec "$c" sh -lc "command -v busybox >/dev/null 2>&1 && busybox wget -q --spider -T $TIMEOUT '$TEST_URL' >/dev/null 2>&1"
    [ $? -eq 0 ] && return 0

    # /dev/tcp (bash feature; may not exist, but cheap to try)
    docker exec "$c" sh -lc "command -v bash >/dev/null 2>&1 && bash -lc 'echo >/dev/tcp/$TEST_HOST/$TEST_PORT' >/dev/null 2>&1"
    [ $? -eq 0 ] && return 0

    return 1
}

for container in $(docker ps --format '{{.Names}}'); do
    NET_MODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$container" 2>/dev/null)

    if [[ "$NET_MODE" == "container:$GLUETUN_ID" ]]; then
        echo "➡️  Checking: $container (linked to $GLUETUN_NAME)"

        if container_net_ok "$container"; then
            echo "✅ $container is good"
        else
            echo "⚠️  Network failure in $container — restarting..."
            docker restart "$container" > /dev/null
            [ $? -eq 0 ] && echo "✅ Restarted $container" || echo "❌ Restart failed!"
        fi
        echo
    fi
done

echo "[$(date)] ✅ Check complete."
