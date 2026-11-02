#!/usr/bin/env python3
"""sendsms.py - send an SMS through a USB modem and show the AT log.

  sudo ./sendsms.py +998901234567 "Hello"
  echo "Hello" | sudo ./sendsms.py +998901234567
  ./sendsms.py --dry-run +998901234567 "Привет"     Show the PDUs, send nothing

Uses PDU mode, so any language works and long messages are split into parts.
The session log is kept in ./logs next to this script.

The modem's AT ports must be free, so hang up a dialup.sh session first: its
ZOPERTE responder reads the same port and would take the modem's replies.
This script answers the modem's +ZOPERTER challenges itself while it runs.
"""
import argparse
import getpass
import glob
import importlib.util
import os
import random
import re
import select
import shutil
import signal
import subprocess
import sys
import termios
import time

GSM7_BASIC = (
    "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\x1bÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?"
    "¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
)
GSM7_EXTENDED = {"\f": 0x0A, "^": 0x14, "{": 0x28, "}": 0x29, "\\": 0x2F,
                 "[": 0x3C, "~": 0x3D, "]": 0x3E, "|": 0x40, "€": 0x65}
GSM7_ESCAPE = 0x1B
GSM7_CODES = {c: i for i, c in enumerate(GSM7_BASIC) if i != GSM7_ESCAPE}

SINGLE_GSM7, PART_GSM7 = 160, 153    # septets
SINGLE_UCS2, PART_UCS2 = 70, 67      # 16-bit units
MAX_PARTS_DEFAULT = 10

CMS_ERRORS = {
    "21": "the network rejected the message",
    "28": "unknown recipient number",
    "38": "the network is out of order",
    "41": "temporary network failure",
    "42": "the network is congested",
    "50": "SMS is not allowed for this SIM",
    "69": "the network does not support this",
    "330": "the SMS centre number is unknown",
    "331": "no network service",
    "332": "the network timed out",
}


class SmsError(Exception):
    pass


# --- PDU encoding ------------------------------------------------------------

def gsm7_septets(text):
    """The text as GSM 7-bit codes, or None if it needs UCS-2. Keeps each
    character's codes together so that a split never breaks an escape pair."""
    chars = []
    for c in text:
        if c in GSM7_CODES:
            chars.append([GSM7_CODES[c]])
        elif c in GSM7_EXTENDED:
            chars.append([GSM7_ESCAPE, GSM7_EXTENDED[c]])
        else:
            return None
    return chars


def pack_septets(septets, fill_bits=0):
    acc, bits, out = 0, fill_bits, bytearray()
    for s in septets:
        acc |= s << bits
        bits += 7
        while bits >= 8:
            out.append(acc & 0xFF)
            acc >>= 8
            bits -= 8
    if bits:
        out.append(acc & 0xFF)
    return bytes(out)


def split_units(units, single, part):
    """Splits a list of characters, each a list of units, into message parts."""
    if sum(len(u) for u in units) <= single:
        return [units]
    parts, current, used = [], [], 0
    for unit in units:
        if used + len(unit) > part:
            parts.append(current)
            current, used = [], 0
        current.append(unit)
        used += len(unit)
    parts.append(current)
    return parts


def encode_address(number):
    digits = number.lstrip("+")
    kind = 0x91 if number.startswith("+") else 0x81
    padded = digits + ("F" if len(digits) % 2 else "")
    swapped = "".join(padded[i + 1] + padded[i] for i in range(0, len(padded), 2))
    return len(digits), kind, bytes.fromhex(swapped)


def encode_smsc(number):
    if not number:
        return b"\x00"    # use the SMS centre stored on the SIM
    _, kind, swapped = encode_address(number)
    return bytes([len(swapped) + 1, kind]) + swapped


def build_pdus(number, text, smsc=None):
    """Returns (pdu_hex, tpdu_length, encoding) for each part of the message."""
    gsm = gsm7_septets(text)
    if gsm is not None:
        parts = split_units(gsm, SINGLE_GSM7, PART_GSM7)
        encoding = "GSM 7-bit"
    else:
        units = []
        for c in text:
            raw = c.encode("utf-16-be")
            units.append([raw[i:i + 2] for i in range(0, len(raw), 2)])
        parts = split_units(units, SINGLE_UCS2, PART_UCS2)
        encoding = "UCS-2"

    reference = random.randrange(256)
    da_len, da_kind, da = encode_address(number)
    result = []
    for index, part in enumerate(parts, 1):
        flat = [u for char in part for u in char]
        udh = b""
        if len(parts) > 1:
            udh = bytes([5, 0, 3, reference, len(parts), index])
        if gsm is not None:
            if udh:
                # The 6-byte header takes 7 septets plus one fill bit.
                body = udh + pack_septets(flat, fill_bits=1)
                udl = 7 + len(flat)
            else:
                body = pack_septets(flat)
                udl = len(flat)
            dcs = 0x00
        else:
            body = udh + b"".join(flat)
            udl = len(body)
            dcs = 0x08
        first = 0x01 | (0x40 if udh else 0)
        tpdu = bytes([first, 0, da_len, da_kind]) + da + bytes([0, dcs, udl]) + body
        result.append(((encode_smsc(smsc) + tpdu).hex().upper(), len(tpdu), encoding))
    return result


# --- modem -------------------------------------------------------------------

class Log:
    def __init__(self, path):
        self.path = path
        self.file = open(path, "a", buffering=1) if path else None

    def __call__(self, line):
        stamped = time.strftime("%H:%M:%S ") + line
        print(stamped, flush=True)
        if self.file:
            self.file.write(stamped + "\n")


class Modem:
    TERMINAL = re.compile(r"^(OK|ERROR|NO CARRIER|\+CM[ES] ERROR.*)$")
    CHALLENGE = re.compile(r"\+ZOPERTER:\s*(\d+),([0-9A-Fa-f]{16})")

    def __init__(self, port, log, answer_for=None):
        self.port, self.log = port, log
        self.answer_for = answer_for
        self.challenges = []
        self.buffer = b""
        self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        t = termios.tcgetattr(self.fd)
        t[0] = 0
        t[1] = 0
        t[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        t[3] = 0
        t[6][termios.VMIN] = 0
        t[6][termios.VTIME] = 0
        # USB modem drivers ignore some of these settings, which does no harm.
        termios.tcsetattr(self.fd, termios.TCSANOW, t)
        # Opening the port raises DTR, give the modem a moment to react to it.
        time.sleep(0.5)
        termios.tcflush(self.fd, termios.TCIOFLUSH)

    def close(self):
        os.close(self.fd)

    def _write(self, data):
        view = data
        while view:
            try:
                view = view[os.write(self.fd, view):]
            except BlockingIOError:
                select.select([], [self.fd], [], 0.1)

    def _fill(self, wait):
        ready, _, _ = select.select([self.fd], [], [], wait)
        if ready:
            try:
                self.buffer += os.read(self.fd, 4096)
            except BlockingIOError:
                pass

    def _next_line(self, deadline):
        while True:
            if b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                return line.replace(b"\r", b"").decode("latin-1")
            left = deadline - time.time()
            if left <= 0:
                return None
            self._fill(left)

    def command(self, cmd, timeout=3, show=None):
        """Sends a command and returns its reply lines, last one terminal.
        Returns [] when the modem does not answer in time."""
        self.log(f"{self.port} >> {show or cmd}")
        self._write(cmd.encode() + b"\r")
        reply = self._read_reply(cmd, timeout)
        self.answer_challenges()
        return reply

    def note_challenge(self, line):
        """Queues a +ZOPERTER challenge. Writing to the port while a command is
        running could abort it, or end up inside an SMS, so it is answered later."""
        match = self.CHALLENGE.search(line)
        if match and self.answer_for:
            self.challenges.append((int(match.group(1)), match.group(2).upper()))
        return bool(match)

    def answer_challenges(self):
        while self.challenges:
            index, nonce = self.challenges.pop(0)
            cmd = f"AT+ZOPERTE={index + 1},{self.answer_for(nonce)}"
            self.log(f"{self.port} >> {cmd}")
            self._write(cmd.encode() + b"\r")
            verdict = first_match(r"\+ZOPERTE:\s*\d+,(\d+)", self._read_reply(cmd, 3))
            if verdict is None:
                self.log("ZOPERTE: no verdict from the modem")
            else:
                self.log("ZOPERTE: " + ("accepted" if verdict.group(1) == "1" else "REJECTED"))

    def _read_reply(self, echo, timeout):
        reply, deadline = [], time.time() + timeout
        while True:
            line = self._next_line(deadline)
            if line is None:
                self.log(f"{self.port} << (no reply)")
                return []
            if not line.strip() or line == echo:
                continue
            self.log(f"{self.port} << {line}")
            if self.note_challenge(line):
                continue
            reply.append(line)
            if self.TERMINAL.match(line):
                return reply

    def answers_at(self):
        # A stale NO CARRIER can greet the first AT, which is then dropped.
        for _ in range(3):
            reply = self.command("AT")
            if not reply:
                return False
            if reply[-1] == "OK":
                return True
        return False

    def wait_prompt(self, timeout):
        """Waits for the "> " prompt, which has no line ending."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if b">" in self.buffer:
                before, self.buffer = self.buffer.split(b">", 1)
                for line in before.decode("latin-1").split("\n"):
                    line = line.strip()
                    if line:
                        self.log(f"{self.port} << {line}")
                        self.note_challenge(line)
                self.log(f"{self.port} << >")
                return before.decode("latin-1")
            if b"ERROR" in self.buffer and b"\n" in self.buffer.split(b"ERROR", 1)[1]:
                return None
            self._fill(0.2)
        return None

    def send_pdu(self, pdu, tpdu_length):
        """Runs one AT+CMGS exchange and returns the message reference."""
        cmd = f"AT+CMGS={tpdu_length}"
        self.log(f"{self.port} >> {cmd}")
        self._write(cmd.encode() + b"\r")
        if self.wait_prompt(10) is None:
            reply = self._read_reply(cmd, 1)
            self.answer_challenges()
            raise SmsError(f"the modem refused to take the message: {describe(reply)}")
        self.log(f"{self.port} >> {pdu}<Ctrl-Z>")
        self._write(pdu.encode() + b"\x1a")
        # The network can take a while. There is no retry after this point,
        # because a lost reply does not mean the message was not sent.
        reply = self._read_reply(pdu, 90)
        self.answer_challenges()
        if not reply:
            raise SmsError("no reply from the modem, the message may or may not have gone out")
        if reply[-1] != "OK":
            raise SmsError(describe(reply))
        for line in reply:
            match = re.match(r"\+CMGS:\s*(\d+)", line)
            if match:
                return match.group(1)
        return "?"


def describe(reply):
    if not reply:
        return "no reply"
    last = reply[-1]
    match = re.match(r"\+CMS ERROR:\s*(\d+)", last)
    if match and match.group(1) in CMS_ERRORS:
        return f"{last} ({CMS_ERRORS[match.group(1)]})"
    return last


def first_match(pattern, reply):
    for line in reply:
        match = re.match(pattern, line)
        if match:
            return match
    return None


def wait_for_sim(modem, timeout=40):
    deadline = time.time() + timeout
    while True:
        reply = modem.command("AT+CPIN?")
        joined = " ".join(reply)
        if "READY" in joined:
            return
        if "SIM PIN" in joined:
            enter_pin(modem)
            time.sleep(3)
        elif "busy" not in joined.lower():
            raise SmsError(f"the SIM is not ready: {describe(reply)}")
        if time.time() > deadline:
            raise SmsError("the SIM did not get ready in time")
        time.sleep(2)


def enter_pin(modem):
    # A wrong PIN uses up one of the SIM's attempts, so it is asked for only once
    # per run, and an option or a file can never supply it.
    if getattr(modem, "pin_tried", False):
        raise SmsError("the SIM still wants a PIN")
    modem.pin_tried = True
    if not sys.stdin.isatty():
        raise SmsError("the SIM needs a PIN, run this from a terminal without piping")
    pin = getpass.getpass("SIM PIN: ")
    if not re.fullmatch(r"[0-9]{4,8}", pin):
        raise SmsError("a PIN is 4 to 8 digits")
    reply = modem.command(f"AT+CPIN={pin}", show="AT+CPIN=****")
    if not reply or reply[-1] != "OK":
        raise SmsError(f"the modem rejected the PIN: {describe(reply)}")


def wait_for_network(modem, timeout=90):
    deadline = time.time() + timeout
    while True:
        match = first_match(r"\+CREG:\s*\d+,(\d+)", modem.command("AT+CREG?"))
        code = match.group(1) if match else ""
        if code in ("1", "5"):
            return
        if code == "3":
            raise SmsError("the network denied registration for this SIM")
        if time.time() > deadline:
            raise SmsError(f"not registered on a network after {timeout} seconds")
        time.sleep(3)


def candidate_ports():
    ports = sorted(glob.glob("/dev/ttyUSB*")) + sorted(glob.glob("/dev/ttyACM*"))
    return [p for p in ports if os.path.exists(p)]


def ports_in_use(ports):
    if not shutil.which("fuser"):
        return []
    busy = []
    for port in ports:
        result = subprocess.run(["fuser", port], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True)
        if result.stdout.strip():
            busy.append(port)
    return busy


def load_answer_function(path, log):
    """Takes the ZOPERTE answer calculation from the responder script. The send can
    still go ahead without it, the modem's challenges just stay unanswered."""
    sys.dont_write_bytecode = True    # no root-owned __pycache__ in this folder
    try:
        spec = importlib.util.spec_from_file_location("zopert_responder", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.answer_for
    except (OSError, ImportError, AttributeError, SyntaxError) as error:
        log(f"ZOPERTE challenges will NOT be answered: cannot load {path}: {error}")
        return None


def open_modem(requested, log, answer_for):
    for port in [requested] if requested else candidate_ports():
        try:
            modem = Modem(port, log, answer_for)
        except OSError as error:
            log(f"{port}: cannot open: {error}")
            continue
        if modem.answers_at():
            return modem
        modem.close()
    raise SmsError("no modem port answers AT commands. Replug the modem, wait 20 seconds, try again")


# ModemManager opens the same ports and would fight over them.
def stop_modemmanager(log):
    if subprocess.run(["systemctl", "is-active", "--quiet", "ModemManager"],
                      stderr=subprocess.DEVNULL).returncode != 0:
        return False
    log("stopping ModemManager while the modem is in use")
    if subprocess.run(["systemctl", "stop", "ModemManager"]).returncode != 0:
        return False
    time.sleep(2)
    return True


def send(args, pdus, log):
    restart_mm = stop_modemmanager(log) if shutil.which("systemctl") else False
    modem = None
    try:
        ports = [args.port] if args.port else candidate_ports()
        busy = ports_in_use(ports)
        if busy:
            raise SmsError(f"{', '.join(busy)} in use, hang up any dialup.sh session and try again")
        answer_for = load_answer_function(args.responder, log) if args.zopert else None
        modem = open_modem(args.port, log, answer_for)
        modem.command("ATE0")
        modem.command("AT+CMEE=2")
        wait_for_sim(modem)
        wait_for_network(modem)
        reply = modem.command("AT+CMGF=0")
        if not reply or reply[-1] != "OK":
            raise SmsError(f"the modem refused PDU mode: {describe(reply)}")
        if not args.smsc:
            reply = modem.command("AT+CSCA?", timeout=5)
            if not first_match(r'\+CSCA:\s*"[^"]+"', reply):
                raise SmsError("the SIM has no SMS centre number, name one with --smsc")
        for index, (pdu, length, _) in enumerate(pdus, 1):
            log(f"sending part {index} of {len(pdus)}")
            try:
                reference = modem.send_pdu(pdu, length)
            except SmsError as error:
                done = f" ({index - 1} of {len(pdus)} parts went out)" if index > 1 else ""
                raise SmsError(f"{error}{done}")
            log(f"part {index} of {len(pdus)} accepted by the network, reference {reference}")
    finally:
        if modem:
            modem.close()
        if restart_mm:
            log("restarting ModemManager")
            subprocess.run(["systemctl", "start", "ModemManager"])


def parse_args():
    parser = argparse.ArgumentParser(description="Send an SMS through a USB modem.")
    parser.add_argument("number", help="recipient, e.g. +998901234567")
    parser.add_argument("text", nargs="?", help="message text (default: read from stdin)")
    parser.add_argument("--port", help="AT port, e.g. /dev/ttyUSB1 (default: auto-detect)")
    parser.add_argument("--smsc", help="SMS centre number (default: the one on the SIM)")
    parser.add_argument("--responder", help="ZOPERTE responder script (default: %(default)s)",
                        default=os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                              "zopert_responder.py")))
    parser.add_argument("--no-zopert", dest="zopert", action="store_false",
                        help="do not answer +ZOPERTER challenges")
    parser.add_argument("--max-parts", type=int, default=MAX_PARTS_DEFAULT,
                        help="refuse longer messages, each part is billed (default: %(default)s)")
    parser.add_argument("--dry-run", action="store_true", help="show the PDUs, send nothing")
    return parser.parse_args()


def main():
    sys.stdout.reconfigure(line_buffering=True)
    args = parse_args()
    for label, number in (("number", args.number), ("SMS centre", args.smsc)):
        if number and not re.fullmatch(r"\+?[0-9]{3,20}", number):
            sys.exit(f"sendsms: invalid {label}: {number}")
    if args.port and not os.path.exists(args.port):
        sys.exit(f"sendsms: no such port: {args.port}")

    if not args.dry_run and os.geteuid() != 0:
        print("sendsms: root is needed for the modem ports, asking sudo...")
        script = os.path.abspath(__file__)
        os.execvp("sudo", ["sudo", sys.executable, script] + sys.argv[1:])

    # sudo may leave a plain C locale, the text is UTF-8 whatever it says.
    if args.text is not None:
        text = os.fsencode(args.text).decode("utf-8", "replace")
    else:
        text = sys.stdin.buffer.read().decode("utf-8", "replace").rstrip("\r\n")
    if not text:
        sys.exit("sendsms: the message is empty")

    pdus = build_pdus(args.number, text, args.smsc)
    if len(pdus) > args.max_parts:
        sys.exit(f"sendsms: the message needs {len(pdus)} parts, more than --max-parts {args.max_parts}")
    print(f"To       : {args.number}")
    print(f"Encoding : {pdus[0][2]}")
    print(f"Parts    : {len(pdus)}")

    if args.dry_run:
        for index, (pdu, length, _) in enumerate(pdus, 1):
            print(f"Part {index}   : AT+CMGS={length}  {pdu}")
        return 0

    log_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, time.strftime("sms-%Y%m%d-%H%M%S.log"))
    log = Log(log_path)
    if os.environ.get("SUDO_UID"):
        os.chown(log_path, int(os.environ["SUDO_UID"]), -1)

    def stop(signum, frame):
        raise SmsError("stopped")
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)

    try:
        send(args, pdus, log)
    except SmsError as error:
        print(f"\nFAILED: {error}\nLog: {log_path}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print(f"\nStopped. Parts already handed to the modem may have gone out.\nLog: {log_path}", file=sys.stderr)
        return 130
    print(f"\nThe network accepted {len(pdus)} of {len(pdus)} parts, delivery to the phone can take a while.\nLog: {log_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
