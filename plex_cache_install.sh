#!/usr/bin/env bash
set -e

############## CONFIG #####################
PLEX_USER="plex"          # Plex user (usually 'plex')
LINUX_USER="thor"         # Your login user with NVMe home folder

# HDD storage
HDD_MOVIES="/mnt/media/Movies"
HDD_TV="/mnt/media/TV"

# NVMe cache directories
NVME_BASE="/home/thor/cache"
NVME_MOVIES="$NVME_BASE/Movies"
NVME_TV="$NVME_BASE/TV"

# OverlayFS work + mount directories
WORK_BASE="/home/thor/overlay_work"
WORK_MOVIES="$WORK_BASE/Movies"
WORK_TV="$WORK_BASE/TV"

OVERLAY_BASE="/home/thor/overlay"
OVERLAY_MOVIES="$OVERLAY_BASE/Movies"
OVERLAY_TV="$OVERLAY_BASE/TV"

# System paths
DAEMON_SCRIPT="/usr/local/bin/plex_cache_daemon.sh"
SERVICE_FILE="/etc/systemd/system/plex_cache.service"
LOGFILE="/var/log/plex_cache.log"
###########################################


echo "========== PLEX NVME CACHE INSTALLER =========="
sleep 1

echo "[1/8] Creating directories..."
mkdir -p "$NVME_MOVIES" "$NVME_TV"
mkdir -p "$WORK_MOVIES" "$WORK_TV"
mkdir -p "$OVERLAY_MOVIES" "$OVERLAY_TV"
touch "$LOGFILE"

echo "[2/8] Setting permissions..."
chown -R "$LINUX_USER":"$LINUX_USER" /home/"$LINUX_USER"/cache
chown -R "$LINUX_USER":"$LINUX_USER" /home/"$LINUX_USER"/overlay_work
chown -R "$LINUX_USER":"$LINUX_USER" /home/"$LINUX_USER"/overlay

chown "$LINUX_USER":"$LINUX_USER" "$LOGFILE"


#############################################
# FSTAB FIX-IT-UP
#############################################

echo "[3/8] Adding OverlayFS mounts to /etc/fstab..."

# Remove existing entries if rerunning
sed -i "\|$OVERLAY_MOVIES|d" /etc/fstab
sed -i "\|$OVERLAY_TV|d" /etc/fstab

cat <<EOF >> /etc/fstab
overlay $OVERLAY_MOVIES overlay lowerdir=$HDD_MOVIES,upperdir=$NVME_MOVIES,workdir=$WORK_MOVIES 0 0
overlay $OVERLAY_TV overlay lowerdir=$HDD_TV,upperdir=$NVME_TV,workdir=$WORK_TV 0 0
EOF

echo "[4/8] Mounting overlay filesystem..."
mount -a

#############################################
# INSTALL CACHING DAEMON
#############################################

echo "[5/8] Installing caching daemon to $DAEMON_SCRIPT..."

cat <<'EOF' > "$DAEMON_SCRIPT"
#!/usr/bin/env bash

### CONFIG ###
HDD_MOVIES="/mnt/media/Movies"
HDD_TV="/mnt/media/TV"

NVME_MOVIES="/home/thor/cache/Movies"
NVME_TV="/home/thor/cache/TV"

LOG="/var/log/plex_cache.log"
CACHE_MAX_MINUTES=180   # 3 hours
##############################################

mkdir -p "$NVME_MOVIES" "$NVME_TV"
touch "$LOG"

echo "### Plex NVMe Cache Daemon Started: $(date) ###" >> "$LOG"

##############################################
# Cleanup: remove NVMe files older than 3 hours. Get that gabage outta herrrr
##############################################
cleanup_cache() {
    echo "[CLEANUP] Removing NVMe cache files older than ${CACHE_MAX_MINUTES} minutes" >> "$LOG"
    find "$NVME_MOVIES" "$NVME_TV" -type f -mmin +$CACHE_MAX_MINUTES -print -delete >> "$LOG" 2>&1
}

# Run cleanup every hour in the background
(
    while true; do
        sleep 3600
        cleanup_cache
    done
) &

##############################################
# Cache file function
##############################################
cache_file() {
    SRC="$1"
    BASENAME=$(basename "$SRC")

    if [[ "$SRC" == "$HDD_MOVIES"* ]]; then
        REL="${SRC#$HDD_MOVIES/}"
        TARGET="$NVME_MOVIES/$REL"
    elif [[ "$SRC" == "$HDD_TV"* ]]; then
        REL="${SRC#$HDD_TV/}"
        TARGET="$NVME_TV/$REL"
    else
        echo "[SKIP] $SRC not in a watched library" >> "$LOG"
        return
    fi

    mkdir -p "$(dirname "$TARGET")"

    if [[ -f "$TARGET" ]]; then
        echo "[CACHE] Already cached: $TARGET" >> "$LOG"
        return
    fi

    echo "[CACHE] rsync → NVMe: $SRC → $TARGET" >> "$LOG"
    rsync -ah --info=progress2 "$SRC" "$TARGET" >> "$LOG" 2>&1
}

##############################################
# Main inotify loop: Still playing?
##############################################
echo "[INFO] Watching for Plex file access..." >> "$LOG"

inotifywait -m -r -e open --format '%w%f' \
    "$HDD_MOVIES" "$HDD_TV" | while read FILE; do

    case "$FILE" in
        *.mp4|*.mkv|*.avi|*.mov|*.m4v|*.flac|*.mp3)
            echo "[EVENT] Plex accessed: $FILE" >> "$LOG"
            cache_file "$FILE"
            ;;
        *)
            ;;
    esac
done
EOF

chmod +x "$DAEMON_SCRIPT"


#############################################
# SYSTEMD SERVICE
#############################################

echo "[6/8] Installing systemd service..."

cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Plex NVMe Cache Daemon
After=network.target plexmediaserver.service

[Service]
ExecStart=$DAEMON_SCRIPT
Restart=always
User=$LINUX_USER
Group=$LINUX_USER

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable plex_cache.service
systemctl start plex_cache.service

#############################################
# FINAL MESSAGE
#############################################

echo "---------------------------------------------------"
echo "[7/8] Installation complete!"
echo
echo "YOUR PLEX LIBRARY PATHS MUST NOW BE SET TO:"
echo "  Movies → $OVERLAY_MOVIES"
echo "  TV     → $OVERLAY_TV"
echo
echo "OverlayFS ensures:"
echo "  - NVMe copy overrides HDD automatically"
echo "  - HDD used only as fallback"
echo "  - No symlinks required"
echo
echo "[8/8] Done. NVMe caching is live."
echo "---------------------------------------------------"

exit 0


####POC, use at your own risk. :: by:buf0rd
