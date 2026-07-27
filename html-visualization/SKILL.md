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

```bash
cd /abs/dir/containing/viz && python3 -m http.server 8731 >/dev/null 2>&1 &
playwright-cli -s=html-viz open --browser=chromium http://localhost:8731/viz.html
playwright-cli -s=html-viz resize 1440 900   # default viewport unless the user specifies one
playwright-cli -s=html-viz screenshot --filename=$SCRATCH/viz.png
```

Then **view `$SCRATCH/viz.png`** for evaluation, where `$SCRATCH` is a scratch directory outside the project.

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
- Keep the HTML in the requested project location; screenshots are evaluation artifacts and belong in the scratch directory.
- When done, `playwright-cli -s=html-viz close`, stop the HTTP server you started, and report where the file lives, what you visually verified, and any known limitations.
