# btrfs-scrub-manager
btrfs scrub script that uses btrfs scrub limit to prevent stalling system while scrubbing.
Btrfs now can use limit to throttle disk parsing. This script starts or resume a scrub and makes sure to finish the scrub on time before a `-p` period.
The idea is that the user wants a monthly scrub, but the scrub should not stall the system. To prevent stalling the script sets the scrub limit to an appropriate value to finish scrub on time, before 15 of the month.

Period is set be default to one month.
Script will start scrubbing *automatically* every period and will try to finish it by current cycle + period/2.
The script is smart enough to adjust rate based on how much data were already scrubbed and when is the cutoff date.
Please crontab this every hour.

```
Arguments:
    MOUNTPOINT                Path to mounted Btrfs filesystem (e.g. / or /home)

Options:
    -p, --period SECONDS      Scrub cycle period in seconds.
                              Default: 2629744s (=(365d 5h 48m 45s)/12, ~30.44 days)
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
```
