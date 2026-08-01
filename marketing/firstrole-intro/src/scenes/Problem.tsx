import React from 'react';
import { AbsoluteFill, useCurrentFrame, useVideoConfig, interpolate, spring } from 'remotion';
import { COLORS, FONTS, CONTENT } from '../content';

const BEAT_LEN = 50; // 3 beats over the scene's 150 frames

export const Problem: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
      {CONTENT.problems.map((text, i) => {
        const start = i * BEAT_LEN;
        const local = frame - start;
        if (local < -10 || local > BEAT_LEN + 10) return null;

        const fromSide = i % 2 === 0 ? 1 : -1;
        const slide = spring({
          frame: local,
          fps,
          config: { damping: 18, stiffness: 140 },
          from: 60 * fromSide,
          to: 0,
        });
        const opacity = interpolate(
          local,
          [0, 15, BEAT_LEN - 15, BEAT_LEN],
          [0, 1, 1, 0],
          { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' },
        );

        return (
          <div
            key={text}
            style={{
              position: 'absolute',
              opacity,
              transform: `translateX(${slide}px)`,
              fontFamily: FONTS.display,
              fontWeight: 700,
              fontSize: 64,
              color: COLORS.inkSoft,
              textAlign: 'center',
            }}
          >
            {text}
          </div>
        );
      })}
    </AbsoluteFill>
  );
};
