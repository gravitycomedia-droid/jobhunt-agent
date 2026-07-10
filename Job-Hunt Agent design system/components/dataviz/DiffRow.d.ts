import React from "react";

export interface DiffRowProps extends React.HTMLAttributes<HTMLDivElement> {
  /** The original resume bullet (shown struck-through unless `unchanged`). */
  original: string;
  /** The AI-tailored replacement. */
  tailored: string;
  /** Highlight the tailored text critical — a guardrail-rejected claim. */
  guardrailFail?: boolean;
  /** Suppress the strike-through on the original (kept as-is). */
  unchanged?: boolean;
}

/**
 * A single tailoring change (original → tailored) for the Tailoring Diff view.
 * Guardrail failures highlight the tailored text red.
 * @startingPoint section="Data" subtitle="Original vs tailored bullet" viewport="360x140"
 */
export function DiffRow(props: DiffRowProps): JSX.Element;
