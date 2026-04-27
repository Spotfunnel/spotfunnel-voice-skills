import Link from "next/link";

// Global 404 page. Replaces Next.js's generic black-and-white error.
// Triggered by notFound() calls in server components (e.g. unknown customer
// slug, missing artifact) plus any unmatched URL.
export default function NotFound() {
  return (
    <main
      className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A]"
      data-testid="not-found"
    >
      <div className="max-w-2xl">
        <h1 className="text-3xl font-medium">Customer not found</h1>
        <hr className="mt-4 border-t border-[#E5E5E0]" />
        <p className="mt-6 text-[#6B6B6B]">
          The page you&rsquo;re looking for doesn&rsquo;t exist or was removed.
        </p>
        <Link
          href="/"
          className="mt-8 inline-block text-sm text-[#1A1A1A] underline underline-offset-4 hover:text-[#6B6B6B]"
          data-testid="not-found-back-link"
        >
          &larr; All customers
        </Link>
      </div>
    </main>
  );
}
