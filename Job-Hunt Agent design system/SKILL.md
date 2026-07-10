---
name: job-hunt-agent-design
description: Use this skill to generate well-branded interfaces and assets for the Job-Hunt Agent app (Flutter, portrait-first AI job-search assistant), for production or throwaway prototypes/mocks. Contains design tokens, colors, type, fonts, an icon set, and the shared component library.
user-invocable: true
---

Read `readme.md` in this skill for the full design guide, then explore the other files.

- Tokens live in `tokens/` and are aggregated by `styles.css` — link that one file to inherit every color/type/spacing/radius/elevation custom property.
- Components live in `components/<group>/` as `<Name>.jsx` (React reference) + `<Name>.d.ts` (props contract). Compose them; never re-implement.
- Foundation specimen cards are in `guidelines/`; component specimens are the `*.card.html` files in `components/`.

If creating visual artifacts (slides, mocks, throwaway prototypes), copy assets out and produce static HTML that links `styles.css`. If working on production Flutter code, translate the tokens (hex, sizes, radii, spacing) into the app's theme and mirror the component specs.

If invoked with no other guidance, ask what to build, ask a few scoping questions, then act as an expert designer for this product.
