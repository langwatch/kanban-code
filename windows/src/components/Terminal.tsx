import { useEffect, useRef, useCallback } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { spawn, type IPty } from "tauri-pty";
import { useTheme } from "../theme";
import "@xterm/xterm/css/xterm.css";

interface Props {
  /** Unique terminal session id (for React key purposes) */
  ptyId: string;
  /** Command to run, e.g. ["wsl.exe"] */
  command: string[];
  /** Text to write into the PTY after shell starts (e.g. "claude --resume abc\r") */
  initialInput?: string;
  /** Called when the PTY process exits */
  onExit?: () => void;
}

const DARK_THEME = {
  background: "#0a0a0c",
  foreground: "#e4e4e7",
  cursor: "#4f8ef7",
  cursorAccent: "#0a0a0c",
  selectionBackground: "#4f8ef740",
  black: "#1a1a1f",
  red: "#f85149",
  green: "#3fb950",
  yellow: "#d29922",
  blue: "#4f8ef7",
  magenta: "#a371f7",
  cyan: "#56d4dd",
  white: "#e4e4e7",
  brightBlack: "#6b7280",
  brightRed: "#ff7b72",
  brightGreen: "#56d364",
  brightYellow: "#e3b341",
  brightBlue: "#79c0ff",
  brightMagenta: "#d2a8ff",
  brightCyan: "#76e3ea",
  brightWhite: "#ffffff",
};

const LIGHT_THEME = {
  background: "#fafafa",
  foreground: "#1a1a1a",
  cursor: "#4f8ef7",
  cursorAccent: "#ffffff",
  selectionBackground: "#4f8ef730",
  black: "#1a1a1a",
  red: "#cf222e",
  green: "#1a7f37",
  yellow: "#9a6700",
  blue: "#0969da",
  magenta: "#8250df",
  cyan: "#1b7c83",
  white: "#6e7781",
  brightBlack: "#57606a",
  brightRed: "#a40e26",
  brightGreen: "#2da44e",
  brightYellow: "#bf8700",
  brightBlue: "#218bff",
  brightMagenta: "#a475f9",
  brightCyan: "#3192aa",
  brightWhite: "#8c959f",
};

export default function TerminalView({ ptyId, command, initialInput, onExit }: Props) {
  const termRef = useRef<HTMLDivElement>(null);
  const xtermRef = useRef<XTerm | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const ptyRef = useRef<IPty | null>(null);
  const { theme } = useTheme();

  const doFit = useCallback(() => {
    if (fitRef.current && xtermRef.current) {
      try {
        fitRef.current.fit();
        const dims = fitRef.current.proposeDimensions();
        if (dims && ptyRef.current) {
          ptyRef.current.resize(dims.cols, dims.rows);
        }
      } catch {
        // terminal not visible yet
      }
    }
  }, []);

  useEffect(() => {
    if (!termRef.current) return;

    const xterm = new XTerm({
      fontFamily: "'Cascadia Code', 'Consolas', 'Courier New', monospace",
      fontSize: 13,
      lineHeight: 1.3,
      cursorBlink: true,
      cursorStyle: "bar",
      theme: theme === "dark" ? DARK_THEME : LIGHT_THEME,
      allowProposedApi: true,
      scrollback: 5000,
    });

    const fitAddon = new FitAddon();
    const webLinksAddon = new WebLinksAddon();
    xterm.loadAddon(fitAddon);
    xterm.loadAddon(webLinksAddon);

    xterm.open(termRef.current);
    xtermRef.current = xterm;
    fitRef.current = fitAddon;

    // Initial fit + spawn
    setTimeout(() => {
      fitAddon.fit();
      const dims = fitAddon.proposeDimensions();
      const cols = dims?.cols ?? 80;
      const rows = dims?.rows ?? 24;

      try {
        // spawn(command[0], args, { cols, rows })
        const pty = spawn(command[0], command.slice(1), { cols, rows });
        ptyRef.current = pty;

        // PTY output → xterm (data is Uint8Array)
        pty.onData((data: Uint8Array) => {
          xterm.write(data);
        });

        // PTY exit
        pty.onExit((_info: { exitCode: number; signal?: number }) => {
          xterm.writeln("\r\n\x1b[90m[Process exited]\x1b[0m");
          onExit?.();
        });

        // xterm input → PTY
        xterm.onData((data: string) => {
          pty.write(data);
        });

        // Send initial command after shell is ready
        if (initialInput) {
          setTimeout(() => {
            pty.write(initialInput);
          }, 800);
        }
      } catch (err) {
        xterm.writeln(`\r\n\x1b[31mFailed to start terminal: ${err}\x1b[0m`);
      }
    }, 50);

    // Resize observer
    const observer = new ResizeObserver(() => {
      if (fitRef.current && xtermRef.current) {
        try {
          fitRef.current.fit();
          const dims = fitRef.current.proposeDimensions();
          if (dims && ptyRef.current) {
            ptyRef.current.resize(dims.cols, dims.rows);
          }
        } catch {
          // ignore
        }
      }
    });
    observer.observe(termRef.current);

    return () => {
      observer.disconnect();
      ptyRef.current?.kill();
      ptyRef.current = null;
      xterm.dispose();
    };
  }, []); // Only mount once

  // Update theme without remounting
  useEffect(() => {
    if (xtermRef.current) {
      xtermRef.current.options.theme = theme === "dark" ? DARK_THEME : LIGHT_THEME;
    }
  }, [theme]);

  return (
    <div
      ref={termRef}
      className="flex-1 min-h-0"
      style={{ padding: "4px" }}
    />
  );
}
