---
name: html-visualizations
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

Prefer a standalone HTML file.

```bash
playwright-cli open file:///abs/path/to/viz.html
playwright-cli resize 1440 900   # default viewport unless the user specifies one
playwright-cli screenshot --filename=/tmp/viz.png
```

Then **view `/tmp/viz.png`** for evaluation.

- `playwright-cli console` after load and after interactions to catch runtime/render errors.
- `playwright-cli snapshot` to inspect DOM structure when diagnosing a layout problem.
- Use a named session (`playwright-cli -s=html-viz ...` on every command) if another browser session may be active.
- If the browser is missing, run `playwright-cli install-browser` and retry.

## Critique and iterate

From the screenshot, check in order: (1) accuracy — entities, labels, directions, groupings are right; (2) reading path — start point, sequence, and main takeaway are immediately obvious; (3) defects — clipping, overlap, broken connectors, unreadable text, stray scrolling; (4) contrast and color-independent meaning.

Fix the biggest problem, re-screenshot the same viewport, compare. **Stop when the screenshot answers the target question with no meaningful defect**.

## Notes

- If composition is hard to explore in code (a tricky metaphor or dense layout), generate a reference image first, then translate it to HTML.
- Keep the HTML in the requested project location; `/tmp` screenshots are evaluation artifacts.
- When done, `playwright-cli close` and report where the file lives, what you visually verified, and any known limitations.
