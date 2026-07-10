import React from "react";

export interface ScoreRingProps extends React.HTMLAttributes<HTMLDivElement> {
  /** Match score 0–100. */
  score: number;
  /** Diameter in px. Default 56. */
  size?: number;
  /** Ring thickness in px. Default 5. */
  thickness?: number;
  /** Override the auto verdict color (≥75 green · ≥50 amber · <50 red). */
  color?: string;
  /** Show the numeric % in the center. Default true. */
  showLabel?: boolean;
}

/**
 * Circular match-score gauge; color tracks the verdict thresholds.
 * @startingPoint section="Data" subtitle="Match-score gauge" viewport="120x120"
 */
export function ScoreRing(props: ScoreRingProps): JSX.Element;
