import { loadFont as loadDisplayFont } from '@remotion/google-fonts/PlusJakartaSans';
import { loadFont as loadMonoFont } from '@remotion/google-fonts/JetBrainsMono';

const display = loadDisplayFont('normal', {
  weights: ['400', '500', '600', '700', '800'],
});

const mono = loadMonoFont('normal', {
  weights: ['400', '500', '600', '700'],
});

export const displayFontFamily = display.fontFamily;
export const monoFontFamily = mono.fontFamily;
