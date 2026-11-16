---
name: html-visualization
description: Build, revise, and evaluate browser-rendered HTML visualizations for concepts, systems, codebases, architectures, workflows, timelines, comparisons, and other relationship-heavy explanations. Use to create or improve an HTML/CSS/JS diagram, process map, interactive explainer, or visual documentation, checking each render with T3 Code's HTML preview.
---

# HTML Visualizations

Build the visualization in code, render it in a real browser, and judge it from screenshots. Prefer pedagogical clarity over marketing polish.

## Plan

- Name the audience and the main questions the visualization must answer. That answer is your stop rule.
- Inspect the source material or code first so the diagram reflects the real implementation.
- Pick the simplest structure that fits the relationships. Identify the content model before adding visual detail.
- Use HTML/CSS for layout; reach for SVG or canvas only when connectors, geometry, or density demand it. Add interaction only when the core explanation can't stand without it.

## Build and check

Write a self-contained HTML file: inline `<style>` and `<script>`. CDN
libraries load as-is, and local images given as absolute paths are inlined.

- Check every draft with `html_preview` on the file path. Set `width` to what
  the reader will see: the default thread column, up to 1600 for a standalone
  page, or about 390 for phones. Check both `appearance` values if the reader
  could see either. It returns a screenshot, the content height, console
  messages, and images that failed to load.
- When the explanation depends on interaction, serve the directory over HTTP
  (preview tabs only open http(s) URLs) and open it with `preview_open`, passing
  the port as the target. Drive it with `preview_act` and inspect it with
  `preview_snapshot`.
- When the visualization is for this thread, show the finished page with
  `html_render`. Its theme and layout rules apply only to pages shown inline.

## Critique and iterate

Check accuracy, reading path, clipping or overlap, legibility, scrolling, contrast, and color-independent meaning. Fix the largest defect and re-screenshot. Stop when the visualization answers the target question with no meaningful defect.

When done, close any preview tab you opened and stop any server you started. Then report the HTML location, what you verified, and any known limitations.
