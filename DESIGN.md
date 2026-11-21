---
name: HomeProxy for LuCI
description: Sing-box proxy management for OpenWrt — a quiet, precise control console.
colors:
  signal-green: "#1f8a4c"
  signal-green-soft: "#2eb872"
  signal-green-mint: "#e8f5e9"
  signal-green-deep: "#2d6d2d"
  brand-blue: "#2b5bd7"
  brand-blue-bright: "#4a7dff"
  fault-red: "#d9534f"
  fault-red-soft: "#e4574c"
  fault-red-text: "#c5221f"
  fault-red-urgency: "#ff4d35"
  caution-amber: "#e08a1e"
  caution-amber-text: "#b06a00"
  neutral-white: "#ffffff"
  neutral-wash: "#fafbfc"
  neutral-panel: "#f4f6f9"
  neutral-inset: "#e9edf2"
  neutral-line: "#eee"
  neutral-line-soft: "#f0f0f0"
  text-strong: "#2c3138"
  text-body: "#5a6470"
  text-muted: "#6b7683"
  text-faint: "#b0b7bf"
  text-dim: "#8a949e"
typography:
  display:
    fontFamily: "inherit"
    fontSize: "20px"
    fontWeight: 600
    lineHeight: 1.2
  title:
    fontFamily: "inherit"
    fontSize: "16px"
    fontWeight: 700
    lineHeight: 1.3
  body:
    fontFamily: "inherit"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "inherit"
    fontSize: "12.5px"
    fontWeight: 600
    lineHeight: 1.4
    letterSpacing: ".3px"
rounded:
  tag: "4px"
  card-sm: "6px"
  card: "8px"
  pill: "10px"
  circle: "50%"
spacing:
  xs: "3px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "18px"
components:
  score-card:
    backgroundColor: "{colors.neutral-white}"
    rounded: "{rounded.card}"
    padding: "0"
  score-kv-value:
    textColor: "{colors.text-strong}"
    typography: "{typography.body}"
    height: "18px"
  score-badge:
    backgroundColor: "{colors.signal-green-mint}"
    textColor: "{colors.signal-green-deep}"
    rounded: "{rounded.pill}"
    padding: "2px 10px"
  chip-manual:
    backgroundColor: "{colors.brand-blue}"
    textColor: "{colors.neutral-white}"
    rounded: "{rounded.tag}"
    padding: "1px 8px"
  dot-ok:
    backgroundColor: "{colors.signal-green-soft}"
    rounded: "{rounded.circle}"
    size: "8px"
  dot-bad:
    backgroundColor: "{colors.fault-red-soft}"
    rounded: "{rounded.circle}"
    size: "8px"
---

# Design System: HomeProxy for LuCI

## Overview

**Creative North Star: "The Quiet Console"**

HomeProxy is an OpenWrt proxy management plugin, and its interface is a control console first: a person comes here to read status, compare latency and loss, switch a node or a policy group, and leave. The visual system therefore optimizes for scanability, legibility of numbers, and calm restraint. It is not a marketing surface and never performs. Density is high by necessity (dozens of nodes, rule sets, log lines) but the surface stays quiet: whitespace is structural, not decorative, and color appears only when it carries meaning.

The palette is a semantic instrument. Green means good (best score, healthy node, success); red means fault (failed probe, degraded node, danger); amber means caution (auto/manual switch tags, warnings); blue is the LuCI interaction and manual-selection color. A color is never chosen for decoration — if a region is tinted, it is saying something. Neutrals do the structural work: white cards float on wash-gray panels, and a small, carefully stepped gray text ramp keeps long lists readable.

Craft shows up as precision, not ornament. Cards sit on a single soft ambient shadow with 6–8px corners; numbers are the loudest element in a row and are always set in a tabular, right-context position so a column of them can be compared at a glance. Everything else — labels, metadata, thresholds — recedes to supporting gray. The result reads like a well-made network instrument: nothing you don't need, nothing missing where you do.

**Key Characteristics:**
- Semantic-only color: green/red/amber/blue each mean one thing.
- Flat surfaces with one soft ambient shadow; 6–8px radii; 10px pill badges.
- Number-first hierarchy: values bold and centered, labels muted and small.
- LuCI-native: inherits the surrounding theme's fonts and controls, adds only the custom console widgets.
- Restraint over expression — density without noise.

## Colors

A semantic signal palette on a quiet gray-and-white structural base: color is instrumentation, never decoration.

### Primary
- **Signal Green** (#1f8a4c): The dominant meaning color. Used for the best score, healthy state, success text, the score column, and the "View all" affordance. Its mint companion **Signal Green Mint** (#e8f5e9) fills the "Scoring"/status pill background, and **Signal Green Deep** (#2d6d2d) is its readable text pair. **Signal Green Soft** (#2eb872) is the live "ok" status dot.

### Secondary
- **Brand Blue** (#2b5bd7): The interaction/primary-action color. It marks interactive controls and the manual-selection semantic — "manual" chips and LuCI action buttons both draw from it. Execution-type buttons that are merely repeatable actions (check / update / download) may sit as neutral outlined buttons so that blue stays a scarce "act now" signal. **Brand Blue Bright** (#4a7dff) is its soft fallback (`var(--primary, #4a7dff)`) when a theme token is absent.

### Tertiary
- **Caution Amber** (#e08a1e): Reserved for "caution/auto" state — auto-selection tags and non-fatal warnings. **Caution Amber Text** (#b06a00) is its legible text pair.

### Neutral
- **Pure White** (#ffffff): card and table surface; the base every console widget floats on.
- **Wash Gray** (#fafbfc): table header and section title background — the faintest structural tint.
- **Panel Gray** (#f4f6f9) and **Inset Gray** (#e9edf2): nested panels, icon wells, and inset info blocks.
- **Hairline** (#eee, #f0f0f0): 1px dividers and card borders; the only borders in the system.
- **Text Strong** (#2c3138): metric values and headings.
- **Text Body** (#5a6470): table cell content (latency, loss, speed).
- **Text Muted** (#6b7683): labels, column headers, secondary metadata — darkened from #9aa3ad to reach WCAG AA 4.5:1 on white.
- **Text Faint** (#b0b7bf) and **Text Dim** (#8a949e): rank numbers, footer, least-important hints.

### Named Rules
**The Signal-Only Rule.** A color appears only when it encodes state — good, fault, caution, or manual. There is no decorative tint. If a region is colored, it is saying something.

**The Fault Red Rule.** Fault Red (#d9534f / #e4574c) is forbidden as decoration or accent. It means a failed probe, a degraded node, or a danger action, and nothing else.

## Typography

**Display Font:** inherits the LuCI theme font stack (no custom web font shipped).
**Body Font:** same stack; the console adds no typeface of its own.

**Character:** LuCI-native and invisible — the console never introduces a brand font, so it feels part of the router's administration UI. Hierarchy is carried by size and weight, not by family contrast.

### Hierarchy
- **Display** (600, 20px, 1.2): the current-series / hero metrics (e.g. the score value).
- **Title** (700, 16px, 1.3): card titles and group headers.
- **Body** (400, 14px, 1.5): table cells and primary content.
- **Label** (600, 12.5px, .3px letter-spacing): column headers, metadata, stat lines. Often paired with a muted color.

### Named Rules
**The Number-First Rule.** In any metric row, the value is the largest and boldest thing; its label is small, muted, and sits above it. A column of values must scan vertically without reading the labels.

## Layout

A centered, single-column console: the score grid is capped at 860px and centered (`max-width: 860px; margin: 0 auto`), so wide router screens do not spread dense data into unreadable spans. Inside a card, a fixed-grid `kv` strip lays out the metric columns (`40px · 1fr · 116px · 68px · 112px · 74px · 64px`) with a `1fr` node column absorbing slack and fixed px columns pinning the numeric fields, so header and data stay vertically aligned. Connection cards use `repeat(auto-fit, minmax(210px, 1fr))` and reflow to fewer columns on narrow screens. Tables are `table-layout: fixed` with per-column px widths and `white-space: nowrap` on numeric cells, so values never wrap mid-figure.

Spacing rhythm is tight and structural: 3px inside stacked label/value pairs, 8px card inner gaps, 12px grid gaps, 16–18px card padding. Responsive behavior is fluid (auto-fit grids) rather than breakpoint-switched, letting dense tables scroll within their own container instead of collapsing.

## Elevation & Depth

Flat by default, one ambient layer. Surfaces are flat at rest; a single soft shadow (`0 1px 4px rgba(0, 0, 0, .08)`) lifts cards off the wash-gray page, and depth beyond that is conveyed tonally through the neutral steps (#fafbfc → #f4f6f9 → #e9edf2) rather than by stacking shadows. There are no raised buttons, no inset shadows, no multi-layer elevation.

### Named Rules
**The Single-Shadow Rule.** Exactly one ambient shadow exists (`0 1px 4px rgba(0,0,0,.08)`). Do not add a second elevation level, a colored glow, or a drop shadow on hover — state changes are expressed with color and border, not with elevation.

## Shapes

Gently curved, restrained. Cards take an 8px radius, small tiles and icon wells 6px, tags a crisp 4px, and status pills / chips a 10px capsule; the "ok / bad / none" indicators are 8px circles. Borders are always 1px hairlines (#eee / #f0f0f0 / #eef0f2) used as separators, never as heavy framing. The form language is rectangular-with-soft-corners — no fully-rounded cards, no sharp 0px corners, no geometric flourishes.

## Components

Precise and understated: soft-cornered cards, hairline dividers, numbers doing the talking.

### Buttons
- **Shape:** follow the LuCI theme buttons (`cbi-button` variants) rather than defining new ones; the console adds only semantic callout links.
- **Primary / action:** LuCI theme default — inherits radius, padding, and hover from the surrounding theme so the plugin never looks foreign.
- **Text link (in-card):** "View all ↗" style — Signal Green (#1f8a4c), 600 weight, cursor pointer; the one interactive affordance inside a score card.

### Chips
- **Style:** capsule, 10px radius, 1px 8px padding.
- **Semantic variants:** auto → Caution Amber tint (`rgba(176,106,0,.14)` bg, #b06a00 text); manual → Brand Blue tint (`rgba(43,91,215,.12)` bg, #2b5bd7 text); status/scoring pill → Signal Green Mint bg with #2d6d2d text.

### Cards / Containers
- **Corner Style:** 8px radius (6px for small tiles).
- **Background:** Pure White on the page wash.
- **Shadow Strategy:** the single ambient shadow (see Elevation & Depth).
- **Border:** none on the card itself; 1px hairlines only between internal rows/sections.
- **Internal Padding:** 12–18px; the header strip uses a faint green-to-white gradient (`linear-gradient(90deg,#f7fbf5,#fff)`) as the card's only allowed tint.

### Inputs / Fields
- **Style:** LuCI theme fields (`cbi-input-text`, selects) — inherited, not restyled.
- **Focus:** theme default; the console does not override focus rings.

### Navigation
- **Style:** LuCI left nav + tab bar, fully inherited. The console only colors the active tab with Brand Blue (`var(--primary, #4a7dff)`) via theme variables.

### Metric Row (signature component)
The console's defining widget: a horizontal grid where each metric cell stacks a small muted label over a large bold value (Delay / Loss / Speed / Degraded / Score). The value is always centered under its label and aligned to the column above; the node-name cell is the only left-aligned, ellipsis-truncated cell. Values stay on one line (`white-space: nowrap`); the active metric (Score) uses Signal Green at 20px weight-600.

### Score / Status Table (signature component)
A `table-layout: fixed` ranked list (# / Node / Latency / Loss / Speed / Degraded / Score). Header row on Wash Gray with muted 12.5px labels; rows on white with hairline bottoms; the Score column in Signal Green bold. Failed nodes fall to the bottom and read "超时/失败". Headers and cells share the same fixed column widths so they align vertically.

## Do's and Don'ts

### Do:
- **Do** reserve green for good, red for fault, amber for caution, blue for manual/interaction — one meaning per hue.
- **Do** keep values bold and centered above/below their muted labels so numeric columns scan vertically.
- **Do** keep a single ambient shadow (`0 1px 4px rgba(0,0,0,.08)`) and 6–8px radii; use hairline dividers for separation.
- **Do** set numeric cells to `white-space: nowrap` and left-align only the node-name column.
- **Do** inherit LuCI theme fonts and form controls so the plugin reads as native router UI.

### Don't:
- **Don't** tint a surface, card, or region unless the tint encodes state — no decorative fills.
- **Don't** use gradients as page or card grounds; the one green-to-white header strip is the only exception.
- **Don't** use large blocks of saturated color or heavy drop shadows; depth is tonal + one soft shadow only.
- **Don't** use Fault Red (#d9534f) as an accent or brand color — it means fault and nothing else.
- **Don't** over-weight numbers or add a second elevation level on hover; state changes are color + border, not shadow.
