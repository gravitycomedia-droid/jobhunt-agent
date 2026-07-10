import React from "react";

export interface ChipInputProps extends Omit<React.InputHTMLAttributes<HTMLInputElement>, "value" | "onChange" | "style"> {
  /** Field label. */
  label?: string;
  /** Current chips. */
  value: string[];
  /** Called with the next chip array on add/remove. */
  onChange: (next: string[]) => void;
  /** Placeholder shown when empty. */
  placeholder?: string;
  /** Helper text. */
  hint?: string;
  /** Optional max number of chips. */
  max?: number;
  style?: React.CSSProperties;
}

/**
 * Token/tag input for target roles, skills, locations. Enter/comma adds,
 * ✕/Backspace removes.
 * @startingPoint section="Forms" subtitle="Tag / token entry" viewport="360x120"
 */
export function ChipInput(props: ChipInputProps): JSX.Element;
