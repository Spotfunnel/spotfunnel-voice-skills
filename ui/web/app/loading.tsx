// Global App Router loading boundary. Renders while any Server Component in
// the tree is awaiting data — primarily Supabase round-trips on cold starts
// (200–1200ms). Without this, the operator stares at a frozen previous page.
//
// Visual: a faint pulsing card stack matching the warm off-white palette.
// No spinners, no logos. The skeleton is intentionally generic since this is
// the global fallback; route-level loading.tsx files render closer to the
// content shape they're replacing.
export default function Loading() {
  return (
    <main
      className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A]"
      data-testid="global-loading"
    >
      <div className="max-w-2xl animate-pulse">
        <div className="h-8 w-48 bg-[#E5E5E0] rounded" />
        <hr className="mt-4 border-t border-[#E5E5E0]" />
        <div className="mt-8 space-y-3">
          <div className="h-16 bg-[#E5E5E0]/60 rounded" />
          <div className="h-16 bg-[#E5E5E0]/60 rounded" />
          <div className="h-16 bg-[#E5E5E0]/60 rounded" />
        </div>
      </div>
    </main>
  );
}
