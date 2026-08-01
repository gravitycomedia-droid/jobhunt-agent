/**
 * Everything you'd want to tweak for this video lives in this one file:
 * colors, fonts, timing, and all copy/image paths. Nothing else in
 * src/ should need editing for a content-only pass.
 */
import { displayFontFamily, monoFontFamily } from './fonts';

// ---- Canvas ---------------------------------------------------------
// 1080x1350 = 4:5, the tallest ratio the LinkedIn feed doesn't crop.
export const WIDTH = 1080;
export const HEIGHT = 1350;
export const FPS = 30;
export const DURATION_IN_FRAMES = 20 * FPS; // 600

// ---- Scene timing (frames @ 30fps) -----------------------------------
// Hook 0-3s, Problem 3-8s, Solution 8-15s, CTA 15-20s (matches the brief).
export const TIMING = {
  hook: { from: 0, duration: 90 },
  problem: { from: 90, duration: 150 },
  solution: { from: 240, duration: 210 },
  cta: { from: 450, duration: 150 },
};

// ---- Brand colors -----------------------------------------------------
// Pulled from `Job-Hunt Agent design system/tokens/colors.css` (--brand-*,
// --neutral-*). Swap these hexes if you want different colors for the video
// specifically — they don't need to match the app.
export const COLORS = {
  bgStart: '#181822', // --neutral-900
  bgMid: '#241F33',
  bgEnd: '#2E2679', // --brand-900
  ink: '#F7F7FB', // --neutral-50
  inkSoft: '#CBCBD9', // --neutral-300
  accent: '#8676EC', // --brand-400
  accentStrong: '#A79EF3', // --brand-300
  border: 'rgba(247, 247, 251, 0.14)',
};

// ---- Fonts --------------------------------------------------------------
// Plus Jakarta Sans / JetBrains Mono, same pairing as the app
// (`tokens/fonts.css`). Loaded via @remotion/google-fonts in fonts.ts.
export const FONTS = {
  display: displayFontFamily,
  mono: monoFontFamily,
};

// ---- Copy -----------------------------------------------------------------
export const CONTENT = {
  hook: 'Job hunting shouldn’t feel like a full-time job',
  problems: ['Generic resumes.', 'Missed matches.', 'Hours wasted tailoring.'],
  brand: {
    name: 'FirstRole',
  },
  // `screenshot` paths are relative to /public — drop your own PNG/JPG in
  // public/screenshots/ and swap the filename here. Anything with the
  // same aspect ratio (portrait, ~3:4) will slot in cleanly.
  features: [
    {
      icon: '✦', // ✦
      label: 'AI-tailored resumes',
      screenshot: 'screenshots/tailor.svg',
    },
    {
      icon: '◎', // ◎
      label: 'Smart job matching',
      screenshot: 'screenshots/match.svg',
    },
    {
      icon: '☁', // placeholder glyph, swap freely
      label: 'Built with RAG',
      screenshot: 'screenshots/rag.svg',
    },
  ],
};
