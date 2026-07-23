import { execFile } from "child_process";

/**
 * Best-effort desktop notification. macOS uses osascript (always present on
 * macOS, no extra install). Other platforms are a documented no-op for v0 —
 * we print a note instead of silently failing so users on Linux/Windows know
 * why nothing popped up.
 */
export function notify(title: string, message: string): void {
  if (process.platform === "darwin") {
    const script = `display notification ${JSON.stringify(message)} with title ${JSON.stringify(title)} sound name "Glass"`;
    execFile("osascript", ["-e", script], (err) => {
      if (err) {
        console.error(`(notify failed: ${err.message})`);
      }
    });
    return;
  }
  console.error(`(desktop notifications are macOS-only in v0 — would have shown: "${title}: ${message}")`);
}
