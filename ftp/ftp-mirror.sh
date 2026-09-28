#!/bin/sh
# Download a folder from an FTP/FTPS server, or upload one to it, in a
# background container that survives closing SSH.
#
# Reuse: copy this file per transfer (e.g. ftp-mirror-myrun.sh), edit the
# settings block, then:
#   sh ftp-mirror-myrun.sh          start (or resume) the transfer
#   sh ftp-mirror-myrun.sh status   running / finished / failed
#   sh ftp-mirror-myrun.sh logs     follow progress (Ctrl+C to stop watching)
#
# The password lives only in this file. It reaches lftp through an
# environment variable set inside the container, so it never appears in the
# command line, `ps`, or `docker inspect`. Keep the file chmod 700.

# ---------------------------------------------------------------- settings
DIRECTION="download" # download: server -> LOCAL_DIR; upload: LOCAL_DIR -> server
FTP_HOST="ftp.example.org"
FTP_PORT="21"
FTP_USER="your-username"
FTP_PASS="your-password"
REMOTE_DIR="/path/on/server"          # folder on the server
LOCAL_DIR="/SSD/${USER}/project_raw"      # folder on this machine
PARALLEL=4                                # files transferred at once
EXTRA_MOUNT=""   # uploads of symlinked output: a folder to mount read-only at
                 # the SAME path inside the container, so link targets resolve.
                 # Nextflow links point into work/, outside LOCAL_DIR; without
                 # this the links are dangling in the container and lftp tries
                 # SITE SYMLINK instead of sending files. Usually the run root,
                 # e.g. /SSD/$USER/myproject
FOLLOW_SYMLINKS=yes # uploads: send what links point at. Nextflow publishDir
                    # writes symlinks into work/, and FTP servers reject
                    # SITE SYMLINK, so without this an upload sends nothing.
ENCRYPT=yes      # yes: require TLS (most sequencing cores); no: plain FTP
VERIFY_CERT=no   # no: accept self-signed certs / servers reached by IP
JOB_NAME="ftpdl" # container name; use a different one per concurrent job
DOCKER="docker1" # "docker1" on Cornell BioHPC, "docker" everywhere else
# -------------------------------------------------------------------------

set -eu

case "$DIRECTION" in
  download|upload) ;;
  *) echo "DIRECTION must be download or upload, not '$DIRECTION'." >&2; exit 1 ;;
esac

# Inside the container: install lftp and run the mirror against $2.
if [ "${1:-}" = "--inner" ]; then
  DATA="${2:-/data}"
  apk add --no-cache lftp >/dev/null
  export LFTP_PASSWORD="$FTP_PASS"
  tls=""
  if [ "$ENCRYPT" = yes ]; then
    tls="set ftp:ssl-force true; set ftp:ssl-protect-data true;"
  fi
  # -R reverses the mirror: local -> server. No --delete in either
  # direction, so a transfer never removes files on the other side.
  # if/then, not `[ ] && x`: under `set -e` a false test ends the script.
  deref=""
  if [ "${FOLLOW_SYMLINKS:-yes}" = yes ]; then
    deref="--dereference"
  fi
  if [ "$DIRECTION" = upload ]; then
    # --no-perms: many FTP servers reject SITE CHMOD/MFF, and lftp's attempt
    # to copy local permissions onto each uploaded file then fails it.
    transfer="mirror -R -c $deref --no-perms --parallel=$PARALLEL --verbose '$DATA' '$REMOTE_DIR'"
  else
    transfer="mirror -c --parallel=$PARALLEL --verbose '$REMOTE_DIR' '$DATA'"
  fi
  # --env-password with an explicit -u user: lftp otherwise falls back to an
  # anonymous login, and it never encrypts anonymous logins.
  exec lftp -c "$tls set ssl:verify-certificate $VERIFY_CERT; \
    open --env-password -u '$FTP_USER' ftp://$FTP_HOST:$FTP_PORT; \
    $transfer"
fi

SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

if [ "$DIRECTION" = upload ]; then
  verb=uploading; arrow="$LOCAL_DIR -> $FTP_HOST:$REMOTE_DIR"
else
  verb=downloading; arrow="$FTP_HOST:$REMOTE_DIR -> $LOCAL_DIR"
fi

# No anchors: docker1 may prefix container names with the user ID.
state() {
  "$DOCKER" ps -a --filter "name=${JOB_NAME}" --format '{{.Status}}' 2>/dev/null | head -1
}

case "${1:-start}" in
  status)
    s=$(state)
    case "$s" in
      "")            echo "$JOB_NAME: no job found" ;;
      Up*)           echo "$JOB_NAME: $verb ($s)" ;;
      "Exited (0)"*) echo "$JOB_NAME: finished OK ($s)" ;;
      *)             echo "$JOB_NAME: FAILED ($s) — run: sh $0 logs" ;;
    esac
    echo "local folder: $(du -sh "$LOCAL_DIR" 2>/dev/null | cut -f1) in $(ls "$LOCAL_DIR" 2>/dev/null | wc -l) items"
    ;;
  logs)
    # docker1 prefixes container names with the user id, so look the real
    # name up rather than assuming JOB_NAME.
    real=$("$DOCKER" ps -a --filter "name=${JOB_NAME}" --format '{{.Names}}' 2>/dev/null | head -1)
    exec "$DOCKER" logs -f --tail 30 "${real:-$JOB_NAME}"
    ;;
  start)
    if [ "$FTP_USER" = "your-username" ] || [ "$FTP_PASS" = "your-password" ]; then
      echo "Edit FTP_USER and FTP_PASS at the top of $0 first." >&2
      exit 1
    fi
    case "$(state)" in
      Up*) echo "$JOB_NAME is already running — sh $0 status" >&2; exit 1 ;;
    esac

    if [ "$DIRECTION" = upload ]; then
      if [ ! -d "$LOCAL_DIR" ] || [ -z "$(ls -A "$LOCAL_DIR" 2>/dev/null)" ]; then
        echo "Nothing to upload: $LOCAL_DIR is missing or empty." >&2
        exit 1
      fi
      data_mode=ro   # uploads only read the local folder
    else
      mkdir -p "$LOCAL_DIR"
      data_mode=rw
    fi

    # Best effort: it holds a password, but a filesystem that refuses
    # chmod (NFS, a mounted share) must not abort the transfer.
    chmod 700 "$SELF" 2>/dev/null || true
    # docker1 renames containers (user__biohpc_JOBNAME), so remove the real
    # one — otherwise the stale container lingers and the new run can't start.
    old=$("$DOCKER" ps -a --filter "name=${JOB_NAME}" --format '{{.Names}}' 2>/dev/null | head -1)
    [ -n "$old" ] && "$DOCKER" rm -f "$old" >/dev/null 2>&1
    "$DOCKER" rm "$JOB_NAME" >/dev/null 2>&1 || true

    # Mount the local folder and this script explicitly. docker1 only
    # permits mounts from folders its site allows (documented: /workdir/$USER
    # and /local/storage) and rejects anything else, so on refusal say where.
    # With EXTRA_MOUNT, mount it at its own path and point lftp at LOCAL_DIR
    # there, so absolute symlink targets inside it resolve.
    if [ -n "$EXTRA_MOUNT" ]; then
      set -- -v "$EXTRA_MOUNT":"$EXTRA_MOUNT":ro -v "$SELF":/job.sh:ro
      inner_data=$LOCAL_DIR
    else
      set -- -v "$LOCAL_DIR":/data:$data_mode -v "$SELF":/job.sh:ro
      inner_data=/data
    fi

    if ! "$DOCKER" run -d --name "$JOB_NAME" "$@" \
        alpine sh /job.sh --inner "$inner_data" >/dev/null; then
      echo "$DOCKER refused to start the container (see its message above)." >&2
      if [ "$DOCKER" = docker1 ]; then
        echo "docker1 only mounts folders it allows. Put both this script and" >&2
        echo "LOCAL_DIR under an allowed location, such as /workdir/\$USER." >&2
      fi
      exit 1
    fi

    echo "started $JOB_NAME ($DIRECTION): $arrow"
    echo "check with: sh $0 status   |   sh $0 logs"
    ;;
  *)
    echo "usage: sh $0 [start|status|logs]" >&2
    exit 1
    ;;
esac
