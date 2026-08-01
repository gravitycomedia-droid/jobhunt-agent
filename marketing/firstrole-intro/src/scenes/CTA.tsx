import React from 'react';
import { AbsoluteFill } from 'remotion';
import { Wordmark } from '../components/Wordmark';

export const CTA: React.FC = () => {
  return (
    <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
      <Wordmark size={104} />
    </AbsoluteFill>
  );
};
