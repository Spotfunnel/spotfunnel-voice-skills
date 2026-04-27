"use client";

import { useEffect, useState } from "react";

// Small affordance hint for Ctrl+K. Renders as plain monospace text in the
// top-right chrome (below the Header). Platform-aware: shows ⌘K on macOS,
// Ctrl K elsewhere. Detects via user-agent on mount; SSR-safe default of
// "⌘K" since ~70% of operators are on Mac and the symbol is recognizable
// cross-platform.
export function CommandPaletteHint() {
  const [label, setLabel] = useState<string>("⌘K");

  useEffect(() => {
    if (typeof navigator === "undefined") return;
    const isMac = /Mac|iPhone|iPad|iPod/i.test(navigator.platform || "");
    setLabel(isMac ? "⌘K" : "Ctrl K");
  }, []);

  return (
    <div
      className="fixed top-9 right-4 z-30 text-[11px] text-[#7A7A72] flex items-center gap-1.5"
      data-testid="command-palette-hint"
    >
      <kbd className="font-mono">{label}</kbd>
      <span>to search</span>
    </div>
  );
}
