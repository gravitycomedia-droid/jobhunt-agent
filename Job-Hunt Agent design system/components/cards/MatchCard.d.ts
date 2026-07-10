import React from "react";
import { JobCardProps } from "./JobCard";
import { VerdictValue } from "../feedback/StatusPill";

export interface MatchCardProps extends JobCardProps {
  /** Match score 0–100 (drives the ring). */
  score: number;
  /** apply | stretch | skip. */
  verdict?: VerdictValue;
  /** Strength chips (green). */
  strengths?: string[];
  /** Gap chips (amber). */
  gaps?: string[];
  /** Start expanded. Default false. */
  defaultExpanded?: boolean;
  /** Primary-action handler shown when expanded. */
  onTailor?: () => void;
  /** Label for the primary action. Default "Tailor resume". */
  tailorLabel?: string;
}

/**
 * JobCard + score ring + verdict pill + strength/gap chips; expandable.
 * @startingPoint section="Cards" subtitle="Match card with score & verdict" viewport="360x240"
 */
export function MatchCard(props: MatchCardProps): JSX.Element;
