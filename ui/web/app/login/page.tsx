"use client";

import { useState } from "react";
import { browserSupabase } from "@/lib/supabase-browser";

const ALLOWLIST = ["kye@getspotfunnel.com", "leo@getspotfunnel.com"];

export default function LoginPage() {
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<"idle" | "sending" | "sent" | "error">(
    "idle",
  );
  const [error, setError] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    const trimmed = email.trim().toLowerCase();
    if (!trimmed) return;
    if (!ALLOWLIST.includes(trimmed)) {
      setStatus("error");
      setError("That email is not on the allowlist. Ask Leo or Kye to invite you.");
      return;
    }
    setStatus("sending");
    setError(null);
    const origin =
      typeof window !== "undefined" ? window.location.origin : "";
    const { error: err } = await browserSupabase.auth.signInWithOtp({
      email: trimmed,
      options: { emailRedirectTo: `${origin}/auth/callback` },
    });
    if (err) {
      setStatus("error");
      setError(err.message);
      return;
    }
    setStatus("sent");
  }

  return (
    <main className="min-h-screen flex items-center justify-center bg-[#FAFAF7] p-12">
      <form
        onSubmit={submit}
        className="w-full max-w-sm bg-white border border-[#E5E5E0] rounded-md p-8"
      >
        <h1 className="text-xl font-medium text-[#1A1A1A]">ZeroOnboarding</h1>
        <p className="mt-2 text-sm text-[#6B6B6B]">
          Sign in with your email. We&apos;ll send a magic link.
        </p>

        {status === "sent" ? (
          <p
            className="mt-6 text-sm text-[#1A1A1A]"
            data-testid="login-sent"
          >
            Check your inbox for a sign-in link.
          </p>
        ) : (
          <>
            <input
              type="email"
              autoFocus
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="you@getspotfunnel.com"
              className="mt-6 w-full border border-[#E5E5E0] rounded px-3 py-2 text-[#1A1A1A] focus:outline-none focus:border-[#3B5BDB]"
              data-testid="login-email"
            />
            {error ? (
              <p className="mt-2 text-xs text-red-600" data-testid="login-error">
                {error}
              </p>
            ) : null}
            <button
              type="submit"
              disabled={status === "sending" || !email.trim()}
              className="mt-4 w-full bg-[#3B5BDB] text-white rounded px-4 py-2 text-sm font-medium hover:bg-[#2F4DBF] disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              data-testid="login-submit"
            >
              {status === "sending" ? "Sending…" : "Send magic link"}
            </button>
          </>
        )}
      </form>
    </main>
  );
}
