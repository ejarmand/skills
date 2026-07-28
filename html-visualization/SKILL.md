---
name: html-visualization
description: Build, revise, and evaluate browser-rendered HTML visualizations for concepts, systems, codebases, architectures, workflows, timelines, comparisons, and other relationship-heavy explanations. Use to create or improve an HTML/CSS/JS diagram, process map, interactive explainer, or visual documentation, validating the rendered result with Playwright CLI screenshots.
---

# HTML Visualizations

Build the visualization in code, render it in a real browser, and judge it from screenshots. Prefer pedagogical clarity over marketing polish.

## Plan

- Name the audience and the main questions the visualization must answer. That answer is your stop rule.
- Inspect the source material or code first so the diagram reflects the real implementation.
- Pick the simplest structure that fits the relationships. Identify the content model before adding visual detail.
- Use HTML/CSS for layout; reach for SVG or canvas only when connectors, geometry, or density demand it. Add interaction only when the core explanation can't stand without it.

## Build and render

Prefer a standalone HTML file. Serve it over HTTP because the browser daemon blocks `file://` URLs. Run this as one shell block so the variables and cleanup trap remain active:

```bash
set -e
viz_dir=/abs/dir/containing/viz
shot_dir="$(mktemp -d -t html-viz-XXXXXX)"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$viz_dir" >/dev/null 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null' EXIT
url="http://127.0.0.1:$port/viz.html"

curl --retry 5 --retry-connrefused -fsS "$url" -o /dev/null
playwright-cli -s=html-viz open --browser=chromium "$url"
playwright-cli -s=html-viz resize 1440 900
playwright-cli -s=html-viz screenshot --filename="$shot_dir/viz.png"
echo "$shot_dir/viz.png"
```

View the printed screenshot path. Re-run the block after changes, using the same viewport for comparison.

- Pass `--browser=chromium` on `open`; the default `chrome` channel is often unavailable.
- Use the named session on every command so concurrent browser sessions cannot interfere.
- Check `playwright-cli console` after load and interactions; a missing `/favicon.ico` is expected noise.
- Use `playwright-cli snapshot` when diagnosing layout or DOM structure.

## Critique and iterate

Check accuracy, reading path, clipping or overlap, legibility, scrolling, contrast, and color-independent meaning. Fix the largest defect and re-screenshot. Stop when the visualization answers the target question with no meaningful defect.

When done, close the browser session, remove the printed screenshot directory, and report the HTML location, what you verified, and any known limitations.
