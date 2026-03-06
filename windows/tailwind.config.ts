import type { Config } from "tailwindcss";

export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        surface: {
          0: "#0d0d0f",
          1: "#141417",
          2: "#1c1c21",
          3: "#242429",
          4: "#2e2e35",
        },
        border: {
          subtle: "#2a2a32",
          DEFAULT: "#3a3a44",
        },
        accent: {
          blue: "#4f8ef7",
          green: "#3fb950",
          yellow: "#d29922",
          red: "#f85149",
          purple: "#a371f7",
        },
      },
    },
  },
  plugins: [],
} satisfies Config;
