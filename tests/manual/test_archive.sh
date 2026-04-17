#!/bin/bash
# tests/manual/test_archive.sh — Manual archive download tests comparing
# zoqa, openqa-cli, and curl against a real production openQA server.
#
# See lib.sh for environment variable overrides and default configuration.

set -eo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

BIG_FILE_REL="hdd/publiccloud_tools_0103.qcow2"
SMALL_FILE_REL="testresults/ulogs/test_cluster-hana0-hdb_hdblcm_install.tar.gz"

BIG_URL="$HOST/tests/$JOB_ID/asset/hdd/publiccloud_tools_0103.qcow2"
SMALL_URL="$HOST/tests/$JOB_ID/file/test_cluster-hana0-hdb_hdblcm_install.tar.gz"

TEMP_DIR="$PWD/test_archive_dir"

cleanup() {
	rm -rf "$TEMP_DIR"
	rm -f /tmp/mojo.tmp.*
}
trap cleanup EXIT

# =============================================================================
# Preflight
# =============================================================================

echo "=== Preflight ==="
echo ""
require_zoqa
detect_gnu_time
echo ""

# =============================================================================
# Helpers
# =============================================================================

check_space() {
	local avail
	avail=$(df -k . | awk 'NR==2 {print $4}')
	if [ "$avail" -lt 3600000 ]; then # Need around 3.5 GB
		echo "WARNING: Less than 3.5GB available in $PWD ($avail KB). Proceeding anyway, but downloads might fail."
	fi
}

run_test() {
	local tool=$1

	echo "=========================================================="
	echo "Tool: $tool"
	echo "=========================================================="

	rm -rf "$TEMP_DIR"
	rm -f /tmp/mojo.tmp.*
	mkdir -p "$TEMP_DIR"
	check_space

	if [ "$tool" == "curl" ]; then
		echo "Downloading BIG file..."
		_maybe_timev bash -c "curl -s -L '$BIG_URL' -o '$TEMP_DIR/$BIG_FILE_REL' --create-dirs && curl -s -L '$SMALL_URL' -o '$TEMP_DIR/$SMALL_FILE_REL' --create-dirs"
	elif [ "$tool" == "zoqa" ]; then
		echo "Running zoqa archive..."
		_maybe_timev "$ZOQA" archive --host "$HOST" -l 10737418240 "$JOB_ID" "$TEMP_DIR"
	elif [ "$tool" == "openqa-cli" ]; then
		echo "Running openqa-cli archive..."
		MOJO_TMPDIR="$TEMP_DIR" _maybe_timev openqa-cli archive --host "$HOST" -l 10737418240 "$JOB_ID" "$TEMP_DIR"
	fi

	echo ""
	echo "--- Checksums ---"

	if [ -f "$TEMP_DIR/$BIG_FILE_REL" ]; then
		echo "BIG FILE MD5: $(md5sum "$TEMP_DIR/$BIG_FILE_REL" | awk '{print $1}')"
	else
		echo "BIG FILE MD5: Not found!"
	fi

	if [ -f "$TEMP_DIR/$SMALL_FILE_REL" ]; then
		echo "SMALL FILE MD5: $(md5sum "$TEMP_DIR/$SMALL_FILE_REL" | awk '{print $1}')"
	else
		echo "SMALL FILE MD5: Not found!"
	fi

	# Clean up immediately to free space for the next test
	rm -rf "$TEMP_DIR"
	echo ""
}

# =============================================================================
# Run
# =============================================================================

echo "Starting tests..."
for tool in zoqa openqa-cli curl; do
	run_test "$tool"
done
echo "All tests completed."
