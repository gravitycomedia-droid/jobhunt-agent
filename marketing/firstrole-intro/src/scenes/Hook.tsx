import React from 'react';
import { AbsoluteFill, useCurrentFrame, useVideoConfig, interpolate, spring } from 'remotion';
import { COLORS, FONTS, CONTENT } from '../content';

export const Hook: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const opacity = interpolate(frame, [0, 25], [0, 1], { extrapolateRight: 'clamp' });
  const exitOpacity = interpolate(frame, [70, 90], [1, 0], { extrapolateLeft: 'clamp' });
  const scale = spring({ frame, fps, config: { damping: 200, stiffness: 90 }, from: 0.92, to: 1 });

  return (
    <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', padding: '0 90px' }}>
      <div
        style={{
          opacity: opacity * exitOpacity,
          transform: `scale(${scale})`,
          fontFamily: FONTS.display,
          fontWeight: 800,
          fontSize: 76,
          lineHeight: 1.12,
          color: COLORS.ink,
          textAlign: 'center',
          letterSpacing: -1.5,
        }}
      >
        {CONTENT.hook}
      </div>
    </AbsoluteFill>
  );
};
