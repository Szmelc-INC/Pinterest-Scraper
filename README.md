# Pinterest-Scraper
Ultimate Pinterest board &amp; media downloader scripts

---

<img width="1011" height="268" alt="image" src="https://github.com/user-attachments/assets/00b62577-1197-459b-a4d1-1dd23aacb497" />

---

### EXAMPLES:
> `./grab.sh -b chromium "https://pin.it/6zZPpPBZS" -o OUT`
```sh
grab.sh -b firefox "https://www.pinterest.com/serainox/teledysk-core/"
grab.sh -o clip "https://pin.it/xxxxxxx"
grab.sh -b firefox -L "https://www.pinterest.com/user/board/"
```

### USAGE:
> **`grab.sh [OPTIONS] <PINTEREST_URL>`**
```sh
OPTIONS:
  -o, --outdir DIR     Output folder (default: derived from the URL slug)
  -b, --browser NAME   Read cookies from a logged-in browser:
                         firefox | chromium | chrome | brave | edge | vivaldi | opera
                         (append /PROFILE if needed, e.g. firefox/default-release)
  -c, --cookies FILE   Cookie file. Accepts EITHER a Netscape cookies.txt OR a
                         browser "Copy as cURL" blob — it auto-detects and, for a
                         cURL blob, extracts the cookie header (+ user-agent) itself.
      --curl FILE      Force cURL-blob mode (paste a full "Copy as cURL" request here).
                         Handy when Chromium keyring decryption fails on -b.
  -a, --archive FILE   Resume/dedupe DB (default: <outdir>/.gdl-archive)
  -r, --range RANGE    Only fetch items in RANGE, e.g. "1-100" or "50-"
  -s, --sleep SEC      Pause between downloads (default: $SLEEP)
  -R, --retries N      Retries per file before a fallback URL is tried (default: $RETRIES)
      --no-videos      Skip videos (images/gifs only)
      --no-sections    Don't descend into board sections
      --no-stories     Skip idea/story pins
      --tree           Keep gallery-dl's user/board folder tree (default: flat)
  -k, --insecure       Skip TLS cert verification (needed behind an intercepting proxy)
  -m, --metadata       Write a .json metadata sidecar per item
  -L, --list           Preview what WOULD download — no files written
  -h, --help           This help
```
