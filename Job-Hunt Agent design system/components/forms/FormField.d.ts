import React from "react";

export interface FormFieldProps extends Omit<React.InputHTMLAttributes<HTMLInputElement>, "style"> {
  /** Field label. */
  label?: string;
  /** Controlled value. */
  value?: string;
  /** Change handler. */
  onChange?: (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => void;
  /** Placeholder. */
  placeholder?: string;
  /** Input type (text, email, password…). */
  type?: string;
  /** Helper text below the field. */
  hint?: string;
  /** Error message (overrides hint, turns the field critical). */
  error?: string;
  /** Marks required (adds a red asterisk). */
  required?: boolean;
  /** Disabled state. */
  disabled?: boolean;
  /** Render a textarea instead of an input. */
  multiline?: boolean;
  /** Textarea rows. Default 3. */
  rows?: number;
  style?: React.CSSProperties;
}

/**
 * Labeled text input with hint + error states — the base text-entry surface.
 * @startingPoint section="Forms" subtitle="Labeled input + validation" viewport="360x120"
 */
export function FormField(props: FormFieldProps): JSX.Element;
