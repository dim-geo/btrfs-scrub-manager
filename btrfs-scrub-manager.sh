#!/usr/bin/env bash
#
# btrfs-scrub-manager.sh
#
# Automated, trend-aware Btrfs scrub management script.
#
# Features:
# - Mountpoint specification and validation
# - Configurable cycle period in seconds (default: 2629744s = (365d 5h 48m 45s)/12)
# - Interrupted scrub detection and automatic resumption
# - Finished scrub interval tracking (avoids redundant scrubs within period)
# - Trend-Aware Adaptive Rate Regulation:
#     * Target completion is cutoff time = period / 2
#     * Calculates past average velocity across cycle: V_past = bytes_scrubbed / elapsed
#     * If trend is lagging (e.g. server downtime or heavy load), boosts limit to catch up
#     * If trend is ahead of schedule, throttles limit down to spare I/O (minimum: 100 B/s)
#     * After cutoff time, throughput limit is removed (0 = unlimited)
#     * Re-evaluates and updates scrub limit every 6 seconds
#

set -euo pipefail
export LC_ALL=C

# ---------------------------------------------------------
# Default Constants & Settings
# ---------------------------------------------------------
# Default period: (365 solar days + 5h + 48m + 45s) / 12
# 365*86400 + 5*3600 + 48*60 + 45 = 31,556,925s; 31556925 / 12 = 2,629,743.75s -> 2,629,744s
DEFAULT_PERIOD=2629744
MIN_LIMIT=100            # Minimum throughput limit in bytes/second
POLL_INTERVAL="${POLL_INTERVAL:-6}" # Polling interval in seconds (aligns with btrfs 5s update)

PERIOD="$DEFAULT_PERIOD"
MOUNTPOINT=""
VERBOSE=0
DRY_RUN=0

# ---------------------------------------------------------
# Helpers & Output Formatting
# ---------------------------------------------------------
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

log_debug() {
    if [[ "$VERBOSE" -eq 1 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*"
    fi
}

format_bytes() {
    local bytes="$1"
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "$bytes"
        return
    fi

    if (( bytes >= 1099511627776 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f TiB", b / 1099511627776 }'
    elif (( bytes >= 1073741824 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f GiB", b / 1073741824 }'
    elif (( bytes >= 1048576 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f MiB", b / 1048576 }'
    elif (( bytes >= 1024 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f KiB", b / 1024 }'
    else
        echo "${bytes} B"
    fi
}

format_duration() {
    local total_sec="$1"
    if ! [[ "$total_sec" =~ ^-?[0-9]+$ ]]; then
        echo "$total_sec"
        return
    fi

    if (( total_sec < 0 )); then
        echo "0s"
        return
    fi

    local d=$(( total_sec / 86400 ))
    local h=$(( (total_sec % 86400) / 3600 ))
    local m=$(( (total_sec % 3600) / 60 ))
    local s=$(( total_sec % 60 ))

    if (( d > 0 )); then
        printf "%dd %02dh %02dm %02ds\n" "$d" "$h" "$m" "$s"
    elif (( h > 0 )); then
        printf "%dh %02dm %02ds\n" "$h" "$m" "$s"
    elif (( m > 0 )); then
        printf "%dm %02ds\n" "$m" "$s"
    else
        printf "%ds\n" "$s"
    fi
}

parse_duration_to_seconds() {
    local dur_str="$1"
    # Format typically H:MM:SS or D:HH:MM:SS or MM:SS
    IFS=':' read -r -a parts <<< "$dur_str"
    local count="${#parts[@]}"
    local sec=0
    if [[ "$count" -eq 3 ]]; then
        local h="${parts[0]}"
        local m="${parts[1]}"
        local s="${parts[2]}"
        sec=$(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
    elif [[ "$count" -eq 2 ]]; then
        local m="${parts[0]}"
        local s="${parts[1]}"
        sec=$(( 10#$m * 60 + 10#$s ))
    elif [[ "$count" -eq 4 ]]; then
        local d="${parts[0]}"
        local h="${parts[1]}"
        local m="${parts[2]}"
        local s="${parts[3]}"
        sec=$(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
    elif [[ "$dur_str" =~ ^[0-9]+$ ]]; then
        sec="$dur_str"
    fi
    echo "$sec"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <MOUNTPOINT>

Automated, trend-aware Btrfs scrub manager with dynamic rate regulation.

Arguments:
    MOUNTPOINT                Path to mounted Btrfs filesystem (e.g. / or /home)

Options:
    -p, --period SECONDS      Scrub cycle period in seconds.
                              Default: ${DEFAULT_PERIOD}s (=(365d 5h 48m 45s)/12, ~30.44 days)
    -m, --mountpoint PATH     Alternative way to specify mountpoint
    -v, --verbose             Enable detailed diagnostics per cycle tick
    -n, --dry-run             Show what commands would run without executing them
    -h, --help                Display this help message and exit

Behavior:
    1. Checks if an active scrub is running -> terminates immediately without hijacking.
    2. Checks if an interrupted/aborted scrub exists -> resumes it.
    3. Checks if previous scrub finished:
       Calculates current cycle = current_epoch / period.
       Cycle starts at cycle * period; next cycle starts at (cycle + 1) * period.
       If previous scrub finished in current cycle, exits until next cycle.
       If not, starts a new scrub cycle.
    4. Target cutoff point is cycle * period + (period / 2).
    5. Actively monitors and calculates past speed trend (bytes scrubbed / elapsed cycle time).
       Assumes scrub started on time for the current cycle (at cycle * period).
    6. If trend is lagging behind (e.g. server was off or heavy disk load), boosts scrub limit.
    7. If trend is ahead of schedule, throttles limit down to spare I/O (minimum limit: ${MIN_LIMIT} B/s).
    8. After cutoff time (elapsed >= period / 2), removes rate limit (unlimited).
    9. Updates scrub rate limit every ${POLL_INTERVAL} seconds until completion.
EOF
}

# ---------------------------------------------------------
# Argument Parsing
# ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--period)
            if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -le 0 ]]; then
                log_error "Option '$1' requires a positive integer representing seconds."
                exit 1
            fi
            PERIOD="$2"
            shift 2
            ;;
        -m|--mountpoint)
            if [[ -z "${2:-}" ]]; then
                log_error "Option '$1' requires a valid mountpoint path."
                exit 1
            fi
            MOUNTPOINT="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [[ -z "$MOUNTPOINT" ]]; then
                MOUNTPOINT="$1"
                shift
            else
                log_error "Unexpected argument: $1"
                usage
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$MOUNTPOINT" ]]; then
    log_error "Mountpoint argument is required."
    usage
    exit 1
fi

# Canonicalize path
if [[ -d "$MOUNTPOINT" ]]; then
    MOUNTPOINT="$(cd "$MOUNTPOINT" && pwd -P)"
else
    log_error "Mountpoint directory does not exist: $MOUNTPOINT"
    exit 1
fi

# ---------------------------------------------------------
# Verification & Permissions
# ---------------------------------------------------------
if [[ "$DRY_RUN" -eq 0 && "$EUID" -ne 0 ]]; then
    log_error "This script requires root privileges to execute and regulate Btrfs scrub. Run with sudo or as root."
    exit 1
fi

# Check if mountpoint is a Btrfs filesystem
FS_TYPE="$(findmnt -n -o FSTYPE "$MOUNTPOINT" 2>/dev/null || true)"
if [[ "$FS_TYPE" != "btrfs" ]]; then
    log_error "Target mountpoint '$MOUNTPOINT' is not a Btrfs filesystem (detected: '${FS_TYPE:-none}')."
    exit 1
fi

# ---------------------------------------------------------
# Scrub Commands Wrapper (supports Dry-Run)
# ---------------------------------------------------------
btrfs_cmd() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] btrfs $*"
        return 0
    else
        btrfs "$@"
    fi
}

get_scrub_status_raw() {
    # Output raw status
    btrfs scrub status --raw "$MOUNTPOINT" 2>/dev/null || true
}

apply_scrub_limit() {
    local limit_val="$1"
    # Ensure limit_val is an integer
    limit_val="${limit_val%.*}"
    if [[ "$limit_val" -lt 0 ]]; then
        limit_val=0
    fi

    if [[ "$limit_val" -eq 0 ]]; then
        log_debug "Applying scrub limit: unlimited (0 B/s) to $MOUNTPOINT"
    else
        log_debug "Applying scrub limit: ${limit_val} B/s ($(format_bytes "$limit_val")/s) to $MOUNTPOINT"
    fi

    btrfs_cmd scrub limit -a -l "$limit_val" "$MOUNTPOINT" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------
# Parsing & Displaying Scrub Status
# ---------------------------------------------------------
parse_status_field() {
    local raw_output="$1"
    local field_name="$2"
    echo "$raw_output" | sed -nE "s/^[[:space:]]*${field_name}:[[:space:]]*(.*)/\1/p" | head -n 1
}

print_scrub_status() {
    local header="${1:-Current Scrub Status:}"
    log_info "----------------------------------------------------------"
    log_info "$header"
    local status_out
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] btrfs scrub status $MOUNTPOINT"
        status_out="$(get_scrub_status_raw)"
    else
        status_out="$(btrfs scrub status "$MOUNTPOINT" 2>&1 || true)"
    fi
    if [[ -n "$status_out" ]]; then
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                log_info "  $line"
            fi
        done <<< "$status_out"
    else
        log_info "  (No status information available)"
    fi
    log_info "----------------------------------------------------------"
}

# ---------------------------------------------------------
# Signal Handling
# ---------------------------------------------------------
cleanup_on_signal() {
    local sig="${1:-SIGTERM}"
    echo ""
    log_warn "Received termination signal ($sig). Stopping and canceling active scrub..."
    if [[ -n "$MOUNTPOINT" ]]; then
        btrfs_cmd scrub cancel "$MOUNTPOINT" 2>/dev/null || true
        log_info "Active scrub on '$MOUNTPOINT' canceled. Progress is preserved in status file for later resumption."
        print_scrub_status "Scrub Status at Interruption:"
    fi
    if [[ "$sig" == "SIGINT" ]]; then
        exit 130
    else
        exit 143
    fi
}
trap 'cleanup_on_signal SIGINT' SIGINT
trap 'cleanup_on_signal SIGTERM' SIGTERM
trap 'cleanup_on_signal SIGHUP' SIGHUP

# ---------------------------------------------------------
# Main Scrub Logic
# ---------------------------------------------------------
CUTOFF_DURATION=$(( PERIOD / 2 ))
NOW="${MOCK_TIME:-$(date +%s)}"
CURRENT_CYCLE=$(( NOW / PERIOD ))
CYCLE_START_TIME=$(( CURRENT_CYCLE * PERIOD ))
NEXT_CYCLE_START=$(( (CURRENT_CYCLE + 1) * PERIOD ))
CUTOFF_TIME=$(( CYCLE_START_TIME + CUTOFF_DURATION ))

log_info "Btrfs Scrub Manager initiated for '$MOUNTPOINT'"
log_info "Cycle Period: ${PERIOD}s ($(format_duration "$PERIOD")), Target Cutoff: ${CUTOFF_DURATION}s ($(format_duration "$CUTOFF_DURATION"))"
log_info "Current Cycle: #$CURRENT_CYCLE (started: $(date -d "@$CYCLE_START_TIME" '+%Y-%m-%d %H:%M:%S'), cutoff: $(date -d "@$CUTOFF_TIME" '+%Y-%m-%d %H:%M:%S'), next cycle: $(date -d "@$NEXT_CYCLE_START" '+%Y-%m-%d %H:%M:%S'))"

RAW_STATUS="$(get_scrub_status_raw)"
STATUS_STR="$(parse_status_field "$RAW_STATUS" "Status")"
STATUS_STR="$(echo "$STATUS_STR" | tr '[:upper:]' '[:lower:]')"

log_info "Current scrub status for '$MOUNTPOINT': '${STATUS_STR:-no stats available}'"

case "$STATUS_STR" in
    "running")
        STARTED_DATE_STR="$(parse_status_field "$RAW_STATUS" "Scrub started")"
        DUR_STR="$(parse_status_field "$RAW_STATUS" "Duration")"
        if [[ -n "$STARTED_DATE_STR" ]]; then
            log_info "Scrub already running for '$MOUNTPOINT' (started: $STARTED_DATE_STR, duration: ${DUR_STR:-unknown}). Exiting."
        else
            log_info "Scrub already running for '$MOUNTPOINT'. Exiting."
        fi
        exit 0
        ;;

    "interrupted"|"aborted")
        log_info "Detected $STATUS_STR scrub. Resuming scrub for cycle #$CURRENT_CYCLE..."
        print_scrub_status "Interrupted Scrub Status (prior to resumption):"

        # Compute initial limit before resuming (assuming scrub started on time at CYCLE_START_TIME)
        ELAPSED_SO_FAR=$(( NOW - CYCLE_START_TIME ))
        if (( ELAPSED_SO_FAR >= CUTOFF_DURATION )); then
            INIT_LIMIT=0
        else
            REMAIN_TIME=$(( CUTOFF_DURATION - ELAPSED_SO_FAR ))
            TOT_BYTES="$(parse_status_field "$RAW_STATUS" "Total to scrub" | awk '{print $1}')"
            DONE_BYTES="$(parse_status_field "$RAW_STATUS" "Bytes scrubbed" | awk '{print $1}')"
            if [[ "$TOT_BYTES" =~ ^[0-9]+$ && "$DONE_BYTES" =~ ^[0-9]+$ && "$TOT_BYTES" -gt "$DONE_BYTES" && "$REMAIN_TIME" -gt 0 ]]; then
                REMAIN_BYTES=$(( TOT_BYTES - DONE_BYTES ))
                INIT_LIMIT=$(( REMAIN_BYTES / REMAIN_TIME ))
                if (( INIT_LIMIT < MIN_LIMIT )); then
                    INIT_LIMIT="$MIN_LIMIT"
                fi
            else
                INIT_LIMIT="$MIN_LIMIT"
            fi
        fi

        apply_scrub_limit "$INIT_LIMIT"
        btrfs_cmd scrub resume -c3 "$MOUNTPOINT"
        ;;

    "finished")
        STARTED_DATE_STR="$(parse_status_field "$RAW_STATUS" "Scrub started")"
        DUR_STR="$(parse_status_field "$RAW_STATUS" "Duration")"
        FINISH_EPOCH=0

        if [[ -n "$STARTED_DATE_STR" ]]; then
            STARTED_EPOCH="$(date -d "$STARTED_DATE_STR" +%s 2>/dev/null || echo 0)"
            DUR_SEC="$(parse_duration_to_seconds "$DUR_STR")"
            FINISH_EPOCH=$(( STARTED_EPOCH + DUR_SEC ))
        fi

        if [[ "$FINISH_EPOCH" -le 0 ]]; then
            # Fallback: check /var/lib/btrfs/ status file mtime
            FS_UUID="$(parse_status_field "$RAW_STATUS" "UUID")"
            if [[ -n "$FS_UUID" && -f "/var/lib/btrfs/scrub.status.${FS_UUID}" ]]; then
                FINISH_EPOCH="$(stat -c %Y "/var/lib/btrfs/scrub.status.${FS_UUID}" 2>/dev/null || echo 0)"
            fi
        fi

        if [[ "$FINISH_EPOCH" -gt 0 ]]; then
            FINISHED_CYCLE=$(( FINISH_EPOCH / PERIOD ))
            FINISH_DATE_READABLE="$(date -d "@$FINISH_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "epoch $FINISH_EPOCH")"
            log_info "Previous scrub finished on: $FINISH_DATE_READABLE (cycle #$FINISHED_CYCLE)"

            if (( FINISHED_CYCLE >= CURRENT_CYCLE )); then
                TIME_UNTIL_NEXT=$(( NEXT_CYCLE_START - NOW ))
                if (( TIME_UNTIL_NEXT < 0 )); then
                    TIME_UNTIL_NEXT=0
                fi
                log_info "Scrub was already completed for current cycle #$CURRENT_CYCLE."
                log_info "Next scrub is not due yet (due at $(date -d "@$NEXT_CYCLE_START" '+%Y-%m-%d %H:%M:%S'), in $(format_duration "$TIME_UNTIL_NEXT"))."
                log_info "Exiting without starting a new scrub."
                exit 0
            else
                log_info "Current cycle #$CURRENT_CYCLE has not been scrubbed (last completed in cycle #$FINISHED_CYCLE). Starting new scrubbing cycle."
            fi
        else
            log_info "Unable to determine previous scrub finish time. Starting new scrubbing cycle for cycle #$CURRENT_CYCLE."
        fi

        # Start new scrub
        apply_scrub_limit "$MIN_LIMIT"
        btrfs_cmd scrub start -c3 "$MOUNTPOINT"
        ;;

    *)
        # "no stats available" or unscrubbed
        log_info "No previous scrub recorded. Starting initial scrub cycle for cycle #$CURRENT_CYCLE."
        apply_scrub_limit "$MIN_LIMIT"
        btrfs_cmd scrub start -c3 "$MOUNTPOINT"
        ;;
esac

# ---------------------------------------------------------
# Trend-Aware Adaptive Monitoring Loop
# ---------------------------------------------------------
log_info "Entering trend-aware dynamic regulation loop (polling every ${POLL_INTERVAL}s)..."

LAST_LIMIT=-1
LAST_SCRUBBED=0
LAST_TICK_TIME="$NOW"

while true; do
    sleep "$POLL_INTERVAL"

    CURRENT_TIME="${MOCK_TIME:-$(date +%s)}"
    RAW_STATUS="$(get_scrub_status_raw)"
    CURRENT_STATUS="$(parse_status_field "$RAW_STATUS" "Status" | tr '[:upper:]' '[:lower:]')"

    if [[ "$CURRENT_STATUS" == "finished" ]]; then
        log_info "=========================================================="
        log_info "Scrub completed successfully on '$MOUNTPOINT'!"
        print_scrub_status "Final Scrub Status on Completion:"
        log_info "=========================================================="
        # Reset limit to unlimited upon completion
        apply_scrub_limit 0
        exit 0
    fi

    if [[ "$CURRENT_STATUS" == "interrupted" || "$CURRENT_STATUS" == "aborted" ]]; then
        log_warn "Scrub became $CURRENT_STATUS."
        print_scrub_status "Interrupted Scrub Status:"
        log_info "Attempting to resume..."
        btrfs_cmd scrub resume "$MOUNTPOINT" || true
        continue
    fi

    # Extract progress data
    TOT_RAW="$(parse_status_field "$RAW_STATUS" "Total to scrub" | awk '{print $1}')"
    SCRUBBED_RAW="$(parse_status_field "$RAW_STATUS" "Bytes scrubbed" | awk '{print $1}')"

    # In case scrub just started and numbers aren't populated yet
    if ! [[ "$TOT_RAW" =~ ^[0-9]+$ && "$SCRUBBED_RAW" =~ ^[0-9]+$ && "$TOT_RAW" -gt 0 ]]; then
        log_debug "Waiting for scrub statistics to populate..."
        continue
    fi

    ELAPSED_CYCLE=$(( CURRENT_TIME - CYCLE_START_TIME ))
    if (( ELAPSED_CYCLE < 1 )); then
        ELAPSED_CYCLE=1
    fi

    REMAIN_BYTES=$(( TOT_RAW - SCRUBBED_RAW ))
    if (( REMAIN_BYTES < 0 )); then
        REMAIN_BYTES=0
    fi

    PERCENT="$(awk -v d="$SCRUBBED_RAW" -v t="$TOT_RAW" 'BEGIN { printf "%.2f", (d / t) * 100 }')"

    # Calculate speeds
    # 1. Past average speed across the cycle (including downtime):
    V_PAST="$(awk -v b="$SCRUBBED_RAW" -v t="$ELAPSED_CYCLE" 'BEGIN { printf "%.2f", b / t }')"

    # 2. Instantaneous speed over the last polling tick:
    TICK_DELTA=$(( CURRENT_TIME - LAST_TICK_TIME ))
    if (( TICK_DELTA < 1 )); then
        TICK_DELTA=1
    fi
    DELTA_BYTES=$(( SCRUBBED_RAW - LAST_SCRUBBED ))
    if (( DELTA_BYTES < 0 )); then
        DELTA_BYTES=0
    fi
    V_RECENT="$(awk -v b="$DELTA_BYTES" -v t="$TICK_DELTA" 'BEGIN { printf "%.2f", b / t }')"

    LAST_SCRUBBED="$SCRUBBED_RAW"
    LAST_TICK_TIME="$CURRENT_TIME"

    TARGET_LIMIT=0

    if (( ELAPSED_CYCLE >= CUTOFF_DURATION )); then
        # After cutoff: no limit should be applied
        TARGET_LIMIT=0
        if [[ "$LAST_LIMIT" -ne 0 ]]; then
            log_info "Elapsed cycle time ($(format_duration "$ELAPSED_CYCLE")) has reached cutoff ($(format_duration "$CUTOFF_DURATION"))."
            log_info "Removing rate limit: unlimited (0 B/s) applied."
            apply_scrub_limit 0
            LAST_LIMIT=0
        fi
        if [[ "$VERBOSE" -eq 1 ]]; then
            log_info "Progress: ${PERCENT}% ($(format_bytes "$SCRUBBED_RAW") / $(format_bytes "$TOT_RAW")) | Status: past cutoff | Limit: unlimited"
        fi
    else
        # Before cutoff: regulate limit based on trend and remaining requirement
        TIME_TO_CUTOFF=$(( CUTOFF_DURATION - ELAPSED_CYCLE ))
        if (( TIME_TO_CUTOFF < 1 )); then
            TIME_TO_CUTOFF=1
        fi

        # Required rate to finish remaining data within remaining time:
        V_REQ="$(awk -v b="$REMAIN_BYTES" -v t="$TIME_TO_CUTOFF" 'BEGIN { printf "%.2f", b / t }')"

        # Trend steering calculation:
        # If V_PAST < V_REQ: trend is lagging behind (e.g. server was down).
        # Boost limit proportionally to steer trend back to finish on time.
        # If V_PAST >= V_REQ: trend is ahead of schedule.
        # Gently throttle limit to V_REQ (minimum MIN_LIMIT) to save I/O.
        IFS=$'\t' read -r TARGET_LIMIT TREND_NOTE PROJ_REMAIN_SEC < <(awk \
            -v req="$V_REQ" \
            -v past="$V_PAST" \
            -v min="$MIN_LIMIT" \
            -v rem="$REMAIN_BYTES" 'BEGIN {
                if (past < req) {
                    boost = 1 + ((req - past) / req);
                    lim = req * boost;
                    note = "lagging (boosted)";
                } else {
                    lim = req;
                    if (past > req * 1.05) {
                        note = "ahead of schedule (throttling down)";
                    } else {
                        note = "on schedule";
                    }
                }
                if (lim < min) lim = min;
                proj = 0;
                if (past > 0) proj = rem / past;
                printf "%.0f\t%s\t%.0f\n", lim, note, proj;
            }')

        # Apply limit if changed significantly (>5% change or first set)
        LIMIT_CHANGE=1
        if [[ "$LAST_LIMIT" -gt 0 ]]; then
            DIFF=$(( TARGET_LIMIT > LAST_LIMIT ? TARGET_LIMIT - LAST_LIMIT : LAST_LIMIT - TARGET_LIMIT ))
            if (( DIFF * 20 < LAST_LIMIT )); then
                LIMIT_CHANGE=0
            fi
        fi

        if [[ "$LIMIT_CHANGE" -eq 1 ]]; then
            apply_scrub_limit "$TARGET_LIMIT"
            LAST_LIMIT="$TARGET_LIMIT"
        fi

        if [[ "$VERBOSE" -eq 1 ]]; then
            log_info "Progress: ${PERCENT}% ($(format_bytes "$SCRUBBED_RAW") / $(format_bytes "$TOT_RAW")) | V_past: $(format_bytes "${V_PAST%.*}")/s | V_req: $(format_bytes "${V_REQ%.*}")/s | Limit: $(format_bytes "$TARGET_LIMIT")/s | Cutoff in: $(format_duration "$TIME_TO_CUTOFF") [Trend: ${TREND_NOTE}]"
            log_debug "Instantaneous tick speed: $(format_bytes "${V_RECENT%.*}")/s | Projected remaining: $(format_duration "$PROJ_REMAIN_SEC")"
        fi
    fi
done
