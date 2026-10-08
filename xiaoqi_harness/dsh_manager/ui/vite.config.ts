import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  base: '/xiaoqi/',
  plugins: [react()],
  build: { outDir: 'dist', emptyOutDir: true },
})
