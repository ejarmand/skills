---
name: html-visualizations
description: Build, revise, and evaluate browser-rendered HTML visualizations for concepts, systems, codebases, architectures, workflows, timelines, comparisons, and other relationship-heavy explanations. Use when Codex needs to create or improve an HTML/CSS/JavaScript diagram, process map, interactive explainer, or visual documentation and should validate the rendered result through an iterative Playwright CLI screenshot workflow.
---

# HTML Visualizations

Create the visualization in code, render it in a real browser, and use screenshots as the primary evaluation surface. Prioritize an accurate visual model and a tight build-render-critique loop over decorative styling.

## Workflow

### 1. Establish the communication goal

- Identify the audience, the question the visualization must answer, and the target artifact or page.
- Inspect the source material and existing code before drawing. For codebase processes, trace the relevant files and runtime path so the diagram reflects the implementation.
- Write down the entities, relationships, sequence, hierarchy, states, or comparisons that must be visible.
- Decide what successful viewing should make immediately understandable. Treat this as the acceptance criterion for iteration.

### 2. Choose the visual structure

- Select the simplest structure that expresses the relationships: flow, timeline, hierarchy, architecture map, state transition, matrix, annotated code path, or small multiple.
- Reduce the content model before adding visual detail. Group related items, name transitions, and remove relationships that do not serve the communication goal.
- Use HTML and CSS for layout and readable content. Use SVG or canvas only when connectors, geometry, or density make them materially clearer.
- Prefer a standalone HTML file for a self-contained deliverable. When working in an existing application, follow its framework, components, and development commands instead of introducing a parallel stack.

### 3. Build a complete first pass

- Implement the full explanatory path before polishing individual elements.
- Keep data and relationships explicit in the source so later revisions are easy.
- Make the visualization legible at the requested viewport. If none is specified, begin at 1440 by 900.
- Add only the interaction needed to understand the visualization. Ensure the core explanation remains visible without interaction unless the user asks otherwise.

### 4. Start the page and render it with Playwright CLI

- Start the existing development server and keep its terminal session alive. Use the project's documented command and URL; use port 3000 only when it is actually the project's port.
- Monitor the server at a task-appropriate interval and recheck its output after meaningful changes or failed page loads.
- Open the page, set the target viewport, and capture a screenshot:

```bash
playwright-cli open http://localhost:3000
playwright-cli resize 1440 900
playwright-cli screenshot --filename=/tmp/desktop.png
```

- View `/tmp/desktop.png` with the available image-viewing tool. Do not evaluate a visual artifact from source code alone.
- Use `playwright-cli snapshot` to inspect page structure and element references when needed.
- Use `playwright-cli console` after load and after interaction to catch runtime or rendering errors.
- Use a named session such as `playwright-cli -s=html-viz open ...` when another browser session may be active. Apply the same `-s` option to every command in that session.
- If the browser executable is unavailable, run `playwright-cli install-browser` and retry.

### 5. Critique the rendered result

Evaluate the screenshot against the communication goal, in this order:

1. Verify semantic accuracy: all important entities, labels, directions, groupings, and transitions are correct.
2. Verify the reading path: the starting point, sequence, hierarchy, and primary takeaway are immediately apparent.
3. Check rendering defects: clipping, overlap, broken connectors, unreadable text, unintended scrolling, and excessive empty space.
4. Check information density: split, group, or simplify sections that require too much scanning or explanation.
5. Check emphasis: confirm the most important relationships dominate secondary context.
6. Check basic accessibility: semantic text, sufficient contrast, and meaning that does not depend only on color.

Use snapshots and DOM inspection to diagnose structural problems, but treat the screenshot as the authority for visual judgment.

### 6. Iterate deliberately

- Fix the highest-impact communication or rendering problem first.
- Make a focused change, allow the page to rebuild, capture the same viewport again, and compare it with the prior screenshot.
- Repeat until the acceptance criterion is satisfied and a new screenshot no longer reveals a meaningful defect.
- Preserve viewport and content between comparison screenshots so differences reflect the code change.
- Test a second viewport when responsiveness is requested or when the artifact is likely to be viewed on a materially different screen. Capture it separately, for example:

```bash
playwright-cli resize 390 844
playwright-cli screenshot --filename=/tmp/mobile.png
```

- Use `--full-page` only as a supplemental check for long pages. Keep a viewport screenshot as the primary composition check.

### 7. Verify and hand off

- Exercise meaningful interactions with Playwright CLI and recapture the affected state.
- Confirm that the final page loads without console errors and that the server remains healthy.
- Keep the final HTML or application files in the requested project location; treat `/tmp` screenshots as evaluation artifacts, not deliverables.
- Close the browser session when evaluation is complete:

```bash
playwright-cli close
```

- Report the implementation location, what was visually verified, the viewport sizes tested, and any known limitations.

## Image Generation as a Prototype

Use image generation only when the visualization is sufficiently complicated that exploring composition in code would be inefficient, or when the rendered first pass is far from the desired result.

- Generate a prototype to explore hierarchy, grouping, spatial organization, or a difficult visual metaphor.
- Treat the generated image as a reference, not as proof that the HTML works and not as the final implementation unless the user explicitly requests a bitmap.
- Translate useful structural ideas into HTML, CSS, SVG, or canvas, then resume the Playwright screenshot loop.
- Skip image generation for ordinary flows, timelines, architecture maps, and other layouts that can be efficiently iterated in the browser.

## Completion Gate

Do not call the visualization complete until all of the following are true:

- The browser-rendered result has been inspected from at least one Playwright CLI screenshot.
- The visualization communicates the intended relationships without relying on a prose walkthrough.
- No important content is clipped, overlapped, or visually ambiguous at the target viewport.
- The underlying explanation matches the provided source material or inspected codebase.
