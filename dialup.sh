#!/usr/bin/env bash
#
# dialup.sh - dial a USB modem with pppd and show a live status screen:
# connection state, IP/DNS, duration, bytes in/out, speed and the process log.
#
#   sudo ./dialup.sh --probe                 Show modem/SIM/signal info, no dialing
#   sudo ./dialup.sh --apn internet          Dial, keep the current default route
#   sudo ./dialup.sh --apn internet --default-route
#                                            Dial and send all traffic over the modem
#   sudo ./dialup.sh --beeline               Dial with the Beeline UZ settings
#   sudo ./dialup.sh --beeline --3g          The same, but only use the 3G network
#   sudo ./dialup.sh --beeline --2g          Save 2G only on the modem; once it is set
#                                            and the modem was replugged, this dials
#   sudo ./dialup.sh --auto-network          Put the modem back on automatic
#
# Press Ctrl-C to hang up. The session log is kept in ./logs next to this script.

set -u

SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

ORIGINAL_ARGS=("$@")
APN=""
NUMBER="*99#"
PORT=""
BAUD=460800
PPP_USER=""
PPP_PASSWORD="${DIALUP_PASSWORD:-}"
DEFAULT_ROUTE=0
PROBE_ONLY=0
CONNECT_TIMEOUT=60
NETWORK_TIMEOUT=300
CHALLENGE_TIMEOUT=180
PING_TARGET="1.1.1.1"
CONTROL_PORT=""
USE_ZOPERT=1
FORCE_3G=0
FORCE_2G=0
AUTO_NETWORK=0
RESPONDER="$SCRIPT_DIR/zopert_responder.py"

usage() {
    cat <<EOF
Usage: sudo $(basename "$0") [options]

  --apn NAME         Carrier APN (default: the APN already stored in the modem)
  --number NUM       Number to dial (default: $NUMBER)
  --port DEV         Data port, e.g. /dev/ttyUSB2 (default: auto-detect)
  --baud RATE        Serial speed (default: $BAUD)
  --user NAME        PPP username, if the carrier needs one
                     (the password is read from \$DIALUP_PASSWORD)
  --control-port DEV Second AT port for status and the ZOPERTE handshake
                     (default: auto-detect)
  --beeline          Use the Beeline UZ APN and login from the vendor config
  --responder FILE   ZOPERTE responder script
                     (default: zopert_responder.py next to this script)
  --no-zopert        Do not answer +ZOPERTER challenges
  --3g               Only use the 3G network while dialing; the modem's previous
                     network mode is put back on exit
  --2g               Save 2G only on the modem, so it never tries 3G after a restart.
                     If it is not set yet, this sets it and asks you to replug.
                     It stays set until --auto-network
  --auto-network     Save the automatic network mode (3G preferred) and exit
  --default-route    Route all traffic over the modem while connected
  --no-ping          Skip the connectivity check after connecting
  --probe            Show modem, SIM and signal info, then exit without dialing
  -h, --help         Show this help
EOF
}

# PROBE_ONLY skips the session summary: nothing was dialed.
die() { echo "dialup: $*" >&2; PROBE_ONLY=1; exit 1; }

need_value() { [[ $# -ge 2 ]] || die "$1 needs a value"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apn)           need_value "$@"; APN=$2; shift 2 ;;
        --number)        need_value "$@"; NUMBER=$2; shift 2 ;;
        --port)          need_value "$@"; PORT=$2; shift 2 ;;
        --baud)          need_value "$@"; BAUD=$2; shift 2 ;;
        --user)          need_value "$@"; PPP_USER=$2; shift 2 ;;
        --control-port)  need_value "$@"; CONTROL_PORT=$2; shift 2 ;;
        --beeline)       APN=internet.beeline.uz; PPP_USER=beeline; PPP_PASSWORD=beeline; shift ;;
        --responder)     need_value "$@"; RESPONDER=$2; shift 2 ;;
        --no-zopert)     USE_ZOPERT=0; shift ;;
        --3g)            FORCE_3G=1; shift ;;
        --2g)            FORCE_2G=1; shift ;;
        --auto-network)  AUTO_NETWORK=1; shift ;;
        --default-route) DEFAULT_ROUTE=1; shift ;;
        --no-ping)       PING_TARGET=""; shift ;;
        --probe)         PROBE_ONLY=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; die "unknown option: $1" ;;
    esac
done

# These values end up inside a chat script, so only allow what is valid in them.
[[ -z $APN || $APN =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid APN: $APN"
[[ $NUMBER =~ ^[0-9*#]+$ ]] || die "invalid number: $NUMBER"
[[ $BAUD =~ ^[0-9]+$ ]] || die "invalid baud rate: $BAUD"
((FORCE_2G + FORCE_3G + AUTO_NETWORK <= 1)) || die "use only one of --2g, --3g and --auto-network"
[[ -z $PORT || -c $PORT ]] || die "not a serial device: $PORT"
[[ -z $CONTROL_PORT || -c $CONTROL_PORT ]] || die "not a serial device: $CONTROL_PORT"

if [[ $EUID -ne 0 ]]; then
    echo "dialup: root is needed for pppd and the modem ports, asking sudo..."
    exec sudo --preserve-env=DIALUP_PASSWORD "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}"
fi

for tool in pppd chat stty ip numfmt; do
    command -v "$tool" >/dev/null || die "$tool is not installed"
done

WORK_DIR=$(mktemp -d /tmp/dialup.XXXXXX) || die "cannot create a temp directory"
chmod 700 "$WORK_DIR"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/dialup-$(date +%Y%m%d-%H%M%S).log"
: >"$LOG"
export LOG
RAW_LOG="$WORK_DIR/raw.log"
: >"$RAW_LOG"
if [[ -n ${SUDO_USER:-} ]]; then
    chown "$SUDO_USER" "$LOG_DIR" "$LOG"
fi

# --- logging -----------------------------------------------------------------

log() { printf '%(%H:%M:%S)T %s\n' -1 "$*" >>"$LOG"; }

STATE="STARTING"
set_state() { STATE=$1; log "== state: $1"; }

# In dashboard mode the screen is redrawn, otherwise log lines go straight out.
DASHBOARD=0
[[ -t 1 ]] && DASHBOARD=1

FOLLOWER_PID=""
PPPD_PID=""
RESPONDER_PID=""
ZOPERT_ACTIVE=0
MM_STOPPED=0
SCREEN_ACTIVE=0
FINISHED=0

# pppd and chat write plain lines to RAW_LOG, this adds the timestamps.
start_stamper() {
    tail -n +1 -F "$RAW_LOG" 2>/dev/null | while IFS= read -r line; do
        # chat -v prints carriage returns as a literal ^M.
        line=${line//^M/}
        [[ -n ${line// /} ]] && log "$line"
    done &
}

# --- modem access ------------------------------------------------------------

# Writes one line of AT traffic to the log. The SIM PIN never reaches the log.
at_trace() {
    local text=$2
    [[ $text == AT+CPIN=* ]] && text="AT+CPIN=****"
    printf '%(%H:%M:%S)T %s %s\n' -1 "$1" "$text" >>"$LOG"
}
export -f at_trace

# Sends AT commands to a port and prints the replies. Runs in its own process
# under `timeout`, because a wedged port can block on open.
at_session() {
    local port=$1 cmd line deadline answered ok skip_at=0
    shift
    # USB modem drivers ignore line settings such as speed and stty reports that
    # as an error, even though raw mode is applied, so its result is not checked.
    stty -F "$port" raw -echo clocal 2>/dev/null
    exec 3<>"$port" || { at_trace "$port" "cannot open the port"; return 1; }
    # Opening the port raises DTR, give the modem a moment to react to it.
    sleep 0.5
    # Drop anything left over in the buffer.
    while IFS= read -r -t 0.1 line <&3; do :; done
    for cmd in "$@"; do
        # Repeated plain ATs are retries: stop once the port said OK or nothing at all.
        [[ $cmd == AT ]] && ((skip_at)) && continue
        printf '%s\r' "$cmd" >&3
        at_trace "$port >>" "$cmd"
        answered=0
        ok=0
        deadline=$((SECONDS + ${AT_REPLY_TIMEOUT:-3}))
        while ((SECONDS < deadline)); do
            IFS= read -r -t 1 line <&3 || continue
            line=${line//$'\r'/}
            [[ -z $line || $line == "$cmd" ]] && continue
            printf '%s\n' "$line"
            at_trace "$port <<" "$line"
            answered=1
            [[ $line == OK ]] && ok=1
            # A leftover NO CARRIER ends the wait too: no OK follows it.
            [[ $line == OK || $line == ERROR || $line == "NO CARRIER" || $line == *"CME ERROR"* || $line == *"CMS ERROR"* ]] && break
        done
        ((answered)) || at_trace "$port <<" "(no reply)"
        ((ok || !answered)) && skip_at=1
    done
    exec 3<&-
}
export -f at_session

at() {
    local port=$1 budget
    shift
    budget=$(((${AT_REPLY_TIMEOUT:-3} + 1) * $# + 3))
    timeout "$budget" bash -c 'at_session "$@"' _ "$port" "$@" 2>/dev/null
}

# Prints the AT-responsive ports, the data port first.
find_ports() {
    local dev reply data=() other=()
    for dev in /dev/ttyUSB* /dev/ttyACM*; do
        [[ -c $dev ]] || continue
        # After a port is reopened the modem can answer the first AT with a stale
        # NO CARRIER and drop the command, so a port that replies gets more tries.
        reply=$(at "$dev" AT AT AT)
        if [[ $reply == *OK* ]]; then
            log "port $dev: answers AT"
            if udevadm info "$dev" 2>/dev/null | grep -qE 'ID_MM_(ZTE_PORT_TYPE_MODEM|PORT_TYPE_AT_PRIMARY)=1'; then
                data+=("$dev")
            else
                other+=("$dev")
            fi
        else
            log "port $dev: no AT response"
        fi
    done
    printf '%s\n' "${data[@]+"${data[@]}"}" "${other[@]+"${other[@]}"}" | grep -v '^$'
}

# ModemManager opens the same ports and would fight with pppd over them.
pause_modemmanager() {
    if systemctl is-active --quiet ModemManager 2>/dev/null; then
        log "stopping ModemManager while the modem is in use"
        systemctl stop ModemManager && MM_STOPPED=1
    fi
}

resume_modemmanager() {
    if ((MM_STOPPED)); then
        log "restarting ModemManager"
        systemctl start ModemManager
        MM_STOPPED=0
    fi
}

# Logs what the modem reports about itself, the SIM and the network.
report_modem() {
    MODEM_INFO=$(at "$1" ATE0 ATI 'AT+CGMR' 'AT+CPIN?' 'AT+CSQ' 'AT+CREG?' 'AT+CGREG?' 'AT+CGATT?' 'AT+COPS?' 'AT+CGDCONT?' \
        'AT+CGCLASS?' 'AT+CFUN?' 'AT+ZPAS?' 'AT+ZSNT?' 'AT+ZSEC?' 'AT+ZOPRT?')
}

describe_signal() {
    local csq
    csq=$(sed -n 's/^+CSQ: *\([0-9]*\),.*/\1/p' <<<"$MODEM_INFO" | head -1)
    if [[ -z $csq || $csq == 99 ]]; then
        echo "unknown"
    else
        echo "$((csq * 2 - 113)) dBm (CSQ $csq)"
    fi
}

describe_sim() {
    local sim
    sim=$(sed -n 's/^+CPIN: *//p; s/^+CME ERROR: *//p' <<<"$MODEM_INFO" | head -1)
    echo "${sim:-unknown}"
}

registration_code() { sed -n 's/^+CG\{0,1\}REG: *[0-9]*,\([0-9]*\).*/\1/p' <<<"$1" | head -1; }

is_registered() { grep -qE '^\+CG?REG: *[0-9]+,[15]' <<<"$1"; }

is_attached() { grep -qE '^\+CGATT: *1|^\+CGREG: *[0-9]+,[15]' <<<"$1"; }

describe_registration() {
    case "$(registration_code "$(grep '^+CREG' <<<"$MODEM_INFO")")" in
        0) echo "not registered, not searching" ;;
        1) echo "registered, home network" ;;
        2) echo "searching" ;;
        3) echo "registration denied" ;;
        5) echo "registered, roaming" ;;
        *) echo "unknown" ;;
    esac
}

# The SIM needs a while after plug-in, and until then the modem answers ERROR to
# anything about the network.
wait_for_sim() {
    local port=$1 tries=0
    [[ $MODEM_INFO == *"SIM busy"* ]] || return 0
    echo "Waiting for the SIM to get ready..."
    while ((tries < 15)) && [[ $(at "$port" 'AT+CPIN?') == *"SIM busy"* ]]; do
        tries=$((tries + 1))
        sleep 2
    done
    report_modem "$port"
}

# Waits for the modem to register on the network. Dialing before that can only fail.
# Registration took several minutes on the MF180S.
wait_for_network() {
    local port=$1 reply started=$SECONDS next_note=0 csq
    is_registered "$MODEM_INFO" && return 0
    echo "Waiting for the network (up to $NETWORK_TIMEOUT seconds)..."
    while ((SECONDS - started < NETWORK_TIMEOUT)); do
        reply=$(at "$port" 'AT+CSQ' 'AT+CREG?' 'AT+CGREG?')
        if is_registered "$reply" || grep -qE '^\+CREG: *[0-9]+,3' <<<"$reply"; then
            report_modem "$port"
            is_registered "$MODEM_INFO"
            return
        fi
        if ((SECONDS - started >= next_note)); then
            csq=$(sed -n 's/^+CSQ: *\([0-9]*\),.*/\1/p' <<<"$reply")
            echo "  $((SECONDS - started))s: not registered yet, signal CSQ ${csq:-?}"
            next_note=$((SECONDS - started + 30))
        fi
        sleep 5
    done
    report_modem "$port"
    return 1
}

# The MF180S registers for calls by itself (+CREG) but does not try to attach for
# packet data (+CGREG: 0,0), so it has to be asked. This uses the data port, because
# the responder may be reading the other one.
try_attach() {
    local reply tries=0
    reply=$(export AT_REPLY_TIMEOUT=60; at "$PORT" 'AT+CGATT=1')
    ATTACH_ERROR=$(grep -m1 'ERROR' <<<"$reply")
    [[ -n $reply ]] || ATTACH_ERROR="no reply"
    while [[ -z $ATTACH_ERROR ]] && ((tries < 6)); do
        if is_attached "$(at "$PORT" 'AT+CGATT?' 'AT+CGREG?')"; then
            report_modem "$PORT"
            return 0
        fi
        tries=$((tries + 1))
        sleep 3
    done
    at "$PORT" 'AT+CEER' >/dev/null
    report_modem "$PORT"
    return 1
}

# Attaches for packet data. The modem reports +ZPAS "CS_ONLY" before the ZOPERTE
# handshake, and an AT+CGATT=1 sent at that point hung and then lost the registration,
# so the handshake comes first, in the vendor app's order. AT+ZSTART is sent without
# the AT+ZOPRT=6 that takes the radio down.
attach_packet_data() {
    local tries=0 reply
    is_attached "$MODEM_INFO" && return 0
    if ((USE_ZOPERT)); then
        at "$CONTROL_PORT" 'AT+ZSTART' >/dev/null
        start_responder
        wait_for_challenge
        echo "Handshake: $(handshake_status). Waiting for packet service..."
        while ((tries < 10)); do
            reply=$(at "$PORT" 'AT+ZPAS?' 'AT+CGATT?' 'AT+CGREG?')
            if is_attached "$reply"; then
                report_modem "$PORT"
                return 0
            fi
            [[ $reply == *CS_PS* || $reply == *PS_ONLY* ]] && break
            tries=$((tries + 1))
            sleep 3
        done
    fi
    echo "Attaching for packet data..."
    try_attach
}

# AT+ZSNT=<mode>,0,<preference>: mode 0 automatic, 1 2G only, 2 3G only. The modem
# saves this across restarts, so restore_network_mode puts the old value back.
force_3g() {
    local port=$1 reply
    SAVED_ZSNT=$(sed -n 's/^+ZSNT: *\([0-9]*,[0-9]*,[0-9]*\).*/\1/p' <<<"$MODEM_INFO" | head -1)
    echo "Switching the modem to 3G only (was ${SAVED_ZSNT:-unknown})..."
    reply=$(export AT_REPLY_TIMEOUT=10; at "$port" 'AT+ZSNT=2,0,0')
    [[ $reply == *OK* ]] || return 1
    log "network mode set to 3G only, previous mode ${SAVED_ZSNT:-unknown}"
    ZSNT_CHANGED=1
    # The old registration stays visible for a moment after the switch.
    sleep 5
    report_modem "$port"
}

# Saves a network mode and leaves it set: it has to survive the modem's restart.
save_network_mode() {
    local port=$1 mode=$2 reply
    reply=$(export AT_REPLY_TIMEOUT=10; at "$port" "AT+ZSNT=$mode")
    [[ $reply == *OK* ]] || die "the modem refused AT+ZSNT=$mode: $reply"
    log "network mode saved: $mode"
}

# A data refusal on 3G right after power-up may stop the modem from trying data on
# 2G as well, so 2G only must already be set when the modem starts. Returns only when
# that is the case, otherwise it sets the mode and asks for a replug.
force_2g() {
    local port=$1 current
    current=$(sed -n 's/^+ZSNT: *\([0-9]*,[0-9]*,[0-9]*\).*/\1/p' <<<"$MODEM_INFO" | head -1)
    if [[ $current == 1,* ]]; then
        log "network mode is already 2G only ($current)"
        return
    fi
    save_network_mode "$port" 1,0,0
    echo "The modem is now saved as 2G only (was ${current:-unknown})."
    echo "Unplug it, plug it back in, wait 20 seconds, and run the same command again."
    echo "To go back later: sudo $0 --auto-network"
    PROBE_ONLY=1
    exit 0
}

restore_network_mode() {
    ((ZSNT_CHANGED)) || return
    if [[ -n $SAVED_ZSNT ]]; then
        (export AT_REPLY_TIMEOUT=10; at "$CONTROL_PORT" "AT+ZSNT=$SAVED_ZSNT") >/dev/null
        log "network mode restored to $SAVED_ZSNT"
    else
        log "the previous network mode is unknown, the modem stays on 3G only"
        echo "Note: the modem stays on 3G only. AT+ZSNT=0,0,0 sets it back to automatic."
    fi
    ZSNT_CHANGED=0
}

# Asks for the SIM PIN if needed. A wrong PIN uses up one of the SIM's attempts,
# so it is only ever tried once and never read from a file or an option.
unlock_sim() {
    local port=$1 pin reply
    [[ $MODEM_INFO == *"SIM PIN"* ]] || return 0
    [[ -t 0 ]] || die "the SIM needs a PIN, run this from a terminal"
    read -r -s -p "SIM PIN: " pin
    echo
    [[ $pin =~ ^[0-9]{4,8}$ ]] || die "a PIN is 4 to 8 digits"
    reply=$(at "$port" "AT+CPIN=$pin")
    [[ $reply == *OK* ]] || die "the modem rejected the PIN: $reply"
    log "SIM unlocked"
    sleep 3
    report_modem "$port"
}

# --- ZOPERTE handshake -------------------------------------------------------

# The modem challenges with "+ZOPERTER: <k>,<nonce>" and expects
# "AT+ZOPERTE=<k+1>,<answer>". pppd owns the data port once it is online, so the
# responder has to run on the other AT port. It only answers: it must not restart
# the modem's cycle, because AT+ZOPRT=6 takes the radio off the network for minutes.
start_responder() {
    [[ -n $RESPONDER_PID ]] && return
    ((USE_ZOPERT)) || { log "ZOPERTE responder: turned off"; return; }
    if [[ $CONTROL_PORT == "$PORT" ]]; then
        log "ZOPERTE responder: NOT started, it needs a second AT port (see --control-port)"
    elif [[ ! -f $RESPONDER ]]; then
        log "ZOPERTE responder: NOT started, $RESPONDER is missing"
    elif ! command -v python3 >/dev/null; then
        log "ZOPERTE responder: NOT started, python3 is missing"
    else
        log "ZOPERTE responder: starting on $CONTROL_PORT"
        python3 "$RESPONDER" -v --passive --mutual "$CONTROL_PORT" >>"$RAW_LOG" 2>&1 </dev/null &
        RESPONDER_PID=$!
        ZOPERT_ACTIVE=1
    fi
}

wait_for_challenge() {
    local started=$SECONDS
    ((ZOPERT_ACTIVE)) || return 0
    echo "Waiting for a +ZOPERTER challenge (up to $CHALLENGE_TIMEOUT seconds)..."
    while ((SECONDS - started < CHALLENGE_TIMEOUT)); do
        if grep -qE 'ZOPERTE: [0-9]+,[01](\\r|\\n|$)' "$LOG"; then
            log "ZOPERTE: $(handshake_status) after $((SECONDS - started)) seconds"
            return 0
        fi
        sleep 1
    done
    log "ZOPERTE: no challenge within $CHALLENGE_TIMEOUT seconds"
}

stop_responder() {
    [[ -n $RESPONDER_PID ]] || return
    kill "$RESPONDER_PID" 2>/dev/null
    wait "$RESPONDER_PID" 2>/dev/null
    RESPONDER_PID=""
}

handshake_status() {
    if ((ZOPERT_ACTIVE == 0)); then
        echo "not running"
        return
    fi
    echo "$(grep -c 'challenge [0-9]* nonce=' "$LOG") challenges," \
        "$(grep -cE 'ZOPERTE: [0-9]+,1(\\r|\\n|$)' "$LOG") accepted," \
        "$(grep -cE 'ZOPERTE: [0-9]+,0(\\r|\\n|$)' "$LOG") rejected"
}

# --- pppd --------------------------------------------------------------------

write_chat_script() {
    {
        # NO CARRIER only aborts from the dial on: a stale one can greet the first AT,
        # which is then dropped, so OK-AT-OK sends it again.
        printf "ABORT BUSY\nABORT 'NO DIALTONE'\nABORT 'NO ANSWER'\nABORT ERROR\n"
        printf "REPORT CONNECT\nTIMEOUT 5\n'' AT\nOK-AT-OK ATE0\n"
        [[ -n $APN ]] && printf "OK 'AT+CGDCONT=1,\"IP\",\"%s\"'\n" "$APN"
        printf "ABORT 'NO CARRIER'\nTIMEOUT %s\nOK ATD%s\nCONNECT \\\\c\n" "$CONNECT_TIMEOUT" "$NUMBER"
    } >"$WORK_DIR/chat"
}

write_ppp_options() {
    local quoted
    {
        echo "unit $PPP_UNIT"
        echo "logfile $RAW_LOG"
        cat <<EOF
nodetach
noauth
local
lock
noipdefault
nodefaultroute
usepeerdns
noipv6
debug
ipcp-accept-local
ipcp-accept-remote
novj
novjccomp
nobsdcomp
nodeflate
lcp-echo-interval 30
lcp-echo-failure 4
maxfail 1
hide-password
EOF
        if [[ -n $PPP_USER ]]; then
            quoted=${PPP_USER//\\/\\\\}
            echo "user \"${quoted//\"/\\\"}\""
        fi
        if [[ -n $PPP_PASSWORD ]]; then
            quoted=${PPP_PASSWORD//\\/\\\\}
            echo "password \"${quoted//\"/\\\"}\""
        fi
    } >"$WORK_DIR/options"
    chmod 600 "$WORK_DIR/options"
}

pick_ppp_unit() {
    local unit=0
    while [[ -e /sys/class/net/ppp$unit ]]; do
        unit=$((unit + 1))
    done
    PPP_UNIT=$unit
    IFACE="ppp$unit"
}

start_pppd() {
    write_chat_script
    write_ppp_options
    local connect="chat -v -s -f $WORK_DIR/chat 2>>$RAW_LOG"
    DIALED=1
    log "starting pppd on $PORT at $BAUD baud (dial $NUMBER, APN ${APN:-from modem})"
    pppd "$PORT" "$BAUD" file "$WORK_DIR/options" connect "$connect" >/dev/null 2>&1 </dev/null &
    PPPD_PID=$!
}

# --- status ------------------------------------------------------------------

human() { numfmt --to=iec --suffix=B --format='%.2f' "$1" 2>/dev/null || echo "$1 B"; }

RX=0 TX=0 RX_RATE=0 TX_RATE=0 LOCAL_IP="-" REMOTE_IP="-" DNS="-" PORT_NOTE=""
CONNECTED_AT=0 ROUTE_NOTE="unchanged"

iface_stat() { cat "/sys/class/net/$IFACE/statistics/$1" 2>/dev/null; }

sample_traffic() {
    local rx tx
    rx=$(iface_stat rx_bytes)
    tx=$(iface_stat tx_bytes)
    # The link can vanish between the two reads, keep the last totals if it does.
    [[ -n $rx && -n $tx ]] || { RX_RATE=0; TX_RATE=0; return; }
    RX_RATE=$(((rx - RX) > 0 ? rx - RX : 0))
    TX_RATE=$(((tx - TX) > 0 ? tx - TX : 0))
    RX=$rx
    TX=$tx
}

# Reads the state of the connection from what pppd has logged so far.
update_state() {
    if [[ $STATE == DIALING ]] && grep -q 'Serial connection established' "$LOG"; then
        set_state NEGOTIATING
    fi
    if [[ $STATE == NEGOTIATING ]] && grep -q 'local  IP address' "$LOG"; then
        LOCAL_IP=$(sed -n 's/.*local  IP address \([0-9.]*\).*/\1/p' "$LOG" | tail -1)
        REMOTE_IP=$(sed -n 's/.*remote IP address \([0-9.]*\).*/\1/p' "$LOG" | tail -1)
        DNS=$(sed -n 's/.*\(primary\|secondary\) *DNS address \([0-9.]*\).*/\2/p' "$LOG" | paste -sd' ' -)
        [[ -n $DNS ]] || DNS="-"
        CONNECTED_AT=$SECONDS
        set_state CONNECTED
        on_connected
    fi
}

on_connected() {
    if ((DEFAULT_ROUTE)); then
        # A low metric wins over the existing routes and disappears with the link.
        if ip route add default dev "$IFACE" metric 10 2>>"$LOG"; then
            ROUTE_NOTE="all traffic via $IFACE"
            log "default route now goes through $IFACE"
        else
            ROUTE_NOTE="could not add default route"
            log "could not add the default route"
        fi
    fi
    if [[ -n $PING_TARGET ]]; then
        (
            if ping -I "$IFACE" -c 3 -W 5 "$PING_TARGET" >/dev/null 2>&1; then
                log "connectivity check: $PING_TARGET reachable through $IFACE"
            else
                log "connectivity check: $PING_TARGET NOT reachable through $IFACE"
            fi
        ) &
    fi
}

format_duration() { printf '%02d:%02d:%02d' $(($1 / 3600)) $((($1 % 3600) / 60)) $(($1 % 60)); }

connection_time() {
    if ((CONNECTED_AT > 0)); then
        format_duration $(((ENDED_AT > 0 ? ENDED_AT : SECONDS) - CONNECTED_AT))
    else
        echo "--:--:--"
    fi
}

state_color() {
    case "$STATE" in
        CONNECTED) printf '\e[1;32m' ;;
        FAILED)    printf '\e[1;31m' ;;
        ENDED)     printf '\e[1;33m' ;;
        *)         printf '\e[1;36m' ;;
    esac
}

draw_screen() {
    local rows cols log_rows
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols 2>/dev/null || echo 80)
    log_rows=$((rows - 14))
    ((log_rows < 3)) && log_rows=3
    {
        printf '\e[H'
        printf '\e[1m USB modem dial-up\e[0m%s\e[K\n' "$PORT_NOTE"
        printf ' %*s\e[K\n' $((cols > 2 ? cols - 2 : 1)) '' | tr ' ' '-'
        printf ' State     : %s%s\e[0m\e[K\n' "$(state_color)" "$STATE"
        printf ' Interface : %-10s Duration : %s\e[K\n' "$IFACE" "$(connection_time)"
        printf ' Local IP  : %-16s Remote IP : %s\e[K\n' "$LOCAL_IP" "$REMOTE_IP"
        printf ' DNS       : %s\e[K\n' "$DNS"
        printf ' Route     : %s\e[K\n' "$ROUTE_NOTE"
        printf ' Handshake : %s\e[K\n' "$(handshake_status)"
        printf ' In        : \e[1m%-12s\e[0m %s/s\e[K\n' "$(human "$RX")" "$(human "$RX_RATE")"
        printf ' Out       : \e[1m%-12s\e[0m %s/s\e[K\n' "$(human "$TX")" "$(human "$TX_RATE")"
        printf ' %*s\e[K\n' $((cols > 2 ? cols - 2 : 1)) '' | tr ' ' '-'
        printf '\e[2m Log: %s   (Ctrl-C to hang up)\e[0m\e[K\n' "$LOG"
        tail -n "$log_rows" "$LOG" | cut -c "1-$((cols > 1 ? cols - 1 : 1))" | while IFS= read -r line; do
            printf '%s\e[K\n' "$line"
        done
        printf '\e[J'
    } 2>/dev/null
}

open_screen() {
    if ((DASHBOARD)); then
        printf '\e[?1049h\e[?25l\e[2J'
        SCREEN_ACTIVE=1
    else
        tail -n +1 -F "$LOG" 2>/dev/null &
        FOLLOWER_PID=$!
    fi
}

close_screen() {
    if ((SCREEN_ACTIVE)); then
        printf '\e[?25h\e[?1049l'
        SCREEN_ACTIVE=0
    fi
    if [[ -n $FOLLOWER_PID ]]; then
        sleep 0.2
        kill "$FOLLOWER_PID" 2>/dev/null
        wait "$FOLLOWER_PID" 2>/dev/null
        FOLLOWER_PID=""
    fi
}

explain_failure() {
    local why="" dial_log
    if [[ -n $FAIL_REASON ]]; then
        echo "$FAIL_REASON"
        return
    fi
    # Only the dial itself: chat echoes its "abort on (...)" list, and >>> <<< lines
    # are the responder's traffic on the other port.
    dial_log=$(sed -n '/starting pppd/,$p' "$LOG" | grep -vE 'abort on|<<<|>>>')
    if grep -q 'Connect script failed' <<<"$dial_log"; then
        if grep -q 'NO CARRIER' <<<"$dial_log"; then
            why="The modem got NO CARRIER: check the APN, data plan and signal."
        elif grep -q 'ERROR' <<<"$dial_log"; then
            why="The modem answered ERROR to the dial: check the APN and SIM."
        else
            why="The modem did not answer the dial sequence: try another --port."
        fi
    elif grep -q 'IPCP: timeout' <<<"$dial_log"; then
        why="The call connected but the network gave the modem no IP address."
        [[ -n $MODEM_CAUSE ]] && why="$why Modem says: $MODEM_CAUSE"
        [[ -n $ATTACH_ERROR ]] && why="$why AT+CGATT=1 answered: $ATTACH_ERROR"
    elif grep -q 'Device .* is locked' "$LOG"; then
        why="Another program holds the port lock."
    elif grep -qE 'LCP: timeout|LCP terminated|Connection terminated' "$LOG" && ((CONNECTED_AT == 0)); then
        why="The call connected but PPP did not come up: check the APN and --user."
    fi
    [[ -n $why ]] && echo "$why"
}

# Asks the modem why the data session failed. Only safe once nothing else is
# reading the port, so this runs after the responder has stopped.
ask_failure_cause() {
    local reply
    reply=$(at "$CONTROL_PORT" 'AT+CEER' 'AT+CGATT?' 'AT+CGACT?')
    MODEM_CAUSE=$(sed -n 's/^+CEER: *//p' <<<"$reply" | head -1)
}

# --- shutdown ----------------------------------------------------------------

ENDED_AT=0
DIALED=0
MODEM_CAUSE=""
FAIL_REASON=""
ATTACH_ERROR=""
SAVED_ZSNT=""
ZSNT_CHANGED=0

finish() {
    ((FINISHED)) && return
    FINISHED=1
    trap '' INT TERM HUP

    if [[ -n $PPPD_PID ]] && kill -0 "$PPPD_PID" 2>/dev/null; then
        log "hanging up"
        kill -TERM "$PPPD_PID" 2>/dev/null
        local waited=0
        while kill -0 "$PPPD_PID" 2>/dev/null && ((waited < 10)); do
            ((DASHBOARD)) && { sample_traffic; draw_screen; }
            sleep 1
            waited=$((waited + 1))
        done
        kill -KILL "$PPPD_PID" 2>/dev/null
    fi
    [[ -n $PPPD_PID ]] && wait "$PPPD_PID" 2>/dev/null
    stop_responder
    ((DIALED && CONNECTED_AT == 0)) && ask_failure_cause
    restore_network_mode
    ((ENDED_AT == 0)) && ENDED_AT=$SECONDS
    case "$STATE" in
        CONNECTED)           set_state ENDED ;;
        DIALING|NEGOTIATING) set_state FAILED ;;
    esac
    resume_modemmanager

    sleep 0.3
    pkill -f "tail -n \+1 -F $RAW_LOG" 2>/dev/null
    close_screen

    if ((PROBE_ONLY == 0)); then
        local reason
        reason=$(explain_failure)
        echo
        echo "=== Session summary ==="
        echo "Result    : $STATE"
        echo "Connected : $(connection_time)"
        echo "In        : $(human "$RX") ($RX bytes)"
        echo "Out       : $(human "$TX") ($TX bytes)"
        echo "Handshake : $(handshake_status)"
        [[ $STATE == FAILED && -n $reason ]] && echo "Reason    : $reason"
        echo "Log       : $LOG"
        if [[ $STATE == FAILED ]]; then
            echo
            echo "--- last log lines ---"
            tail -n 15 "$LOG"
        fi
    fi
    rm -rf "$WORK_DIR"
}
trap finish EXIT
trap 'exit 130' INT TERM HUP

# --- main --------------------------------------------------------------------

MODEM_INFO=""
PPP_UNIT=0
IFACE="-"

start_stamper
log "dialup started"
pause_modemmanager
# Give the ports a moment to settle after ModemManager lets go of them.
((MM_STOPPED)) && sleep 2

echo "Looking for the modem's data port..."
mapfile -t AT_PORTS < <(find_ports)
if [[ -n $PORT ]]; then
    PORT_NOTE=" - $PORT"
else
    if [[ ${#AT_PORTS[@]} -eq 0 ]]; then
        STATE="FAILED"
        log "no serial port answered AT"
        echo "No modem port answers AT commands. Replug the modem, wait 20 seconds, try again."
        echo "If it still fails, name a port with --port. Log: $LOG"
        echo
        echo "--- AT log ---"
        grep -E ' (>>|<<) |cannot open' "$LOG"
        PROBE_ONLY=1
        exit 1
    fi
    PORT=${AT_PORTS[0]}
    PORT_NOTE=" - $PORT"
fi
if [[ -z $CONTROL_PORT ]]; then
    CONTROL_PORT=$PORT
    for candidate in "${AT_PORTS[@]+"${AT_PORTS[@]}"}"; do
        [[ $candidate != "$PORT" ]] && CONTROL_PORT=$candidate
    done
fi
log "data port $PORT, control port $CONTROL_PORT"

report_modem "$CONTROL_PORT"
wait_for_sim "$CONTROL_PORT"
unlock_sim "$CONTROL_PORT"
if ((AUTO_NETWORK)); then
    save_network_mode "$CONTROL_PORT" 0,0,2
    echo "The modem is back on the automatic network mode (0,0,2)."
    PROBE_ONLY=1
    exit 0
fi
if ((PROBE_ONLY == 0)); then
    ((FORCE_2G)) && force_2g "$CONTROL_PORT"
    if ((FORCE_3G)) && ! force_3g "$CONTROL_PORT"; then
        STATE="FAILED"
        FAIL_REASON="The modem refused the switch to 3G only (AT+ZSNT=2,0,0), so it did not dial."
        exit 1
    fi
    if ! wait_for_network "$CONTROL_PORT"; then
        STATE="FAILED"
        FAIL_REASON="The modem did not register on the network ($(describe_registration)), so it did not dial."
        exit 1
    fi
    if ! attach_packet_data; then
        log "packet data attach failed (${ATTACH_ERROR:-no error text}), dialing anyway: the call may attach by itself"
    fi
    # Only now: the responder and the polling above would take each other's replies.
    start_responder
fi

echo "SIM          : $(describe_sim)"
echo "Signal       : $(describe_signal)"
echo "Network      : $(describe_registration)"
echo "Packet data  : $(is_attached "$MODEM_INFO" && echo attached || echo "not attached")"
echo "Service      : $(sed -n 's/^+ZPAS: *//p' <<<"$MODEM_INFO" | tr -d '"' | head -1)"
sed -n 's/^+COPS: *[0-9]*,[0-9]*,"\([^"]*\)".*/Operator     : \1/p' <<<"$MODEM_INFO" | head -1

if ((PROBE_ONLY)); then
    echo
    echo "--- AT log ---"
    grep -E ' (>>|<<) ' "$LOG"
    echo
    echo "Data port    : $PORT"
    echo "Log          : $LOG"
    exit 0
fi

pick_ppp_unit
set_state DIALING
start_pppd
open_screen

while kill -0 "$PPPD_PID" 2>/dev/null; do
    update_state
    sample_traffic
    if ((DASHBOARD)); then
        draw_screen
    elif [[ $STATE == CONNECTED ]] && ((SECONDS % 10 == 0)); then
        log "traffic: in $(human "$RX") ($(human "$RX_RATE")/s), out $(human "$TX") ($(human "$TX_RATE")/s)"
    fi
    sleep 1
done

wait "$PPPD_PID"
PPP_STATUS=$?
PPPD_PID=""
ENDED_AT=$SECONDS
sleep 0.5
update_state
log "pppd exited with status $PPP_STATUS"
if ((CONNECTED_AT > 0)); then
    set_state ENDED
else
    set_state FAILED
fi
exit "$PPP_STATUS"
