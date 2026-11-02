# sendsms.py

Sends an SMS through a USB modem and shows the AT commands as it runs. Works in any
language, and long messages are split into parts automatically.

## Usage

```bash
sudo ./sendsms.py +998901234567 "Hello"
```

The text can also come from standard input:

```bash
echo "Hello" | sudo ./sendsms.py +998901234567
```

To see what would be sent without using the modem:

```bash
./sendsms.py --dry-run +998901234567 "Hello"
```

End any `dialup.sh` session first, because both use the same port.

## Options

| Option | What it does |
|---|---|
| `--port DEV` | AT port to use, such as `/dev/ttyUSB1` (default: auto-detect) |
| `--smsc NUMBER` | SMS centre number (default: the one on the SIM) |
| `--responder FILE` | ZOPERTE responder script (default: `zopert_responder.py` next to this script) |
| `--no-zopert` | Don't answer `+ZOPERTER` challenges |
| `--max-parts N` | Refuse messages that need more than N parts (default: 10) |
| `--dry-run` | Show the encoded message and send nothing |
