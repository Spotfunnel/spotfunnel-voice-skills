"use client";

import { useEffect, useState } from "react";

// Top-level gate: every page asks for an operator name on first visit and
// stores it in localStorage. Used as `author_name` for new annotations.
//
// Why localStorage and not a cookie/session: this is a single-operator UI
// behind Vercel password protection. We just need to attribute saves so
// future M7 review mode shows "Leo wrote this 2 hours ago".
//
// Renders nothing until mounted to avoid SSR/CSR mismatch (the server can't
// see localStorage). Children render unconditionally on the server, so the
// markdown still rasterizes fine without JS — the gate only intercepts
// interactive sessions.

const STORAGE_KEY = "operatorName";

export function OperatorNameGate({ children }: { children: React.ReactNode }) {
  const [mounted, setMounted] = useState(false);
  const [hasName, setHasName] = useState(false);
  const [draft, setDraft] = useState("");

  useEffect(() => {
    setMounted(true);
    const v = window.localStorage.getItem(STORAGE_KEY);
    if (v && v.trim()) setHasName(true);
  }, []);

  function submit(e: React.FormEvent) {
    e.preventDefault();
    const trimmed = draft.trim();
    if (!trimmed) return;
    window.localStorage.setItem(STORAGE_KEY, trimmed);
    setHasName(true);
  }

  // Pre-mount: render children to keep SSR markup stable. The interactive
  // gate appears post-hydration if no name is set.
  if (!mounted || hasName) {
    return <>{children}</>;
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-[#FAFAF7] p-12">
      <form
        onSubmit={submit}
        className="w-full max-w-sm bg-white border border-[#E5E5E0] rounded-md p-8"
      >
        <h1 className="text-xl font-medium text-[#1A1A1A]">Who&apos;s reading?</h1>
        <p className="mt-2 text-sm text-[#6B6B6B]">
          Used to sign your annotations. Stored locally, never sent to a server.
        </p>
        <input
          type="text"
          autoFocus
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          placeholder="e.g. Leo"
          className="mt-6 w-full border border-[#E5E5E0] rounded px-3 py-2 text-[#1A1A1A] focus:outline-none focus:border-[#3B5BDB]"
        />
        <button
          type="submit"
          disabled={!draft.trim()}
          className="mt-4 w-full bg-[#3B5BDB] text-white rounded px-4 py-2 text-sm font-medium hover:bg-[#2F4DBF] disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
        >
          Continue
        </button>
      </form>
    </div>
  );
}
