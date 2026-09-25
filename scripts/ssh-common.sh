# Shared SSH setup for the device-facing scripts. Sourced, not executed.
#
# Every helper in deploy.sh and device-screenshot.sh is its own ssh invocation,
# and a deploy makes a few dozen of them. On a Cortex-A35 the TCP handshake and
# key exchange cost more than the work being asked for, so multiplex them: the
# first connection opens a master socket and the rest ride along on it.
#
# Both scripts derive the same socket path on purpose - a screenshot run
# straight after a deploy reuses the connection the deploy already opened.
#
# Callers must define DEVICE before sourcing this, and should call
# ssh_shutdown on exit.

# %C is a hash of (host, port, user, ...), which keeps the path short. That
# matters: the socket is a unix domain address, so the whole thing has to fit
# in ~104 bytes, and macOS's TMPDIR alone eats half of that.
SSH_CTL_DIR="${SSH_CTL_DIR:-/tmp/.r36s-ssh-$(id -u)}"
mkdir -p "$SSH_CTL_DIR"
chmod 700 "$SSH_CTL_DIR"

# ControlPersist outlives the script so consecutive make targets share one
# connection, but not so long that a forgotten socket keeps a sleeping
# handheld's session open all afternoon.
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=$SSH_CTL_DIR/%C -o ControlPersist=120}"

# shellcheck disable=SC2086
sshd() { ssh $SSH_OPTS "$DEVICE" "$@"; }

# Close the master deliberately when we are done with the device. Without this
# the port stays open for ControlPersist seconds after the last command, which
# is harmless but confusing when you are watching the handheld's connections.
ssh_shutdown() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -O exit "$DEVICE" >/dev/null 2>&1 || true
}
