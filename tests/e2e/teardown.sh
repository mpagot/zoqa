#!/usr/bin/env bash
# teardown.sh — Generic openQA container cleanup.
#
# Stops and removes the openQA single-instance container and cleans up
# temporary files created by setup.sh and run.sh.
#
# Usage:
#   bash tests/e2e/teardown.sh [OPTIONS]
#
# OPTIONS:
#   --collect-logs    Dump openQA server-side logs to ./openqa-e2e-logs/ before
#                     stopping the container. Useful for post-mortem debugging.
#   --dryrun          Print commands without executing them.
#   -h, --help        Show this help message and exit.

set -eo pipefail

# -----------------------------------------------------------------------------
# Source shared library
# -----------------------------------------------------------------------------
LOG_PREFIX="teardown"
# shellcheck source=SCRIPTDIR/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd_to_project_root "${BASH_SOURCE[0]}"

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------
# (COLLECT_LOGS defaults to false via lib.sh; --collect-logs sets it to true)

show_help() {
	cat <<'EOF'
# Stops and removes the openQA single-instance container and cleans up
# temporary files created by setup.sh and run.sh.
#
# Usage:
#   bash tests/e2e/teardown.sh [OPTIONS]
#
# OPTIONS:
#   --collect-logs    Dump openQA server-side logs to ./openqa-e2e-logs/ before
#                     stopping the container. Useful for post-mortem debugging.
#   --dryrun          Print commands without executing them.
#   -h, --help        Show this help message and exit.
EOF
}

while [[ "$#" -gt 0 ]]; do
	case $1 in
	-h | --help)
		show_help
		exit 0
		;;
	--dryrun)
		DRY_RUN=true
		shift
		;;
	--collect-logs)
		COLLECT_LOGS=true
		shift
		;;
	*)
		echo "Unknown parameter: $1" >&2
		exit 1
		;;
	esac
done

# (log() is provided by lib.sh; LOG_PREFIX is set to "teardown" above)

# -----------------------------------------------------------------------------
# Log Collection (optional)
# -----------------------------------------------------------------------------
if [[ "$COLLECT_LOGS" == "true" ]]; then
	LOG_DIR="openqa-e2e-logs"
	log "Collecting server-side logs into ./$LOG_DIR/ ..."
	run_cmd "mkdir -p $LOG_DIR"

	if [[ "$DRY_RUN" == "true" ]]; then
		echo "[DRY-RUN] podman exec $CONTAINER_NAME cat /var/log/openqa > $LOG_DIR/openqa.log"
		echo "[DRY-RUN] podman exec $CONTAINER_NAME cat /var/log/apache2/access_log > $LOG_DIR/apache-access.log"
		echo "[DRY-RUN] podman exec $CONTAINER_NAME cat /var/log/apache2/error_log > $LOG_DIR/apache-error.log"
		echo "[DRY-RUN] podman exec $CONTAINER_NAME journalctl --no-pager > $LOG_DIR/journal.log"
		echo "[DRY-RUN] podman exec $CONTAINER_NAME find /var/log -name 'gru*' -o -name 'minion*' | xargs cat >> $LOG_DIR/gru.log"
		echo "[DRY-RUN] podman logs $CONTAINER_NAME > $LOG_DIR/container-stdout-stderr.log"
	else
		container_exec cat /var/log/openqa 2>/dev/null >"$LOG_DIR/openqa.log" || true
		container_exec cat /var/log/apache2/access_log 2>/dev/null >"$LOG_DIR/apache-access.log" || true
		container_exec cat /var/log/apache2/error_log 2>/dev/null >"$LOG_DIR/apache-error.log" || true
		container_exec journalctl --no-pager 2>/dev/null >"$LOG_DIR/journal.log" || true
		# Gru / Minion worker logs — find then cat each file individually
		container_exec bash -c "find /var/log -name 'gru*' -o -name 'minion*' 2>/dev/null | xargs -r cat" \
			>"$LOG_DIR/gru.log" 2>/dev/null || true
		# Container stdout/stderr (podman-side)
		podman logs "$CONTAINER_NAME" >"$LOG_DIR/container-stdout-stderr.log" 2>&1 || true

		log "Logs saved to ./$LOG_DIR/"
		ls -lh "$LOG_DIR/"
	fi
fi

# -----------------------------------------------------------------------------
# Container Stop
# -----------------------------------------------------------------------------
log "Stopping and removing container '$CONTAINER_NAME'..."
run_cmd "podman rm -f $CONTAINER_NAME >/dev/null 2>&1 || true"

# -----------------------------------------------------------------------------
# Temporary File Cleanup
# -----------------------------------------------------------------------------
log "Removing temporary files..."
run_cmd "rm -f tests/e2e/entrypoint-wrapper.sh"
run_cmd "rm -f client.conf.e2e"
run_cmd "rm -f test_output.log"
run_cmd "rm -f /tmp/openqa_e2e_env.sh"

log "Teardown complete."
