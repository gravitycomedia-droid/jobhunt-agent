import React from "react";

/**
 * Icon — thin wrapper over a curated set of Lucide-style line glyphs.
 * Stroke-based, 24×24, inherits `currentColor`. Substituted from Lucide
 * (ISC) because the source app ships no icon assets — see readme.
 */
const PATHS = {
  // ---- Bottom-nav destinations ----
  home: ["M3 10.5 12 3l9 7.5", "M5 9.5V21h14V9.5"],
  briefcase: ["M3 8.5h18v11H3z", "M8 8.5V6a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2.5", "M3 13h18"],
  target: ["M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 1 0-18 0", "M12 12m-5 0a5 5 0 1 0 10 0a5 5 0 1 0-10 0", "M12 12m-1 0a1 1 0 1 0 2 0a1 1 0 1 0-2 0"],
  columns: ["M4 4h16v16H4z", "M9.5 4v16", "M15 4v16"],
  user: ["M12 12m-4 0a4 4 0 1 0 8 0a4 4 0 1 0-8 0", "M4 21c0-3.5 3.6-5.5 8-5.5s8 2 8 5.5"],
  // ---- Meta / chrome ----
  mapPin: ["M12 21s-6.5-5.5-6.5-10a6.5 6.5 0 1 1 13 0C18.5 15.5 12 21 12 21z", "M12 11m-2.2 0a2.2 2.2 0 1 0 4.4 0a2.2 2.2 0 1 0-4.4 0"],
  building: ["M4 21V5a1 1 0 0 1 1-1h9a1 1 0 0 1 1 1v16", "M15 9h4a1 1 0 0 1 1 1v11", "M8 8h3M8 12h3M8 16h3", "M2 21h20"],
  externalLink: ["M14 4h6v6", "M20 4 11 13", "M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"],
  search: ["M11 11m-7 0a7 7 0 1 0 14 0a7 7 0 1 0-14 0", "m20 20-3.5-3.5"],
  bell: ["M6 9a6 6 0 1 1 12 0c0 5 2 6 2 6H4s2-1 2-6", "M10.5 20a1.8 1.8 0 0 0 3 0"],
  bookmark: ["M6 3h12a1 1 0 0 1 1 1v17l-7-4-7 4V4a1 1 0 0 1 1-1z"],
  // ---- Verdict / guardrail / status glyphs ----
  check: ["M4 12.5 9 17.5 20 6.5"],
  x: ["M6 6 18 18", "M18 6 6 18"],
  minus: ["M5 12h14"],
  arrowUpRight: ["M7 17 17 7", "M8 7h9v9"],
  alertTriangle: ["M12 3 22 20H2L12 3z", "M12 10v5", "M12 18h.01"],
  info: ["M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 1 0-18 0", "M12 11v5", "M12 8h.01"],
  // ---- Structure / interaction ----
  chevronDown: ["M6 9.5 12 15.5 18 9.5"],
  chevronRight: ["M9.5 6 15.5 12 9.5 18"],
  plus: ["M12 5v14", "M5 12h14"],
  clock: ["M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 1 0-18 0", "M12 7v5l3.5 2"],
  bot: ["M6 8h12a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2z", "M12 4v4", "M12 4m-1 0a1 1 0 1 0 2 0a1 1 0 1 0-2 0", "M9 13v1.5M15 13v1.5"],
  upload: ["M12 15V4", "M8 8l4-4 4 4", "M4 17v2a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-2"],
  fileText: ["M6 3h8l5 5v13a0 0 0 0 1 0 0H6a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z", "M14 3v5h5", "M8.5 13h7M8.5 16.5h7"],
};

export function Icon({ name, size = 20, strokeWidth = 2, color, style, ...rest }) {
  const d = PATHS[name] || [];
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke={color || "currentColor"}
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      style={{ display: "block", flex: "none", ...style }}
      aria-hidden="true"
      {...rest}
    >
      {d.map((p, i) => (
        <path key={i} d={p} />
      ))}
    </svg>
  );
}
