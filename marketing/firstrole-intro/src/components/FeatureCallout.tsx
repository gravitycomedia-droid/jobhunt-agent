import React from 'react';
import {
  AbsoluteFill,
  useCurrentFrame,
  useVideoConfig,
  spring,
  interpolate,
  Img,
  staticFile,
} from 'remotion';
import { COLORS, FONTS } from '../content';

export const FeatureCallout: React.FC<{
  icon: string;
  label: string;
  screenshot: string;
}> = ({ icon, label, screenshot }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const enter = spring({ frame, fps, config: { damping: 16, stiffness: 130 } });
  const opacity = interpolate(frame, [0, 12], [0, 1], {
    extrapolateRight: 'clamp',
  });
  const y = interpolate(enter, [0, 1], [40, 0]);

  return (
    <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
      <div
        style={{
          opacity,
          transform: `translateY(${y}px)`,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          gap: 28,
        }}
      >
        <div
          style={{
            width: 460,
            height: 620,
            borderRadius: 40,
            border: `2px solid ${COLORS.border}`,
            overflow: 'hidden',
            boxShadow: '0 30px 60px rgba(0,0,0,0.35)',
            background: COLORS.bgStart,
          }}
        >
          <Img
            src={staticFile(screenshot)}
            style={{ width: '100%', height: '100%', objectFit: 'cover' }}
          />
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          <span style={{ fontFamily: FONTS.mono, fontSize: 34, color: COLORS.accentStrong }}>
            {icon}
          </span>
          <span
            style={{
              fontFamily: FONTS.display,
              fontWeight: 700,
              fontSize: 40,
              color: COLORS.ink,
            }}
          >
            {label}
          </span>
        </div>
      </div>
    </AbsoluteFill>
  );
};
