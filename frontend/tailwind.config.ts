import type { Config } from 'tailwindcss';

export default {
  content: ['./index.html', './src/**/*.{ts,js}'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        'gh-bg':         '#0d1117',
        'gh-surface':    '#161b22',
        'gh-surface2':   '#21262d',
        'gh-border':     '#30363d',
        'gh-text':       '#e6edf3',
        'gh-muted':      '#8b949e',
        'gh-blue':       '#388bfd',
        'gh-blue-light': '#58a6ff',
        'gh-green':      '#3fb950',
        'gh-red':        '#f85149',
        'gh-yellow':     '#e3b341',
      },
    },
  },
  plugins: [],
} satisfies Config;
