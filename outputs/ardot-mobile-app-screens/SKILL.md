---
name: ardot-mobile-app-screens
agent_created: true
description: Use when designing iOS/Android mobile app screens in Ardot (text-to-UI / mockup generation). Covers iPhone frame setup, status bar, pill tab bar, absolute positioning on canvas, Inter typography, and reusable icon patterns so screens are consistent and buildable.
---

# Ardot Mobile App Screens

## When to use

Use this skill for any task that asks to design, mock up, or refine mobile app interfaces in Ardot, especially when producing multiple iPhone screens side-by-side on a single canvas.

## Design tokens

Use these defaults unless the user or an existing style guide overrides them.

- **Canvas**: `1600×1100`, fill `#F3F4F6`, layout `NONE` (absolute positioning).
- **Phone frame**: `402×874`, corner radius `60`, fill `#FFFFFF`, stroke `1px #E5E7EB`.
- **Phone positions** (3-up): `x=80`, `x=482`, `x=884`, `y=100`.
- **Status bar**: height `62`, transparent fill, time label centered with SF Pro fallback to Inter.
- **Bottom tab bar**: floating pill at `x=20, y=770`, `362×62`, corner radius `36`, 3–4 tabs, active tab filled with accent color.
- **Typography**: Inter family.
  - Screen title: `34px Bold`
  - Section title: `22px Bold`
  - Body/track: `15px SemiBold` / `13px Regular`
  - Tab label: `10px Medium`, uppercase, letter-spacing `0.5px`
- **Color palette**:
  - Background: `#FFFFFF`
  - Surface/secondary: `#F3F4F6`
  - Primary accent: `#6366F1`
  - Primary light: `#E0E7FF`
  - Text primary: `#111827`
  - Text secondary: `#6B7280`
  - Text tertiary: `#9CA3AF`
  - Success/downloaded: `#10B981`
  - Warning/downloading: `#F59E0B`
  - Border: `#E5E7EB`

## Workflow

1. Call `mcp__ardot__fetch_guidelines` with `topic: "mobile-app"`.
2. Create or open the Ardot design file.
3. Create the main canvas frame with `layout: "NONE"` and absolute positioning.
4. Add iPhone frames with status bar and bottom tab bar first.
5. Build each screen top-to-bottom inside its phone frame using absolute `x/y`:
   - Status bar area (y `0–62`)
   - Header / title (y `82`)
   - Primary content
   - Bottom tab bar (y `770`)
6. Keep content within `y=62` to `y=770` to avoid overlap with chrome.
7. Use `G()` placeholder frames for album covers / avatars.
8. Export the main canvas as PNG (`scale: 2`) and present.

## Critical positioning rule

If a parent frame uses auto-layout (`horizontal`/`vertical`), child `x/y` coordinates may be ignored or interpreted as offsets, causing frames to render off-canvas. For multi-screen canvases, set the parent canvas `layout: "NONE"` and position every phone frame with explicit `x` and `y`.

## Icon patterns

Prefer small inline SVG frames (`18–24px`) instead of icon fonts. Stroke color should match the surrounding text or button fill. Use `stroke-width="2"` or `2.5`, and `stroke-linecap="round"` / `stroke-linejoin="round"` for a friendly, consistent look.

Common icons:
- **Home**: house outline
- **Download**: downward arrow
- **Search**: magnifier
- **Check**: polyline checkmark
- **Play**: filled triangle
- **More**: three dots
- **Back**: chevron left
- **Shuffle**: crossed arrows
- **Settings**: gear

## Status indicators

For offline-first apps, always expose:
- Downloaded / not-downloaded state per item.
- Progress bar for storage usage.
- Filter chips for quick state switching.
- Bulk-selection mode with a bottom action bar.
