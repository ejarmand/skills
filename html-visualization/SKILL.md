---
name: html-visualization
description: Build, revise, and evaluate browser-rendered HTML visualizations for concepts, systems, codebases, architectures, workflows, timelines, comparisons, and other relationship-heavy explanations. Use to create or improve an HTML/CSS/JS diagram, process map, interactive explainer, or visual documentation, validating the rendered result with Playwright CLI screenshots.
---

# HTML Visualizations

Build the visualization in code, render it in a real browser, and judge it from screenshots. Optimize for an accurate, legible visual model and a tight build-render-critique loop.

## Plan

- Name the audience and the main questions the visualization must answer. That answer is your stop rule.
- Inspect the source material or code first so the diagram reflects the real implementation.
- Pick the simplest structure that fits the relationships. Identify the content model before adding visual detail.
- Use HTML/CSS for layout; reach for SVG or canvas only when connectors, geometry, or density demand it. Add interaction only when the core explanation can't stand without it.

## Build and render

Prefer a standalone HTML file. Serve it over HTTP — `file://` URLs are blocked by the browser daemon.

Create the screenshot directory once, outside the project, and print it:

```bash
mktemp -d -t html-viz-XXXXXX
```

Each Bash call is a fresh shell, so variables do not carry over — substitute the
printed path literally wherever `SHOT_DIR` appears below, and quote it.

Then render. Bind to a free port rather than a fixed one, and fail fast if the
server did not come up or the port is serving something else:

```bash
viz_dir=/abs/dir/containing/viz
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$viz_dir" >/dev/null 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null' EXIT
url="http://127.0.0.1:$port/viz.html"

curl --retry 5 --retry-connrefused -fsS "$url" -o /dev/null ||
  { echo "no server serving $url" >&2; exit 1; }
kill -0 "$server_pid" 2>/dev/null ||
  { echo "http.server (pid $server_pid) exited" >&2; exit 1; }

playwright-cli -s=html-viz open --browser=chromium "$url"
playwright-cli -s=html-viz resize 1440 900   # default viewport unless the user specifies one
playwright-cli -s=html-viz screenshot --filename="SHOT_DIR/viz.png"
```

Then **view `SHOT_DIR/viz.png`** for evaluation.

- Run the block above as a single command: the `EXIT` trap stops the server when
  the shell ends, so the server lives exactly as long as the render pass that
  needs it. Re-run the whole block for each iteration; the browser session and
  the screenshot directory persist across passes.
- The port is chosen by binding port 0 and releasing it, so another process can
  in principle claim it first. The `curl` check is what proves *your* server is
  the one answering — treat its failure as a real error, not a race to retry
  around.
- Pass `--browser=chromium` on `open`. Without it the CLI targets the `chrome` channel, which is often not installed even though Playwright's bundled Chromium is; the daemon then dies with `Chromium distribution 'chrome' is not found`. `chromium` is a valid value despite being absent from `--help`.
- Use the named session (`-s=html-viz`) on every command so a concurrent browser session can't interfere.
- `playwright-cli console` after load and after interactions to catch runtime/render errors. A 404 for `/favicon.ico` is expected noise from the local server.
- `playwright-cli snapshot` to inspect DOM structure when diagnosing a layout problem.
- If `open` fails, check the daemon error before reinstalling anything. `playwright-cli install-browser --list` shows what is already present; a bare `install-browser` can abort on host-library validation (`libgtk-4`, gstreamer, …) that needs root, which is a separate problem from browser selection.

## Critique and iterate

From the screenshot, check in order: (1) accuracy — entities, labels, directions, groupings are right; (2) reading path — start point, sequence, and main takeaway are immediately obvious; (3) defects — clipping, overlap, broken connectors, unreadable text, stray scrolling; (4) contrast and color-independent meaning.

Fix the biggest problem, re-screenshot the same viewport, compare. **Stop when the screenshot answers the target question with no meaningful defect**.

## Notes

- If composition is hard to explore in code (a tricky metaphor or dense layout), generate a reference image first, then translate it to HTML.
- Keep the HTML in the requested project location; screenshots are evaluation artifacts and belong in the screenshot directory.
- When done, `playwright-cli -s=html-viz close` and `rm -rf "SHOT_DIR"`. The trap already stopped the server; if a render pass was interrupted before its trap ran, kill that recorded PID. Report where the file lives, what you visually verified, and any known limitations.
