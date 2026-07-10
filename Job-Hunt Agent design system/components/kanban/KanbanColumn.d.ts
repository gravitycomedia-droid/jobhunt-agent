import React from "react";
import { StageValue } from "../feedback/StatusPill";

export interface KanbanColumnProps extends React.HTMLAttributes<HTMLDivElement> {
  /** Pipeline stage this lane represents. */
  stage: StageValue;
  /** Card count in the header; defaults to counting children. */
  count?: number;
  /** Column width in px. Default 264. */
  width?: number;
  /** Application cards. */
  children?: React.ReactNode;
}

/**
 * One pipeline lane for the Applications Kanban board.
 * @startingPoint section="Cards" subtitle="Pipeline lane" viewport="280x360"
 */
export function KanbanColumn(props: KanbanColumnProps): JSX.Element;
