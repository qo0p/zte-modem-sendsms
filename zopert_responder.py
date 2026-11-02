#!/usr/bin/env python3
"""Beeline/UZ ZTE MF180S keep-alive responder.

Replaces the Windows connection manager's ZOPERTE handshake:

  modem: +ZOPERTER: <k>,<16 hex nonce>
  host : AT+ZOPERTE=<k+1>,<8 hex answer>

where answer = hex(sum_bytes(w) for each of the four 32-bit words of
MD5(nonce, IV = 23 9C FA C2 38 A3 6C 9E 7D 8A 99 6C A8 74 53 8B)).

Usage:
  zopert_responder.py /dev/serial/by-id/usb-...-if01-port0
  zopert_responder.py -v /dev/ttyUSB1
  zopert_responder.py --passive /dev/ttyUSB1  only answer, never restart the cycle
  zopert_responder.py --mutual /dev/ttyUSB1   send the host's own challenge first,
                                              like the vendor app
"""
import os, sys, time, struct, math, termios, select, random, re

IV = [0x239cfac2, 0x38a36c9e, 0x7d8a996c, 0xa874538b]
S = [7,12,17,22]*4 + [5,9,14,20]*4 + [4,11,16,23]*4 + [6,10,15,21]*4
K = [int(abs(2**32 * abs(math.sin(i + 1)))) & 0xffffffff for i in range(64)]

def _rol(x, c):
    return ((x << c) | (x >> (32 - c))) & 0xffffffff

def md5_iv(data, iv=IV):
    a, b, c, d = iv
    bitlen = len(data) * 8
    data = data + b'\x80'
    while len(data) % 64 != 56:
        data += b'\x00'
    data += struct.pack('<Q', bitlen)
    for off in range(0, len(data), 64):
        M = list(struct.unpack('<16I', data[off:off + 64]))
        A, B, C, D = a, b, c, d
        for i in range(64):
            if i < 16:
                F = (B & C) | (~B & D); g = i
            elif i < 32:
                F = (D & B) | (~D & C); g = (5 * i + 1) % 16
            elif i < 48:
                F = B ^ C ^ D; g = (3 * i + 5) % 16
            else:
                F = C ^ (B | (~D & 0xffffffff)); g = (7 * i) % 16
            F = (F + A + K[i] + M[g]) & 0xffffffff
            A, D, C = D, C, B
            B = (B + _rol(F, S[i])) & 0xffffffff
        a = (a + A) & 0xffffffff
        b = (b + B) & 0xffffffff
        c = (c + C) & 0xffffffff
        d = (d + D) & 0xffffffff
    return struct.pack('<4I', a, b, c, d)

def answer_for(nonce_hex):
    dig = md5_iv(bytes.fromhex(nonce_hex))
    return ''.join("%02X" % (sum(dig[i*4:i*4+4]) & 0xff) for i in range(4))

def open_port(path, baud=115200):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    t = termios.tcgetattr(fd)
    t[0] = 0; t[1] = 0
    t[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    t[3] = 0
    t[6][termios.VMIN] = 0; t[6][termios.VTIME] = 0
    t[4] = getattr(termios, "B%d" % baud); t[5] = t[4]
    termios.tcsetattr(fd, termios.TCSANOW, t)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd

def main():
    verbose = "-v" in sys.argv
    # AT+ZOPRT=6 dropped the signal and the registration on hardware (2026-11-02).
    passive = "--passive" in sys.argv
    mutual = "--mutual" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        print(__doc__); sys.exit(1)
    port = args[0]
    fd = open_port(port)
    print("# responder on", port, flush=True)

    def send(cmd):
        if verbose: print(">>>", cmd, flush=True)
        data = (cmd + "\r").encode()
        for _ in range(50):
            try:
                os.write(fd, data)
                return
            except BlockingIOError:
                select.select([], [fd], [], 0.05)
            except OSError as e:
                print("write error:", e, flush=True)
                return

    def log(*a):
        print(time.strftime("%H:%M:%S"), *a, flush=True)

    last_cycle = 0
    buf = ""
    send("AT"); send("ATE0")
    while True:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try:
                d = os.read(fd, 4096)
            except OSError:
                time.sleep(0.5); continue
            if not d:
                continue
            buf += d.decode("latin-1", "replace")
            if verbose:
                print("<<<", d.decode("latin-1", "replace").replace("\r", "\\r").replace("\n", "\\n"), flush=True)
            m = re.search(r"\+ZOPERTER:\s*(\d+),([0-9A-Fa-f]{16})", buf)
            if m:
                idx = int(m.group(1)); nonce = m.group(2).upper()
                ans = answer_for(nonce)
                log(f"challenge {idx} nonce={nonce} -> answer {ans}")
                if mutual:
                    send("AT+ZOPERTE=0," + os.urandom(8).hex().upper())
                    time.sleep(1)
                send(f"AT+ZOPERTE={idx + 1},{ans}")
                buf = buf[m.end():]
            if len(buf) > 4096:
                buf = buf[-2048:]

        # keep the poll cycle alive: restart it if nothing happened for 4 minutes
        if not passive and time.time() - last_cycle > 240:
            send("AT+CPBS=\"SM\"")
            send("AT+ZOPRT=6")
            send("AT+ZOPRT=5")
            send("AT+ZSTART")
            last_cycle = time.time()
            log("cycle restarted (ZOPRT=6/5, ZSTART)")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
