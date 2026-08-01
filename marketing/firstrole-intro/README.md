# FirstRole — LinkedIn intro video

20s, 1080×1350 (4:5) vertical video for the LinkedIn feed. Built with
[Remotion](https://remotion.dev). Text and motion only, no voiceover.

## Structure

| Time | Scene | File |
|---|---|---|
| 0–3s | Hook line, fades in over dark gradient | `src/scenes/Hook.tsx` |
| 3–8s | 3 problem beats, alternating slide-in | `src/scenes/Problem.tsx` |
| 8–15s | Wordmark reveal + 3 feature callouts w/ screenshots | `src/scenes/Solution.tsx` |
| 15–20s | CTA + small wordmark | `src/scenes/CTA.tsx` |

Scene order/timing is assembled in `src/FirstRoleIntro.tsx` from the
`TIMING` map in `src/content.ts`.

## What to edit

Everything content-related lives in **`src/content.ts`**: copy, colors,
fonts, timing, and screenshot paths. You shouldn't need to touch any other
file for a copy/asset-only pass.

**Screenshots:** drop your real app screenshots into `public/screenshots/`
and update the `screenshot` path for each entry in `CONTENT.features`.
Placeholder SVGs (`tailor.svg`, `match.svg`, `rag.svg`) are there now so the
video renders out of the box — swap the files or just point to new ones.
Portrait screenshots (roughly 3:4) slot in cleanly; anything else gets
`object-fit: cover`-cropped by `FeatureCallout.tsx`.

**Colors/fonts:** currently pulled from the app's own design tokens
(`Job-Hunt Agent design system/tokens/colors.css` — brand violet `#5647E0`
ramp — and `tokens/fonts.css` — Plus Jakarta Sans + JetBrains Mono). Change
`COLORS` / `FONTS` in `content.ts` if you want the video to diverge from the
in-app palette.

**Logo:** no logo file existed, so `src/components/Wordmark.tsx` renders a
styled text mark ("First" + "Role" in two colors). If you get a real
logo/icon, swap the `<span>`s for an `<Img src={staticFile('logo.svg')} />`
inside the same spring wrapper.

## Commands

```bash
npm install       # first time only
npm start          # opens Remotion Studio (live preview + timeline scrubber)
npm run build       # renders out/firstrole-intro.mp4
npm run still        # renders a single PNG frame for a quick sanity check
```

Run these from `marketing/firstrole-intro/`.
