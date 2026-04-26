"use client";

// Root error boundary for the App Router. Renders when any Server / Client
// Component below throws and the throw isn't caught by a more specific
// boundary. Required to be a Client Component because Next.js wires up
// reset() on the client.
//
// Reference: https://nextjs.org/docs/app/building-your-application/routing/error-handling
export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <main className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A]">
      <div className="max-w-2xl">
        <h1 className="text-3xl font-medium">Something went wrong</h1>
        <hr className="mt-4 border-t border-[#E5E5E0]" />
        <p className="mt-6 text-[#1A1A1A]">{error.message}</p>
        {error.digest ? (
          <p className="mt-2 text-sm text-[#6B6B6B]">Ref: {error.digest}</p>
        ) : null}
        <button
          type="button"
          onClick={() => reset()}
          className="mt-8 text-sm text-[#1A1A1A] underline underline-offset-4 hover:text-[#6B6B6B]"
        >
          Try again
        </button>
      </div>
    </main>
  );
}
