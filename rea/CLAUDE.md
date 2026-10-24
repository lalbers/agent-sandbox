
## REA

- The `rea` MCP server is your reverse-engineering toolkit; the CLI is also
  available as `rea` (e.g. `rea doctor --json`).
- Ghidra 12.1: `$GHIDRA_INSTALL_DIR` (/opt/ghidra), JDK 21: `$JAVA_HOME`
  (/opt/jdk). Hopper and IDA are not installed.
- Browser observation only makes sense with `SBX_NET=open`. Start Chromium
  yourself, bound to loopback, with its own throw-away profile:
  `chromium-browser --headless=new --no-sandbox --proxy-server="$HTTPS_PROXY"
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222
  --user-data-dir=/tmp/rea-browser --password-store=basic
  --disable-background-networking --disable-component-update --no-first-run <url>`
  (the last three stop Chromium's own calls to Google services)
  (`--no-sandbox` because the container already is the sandbox and has no
  privileges for Chromium's own one).

### Runtime analysis

- Frida (`rea instrument-with-frida`, `rea list-frida-*`) and process capture
  (`rea capture-process`) work in here without extra privileges. Both run the
  target inside this container: only use them when the operator asked for
  runtime analysis.
- mitmdump 12.2.3 is `$REA_MITMDUMP_COMMAND`; REA uses it to decode `.mitm`
  captures. For a live capture, chain it to the egress proxy so the network
  policy still applies, and point the target at it:
  `"$REA_MITMDUMP_COMMAND" --listen-host 127.0.0.1 -p 8080
  --mode "upstream:$HTTPS_PROXY" -w /lab/out/session.mitm`
  (its CA is created in `~/.mitmproxy`).
