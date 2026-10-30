
## REA

The `rea` MCP server is your reverse-engineering toolkit; the CLI is `rea`
(for example, `rea doctor --json`).

Ghidra 12.1 is at `$GHIDRA_INSTALL_DIR` (`/opt/ghidra`), and JDK 21 is at
`$JAVA_HOME` (`/opt/jdk`). Hopper and IDA are not installed.

Browser observation only makes sense with `SBX_NET=open`. Start Chromium
yourself, bound to loopback, with its own throw-away profile:

```bash
chromium-browser --headless=new --no-sandbox --proxy-server="$HTTPS_PROXY" \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 \
  --user-data-dir=/tmp/rea-browser --password-store=basic \
  --disable-background-networking --disable-component-update --no-first-run <url>
```

The two `--disable-*` flags stop background and component-update traffic, and
`--no-first-run` only skips the first-run setup. `--no-sandbox` is needed
because the container has no privileges for Chromium's own sandbox.

### Runtime analysis

Frida (`rea instrument-with-frida`, `rea list-frida-*`) and process capture
(`rea capture-process`) run the target inside the sandbox (the container, or
the microVM in vm mode) without extra privileges. Use them only when the
operator asked for runtime analysis.

REA uses mitmdump 12.2.3 (`$REA_MITMDUMP_COMMAND`) to decode `.mitm` captures.
The sandbox has no direct network. For a live capture, run mitmdump yourself
as an upstream proxy writing a `.mitm` capture (`-w`); upstream mode keeps
the egress proxy, and with it the network policy, in the path:

```bash
"$REA_MITMDUMP_COMMAND" --listen-host 127.0.0.1 -p 8080 \
  --mode "upstream:$HTTPS_PROXY" -w /lab/out/session.mitm
```

A target inherits `$HTTPS_PROXY`, `$HTTP_PROXY`, and their lowercase forms;
any of them sends it to the egress proxy, bypassing mitmdump, so the target's
proxy settings must point at `http://127.0.0.1:8080`. mitmdump creates its CA
in `~/.mitmproxy`; the root filesystem is read-only, so the system trust store
cannot be changed. Node.js targets trust that CA only when
`NODE_EXTRA_CA_CERTS=~/.mitmproxy/mitmproxy-ca-cert.pem` is set; other
clients need their own CA option.
