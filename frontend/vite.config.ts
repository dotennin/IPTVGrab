import { defineConfig } from 'vite';

export default defineConfig({
  root: '.',
  build: {
    outDir: '../static/dist',
    emptyOutDir: true,
    sourcemap: true,
  },
  server: {
    port: 5173,
    proxy: {
      '/api': { target: 'http://localhost:8765', changeOrigin: true },
      '/ws':  { target: 'ws://localhost:8765',   ws: true, changeOrigin: true },
      '/downloads': { target: 'http://localhost:8765', changeOrigin: true },
      // Proxy /login so the server can redirect to /login.html (served from public/).
      // Without this, Vite's SPA fallback serves index.html at /login, causing an
      // infinite redirect loop when unauthenticated API calls trigger 401 → /login.
      '/login': { target: 'http://localhost:8765', changeOrigin: true },
    },
  },
});
