import React from "react";

export type VerdictValue = "apply" | "stretch" | "skip";
export type GuardrailValue = "pass" | "fail";
export type StageValue = "new" | "applied" | "replied" | "interview" | "offer" | "rejected";

export interface StatusPillProps extends React.HTMLAttributes<HTMLSpanElement> {
  /** Which semantic system the pill represents. */
  context: "verdict" | "guardrail" | "stage";
  /** Value within the chosen context (see VerdictValue / GuardrailValue / StageValue). */
  value: VerdictValue | GuardrailValue | StageValue | string;
  /** md (default, 12px) or sm (11px) for dense rows. */
  size?: "sm" | "md";
  /** Show the leading glyph on verdict/guardrail pills. Stage always shows a colored dot. Default true. */
  showIcon?: boolean;
}

/**
 * One pill, three semantic contexts. Verdict (apply/stretch/skip) and
 * guardrail (pass/fail) render a tone-colored soft chip with a leading
 * glyph; Kanban stage renders a colored dot + label.
 *
 * @startingPoint section="Status" subtitle="Verdict · guardrail · stage" viewport="320x120"
 */
export function StatusPill(props: StatusPillProps): JSX.Element;
