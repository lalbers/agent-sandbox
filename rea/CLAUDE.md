
## REA

- The `rea` MCP server is your reverse-engineering toolkit; the CLI is also
  available as `rea` (e.g. `rea doctor --json`).
- Ghidra 12.1: `$GHIDRA_INSTALL_DIR` (/opt/ghidra), JDK 21: `$JAVA_HOME`
  (/opt/jdk). Hopper and IDA are not installed.
- Browser observation only makes sense with `SBX_NET=open`. Start Chromium
  yourself, bound to loopback, with its own throw-away profile:
  `chromium-browser --headless=new --no-sandbox --proxy-server="$HTTPS_PROXY"
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222
  --user-data-dir=/tmp/rea-browser --password-store=basic <url>`
  (`--no-sandbox` because the container already is the sandbox and has no
  privileges for Chromium's own one).
