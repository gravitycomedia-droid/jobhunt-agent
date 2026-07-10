import React from "react";

export interface SimilarityBarProps extends React.HTMLAttributes<HTMLDivElement> {
  /** 0–100. */
  value: number;
  /** Optional caption above the bar. */
  label?: string;
  /** Show the numeric % on the right. Default true. */
  showValue?: boolean;
  /** Override the auto verdict color. */
  color?: string;
  /** Track height in px. Default 8. */
  height?: number;
}

/**
 * Horizontal similarity / coverage meter; color tracks verdict thresholds.
 * @startingPoint section="Data" subtitle="Similarity / coverage meter" viewport="320x80"
 */
export function SimilarityBar(props: SimilarityBarProps): JSX.Element;
