import React from "react";

/* score → verdict tone (mirrors StatusPill verdict mapping) */
function toneFor(score) {
  if (score >= 75) return { stroke: "var(--success-fill)", text: "var(--success-text)" };
  if (score >= 50) return { stroke: "var(--warning-fill)", text: "var(--warning-text)" };
  return { stroke: "var(--critical-fill)", text: "var(--critical-text)" };
}

/**
 * ScoreRing — circular match-score gauge. Color follows the verdict
 * thresholds (≥75 apply/green · ≥50 stretch/amber · <50 skip/red)
 * unless `color` is given.
 */
export function ScoreRing({ score = 0, size = 56, thickness = 5, color, showLabel = true, style, ...rest }) {
  const v = Math.max(0, Math.min(100, Math.round(score)));
  const r = (size - thickness) / 2;
  const c = 2 * Math.PI * r;
  const tone = toneFor(v);
  const stroke = color || tone.stroke;
  return (
    <div
      style={{ position: "relative", width: size, height: size, flex: "none", ...style }}
      role="img"
      aria-label={`Match score ${v} percent`}
      {...rest}
    >
      <svg width={size} height={size} style={{ display: "block", transform: "rotate(-90deg)" }}>
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="var(--neutral-200)" strokeWidth={thickness} />
        <circle
          cx={size / 2}
          cy={size / 2}
          r={r}
          fill="none"
          stroke={stroke}
          strokeWidth={thickness}
          strokeLinecap="round"
          strokeDasharray={c}
          strokeDashoffset={c * (1 - v / 100)}
          style={{ transition: "stroke-dashoffset 500ms ease" }}
        />
      </svg>
      {showLabel && (
        <div
          style={{
            position: "absolute",
            inset: 0,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontFamily: "var(--font-mono)",
            fontWeight: 700,
            fontSize: size >= 52 ? 16 : 12,
            color: tone.text,
            letterSpacing: "-0.02em",
          }}
        >
          {v}
          <span style={{ fontSize: size >= 52 ? 9 : 7, marginTop: 2, marginLeft: 1, opacity: 0.75 }}>%</span>
        </div>
      )}
    </div>
  );
}
