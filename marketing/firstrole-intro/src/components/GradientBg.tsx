import React from 'react';
import { AbsoluteFill } from 'remotion';
import { COLORS } from '../content';

// Persistent backdrop for the whole video — stays behind every scene so
// transitions never reveal a hard cut in the background.
export const GradientBg: React.FC = () => {
  return (
    <AbsoluteFill
      style={{
        background: `linear-gradient(160deg, ${COLORS.bgStart} 0%, ${COLORS.bgMid} 48%, ${COLORS.bgEnd} 100%)`,
      }}
    >
      <AbsoluteFill
        style={{
          background:
            'radial-gradient(120% 90% at 50% 15%, rgba(255,255,255,0.06) 0%, rgba(255,255,255,0) 55%)',
        }}
      />
    </AbsoluteFill>
  );
};
