import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri 개발 서버: 고정 포트, 오류 화면이 창을 가리지 않게
export default defineConfig({
  plugins: [react()],
  // @/ = src (층별 import: @/shared/…, @/entities/…)
  resolve: { alias: { "@": "/src" } },
  clearScreen: false,
  server: { port: 1420, strictPort: true, watch: { ignored: ["**/src-tauri/**"] } },
  build: {
    target: "es2022",
    chunkSizeWarningLimit: 2000,
    rollupOptions: { output: { manualChunks: { "react-vendor": ["react", "react-dom"] } } },
  },
});
