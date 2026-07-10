import React from "react";

/**
 * LoadingSkeleton — shimmer placeholder. `variant`:
 *   "line"   — a text line (set width)
 *   "block"  — a rectangle (set width/height)
 *   "circle" — an avatar/ring (set size)
 *   "card"   — a full JobCard-shaped placeholder
 * Requires the @keyframes below; each card/DC that uses it should include it.
 */
const shimmer = {
  background:
    "linear-gradient(100deg, var(--neutral-100) 30%, var(--neutral-200) 50%, var(--neutral-100) 70%)",
  backgroundSize: "200% 100%",
  animation: "jha-shimmer 1.3s ease-in-out infinite",
};

function Bar({ w = "100%", h = 12, r = "var(--radius-sm)", style }) {
  return <div style={{ width: w, height: h, borderRadius: r, ...shimmer, ...style }} />;
}

export function LoadingSkeleton({ variant = "line", width, height, size = 42, count = 1, style, ...rest }) {
  if (variant === "circle") {
    return <div style={{ width: size, height: size, borderRadius: "50%", ...shimmer, ...style }} {...rest} />;
  }
  if (variant === "block") {
    return <div style={{ width: width || "100%", height: height || 80, borderRadius: "var(--radius-md)", ...shimmer, ...style }} {...rest} />;
  }
  if (variant === "card") {
    return (
      <div style={{ background: "var(--color-surface)", border: "1px solid var(--color-border)", borderRadius: "var(--radius-lg)", padding: "var(--space-4)", display: "flex", flexDirection: "column", gap: 12, ...style }} {...rest}>
        <div style={{ display: "flex", gap: 12, alignItems: "center" }}>
          <div style={{ width: 42, height: 42, borderRadius: "var(--radius-md)", ...shimmer }} />
          <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 7 }}>
            <Bar w="70%" h={14} />
            <Bar w="45%" h={11} />
          </div>
        </div>
        <div style={{ display: "flex", gap: 8 }}><Bar w={90} h={20} r="var(--radius-pill)" /><Bar w={70} h={20} r="var(--radius-pill)" /></div>
      </div>
    );
  }
  // line(s)
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8, ...style }} {...rest}>
      {Array.from({ length: count }).map((_, i) => (
        <Bar key={i} w={i === count - 1 && count > 1 ? "60%" : width || "100%"} h={height || 12} />
      ))}
    </div>
  );
}
