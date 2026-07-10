import React from "react";
import { JobCard } from "./JobCard.jsx";
import { ScoreRing } from "../dataviz/ScoreRing.jsx";
import { StatusPill } from "../feedback/StatusPill.jsx";
import { Icon } from "../icons/Icon.jsx";

function Chip({ tone, children }) {
  const map = {
    strength: { bg: "var(--success-soft)", fg: "var(--success-text)", bd: "var(--success-border)" },
    gap: { bg: "var(--warning-soft)", fg: "var(--warning-text)", bd: "var(--warning-border)" },
  }[tone];
  return (
    <span style={{ display: "inline-flex", alignItems: "center", padding: "2px 9px", borderRadius: "var(--radius-pill)", background: map.bg, color: map.fg, border: `1px solid ${map.bd}`, fontSize: 12, fontWeight: 600 }}>
      {children}
    </span>
  );
}

/**
 * MatchCard — JobCard extended with a score ring, verdict pill, and
 * strength/gap chips. Collapses to a summary; expands to full chip lists
 * and the primary action.
 */
export function MatchCard({
  score = 0,
  verdict,
  strengths = [],
  gaps = [],
  defaultExpanded = false,
  onTailor,
  tailorLabel = "Tailor resume",
  ...jobProps
}) {
  const [open, setOpen] = React.useState(defaultExpanded);
  const shownStrengths = open ? strengths : strengths.slice(0, 2);
  const shownGaps = open ? gaps : gaps.slice(0, 1);
  const hidden = strengths.length + gaps.length - shownStrengths.length - shownGaps.length;

  return (
    <JobCard {...jobProps} trailing={<ScoreRing score={score} size={52} />}>
      <div style={{ display: "flex", flexDirection: "column", gap: "var(--space-3)", borderTop: "1px solid var(--color-border)", paddingTop: "var(--space-3)" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
          {verdict && <StatusPill context="verdict" value={verdict} />}
          <button
            type="button"
            onClick={(e) => { e.stopPropagation(); setOpen((o) => !o); }}
            style={{ marginLeft: "auto", appearance: "none", border: "none", background: "transparent", cursor: "pointer", display: "inline-flex", alignItems: "center", gap: 3, color: "var(--text-secondary)", fontSize: 13, fontWeight: 600, fontFamily: "var(--font-sans)", padding: 2 }}
          >
            {open ? "Less" : hidden > 0 ? `+${hidden} more` : "Details"}
            <Icon name="chevronDown" size={15} strokeWidth={2.4} style={{ transform: open ? "rotate(180deg)" : "none", transition: "transform 150ms ease" }} />
          </button>
        </div>

        <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
          {shownStrengths.map((s, i) => <Chip key={`s${i}`} tone="strength">{s}</Chip>)}
          {shownGaps.map((g, i) => <Chip key={`g${i}`} tone="gap">{g}</Chip>)}
        </div>

        {open && onTailor && (
          <button
            type="button"
            onClick={(e) => { e.stopPropagation(); onTailor(); }}
            style={{ appearance: "none", border: "none", cursor: "pointer", width: "100%", padding: "10px 14px", borderRadius: "var(--radius-md)", background: "var(--brand)", color: "var(--text-on-brand)", fontFamily: "var(--font-sans)", fontSize: 14, fontWeight: 700 }}
          >
            {tailorLabel}
          </button>
        )}
      </div>
    </JobCard>
  );
}
