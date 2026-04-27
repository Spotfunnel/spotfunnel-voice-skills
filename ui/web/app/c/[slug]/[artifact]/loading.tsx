// Loading skeleton for the artifact reading-mode page. Matches the actual
// layout: top breadcrumb + stacked muted paragraphs to mimic prose.
export default function Loading() {
  return (
    <main
      className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A] relative"
      data-testid="artifact-loading"
    >
      <div className="max-w-3xl mx-auto animate-pulse">
        <div className="h-4 w-64 bg-[#E5E5E0]/60 rounded" />
      </div>

      <div className="max-w-3xl mx-auto mt-10 animate-pulse space-y-4">
        <div className="h-8 w-3/4 bg-[#E5E5E0] rounded" />
        <div className="h-4 w-full bg-[#E5E5E0]/50 rounded" />
        <div className="h-4 w-full bg-[#E5E5E0]/50 rounded" />
        <div className="h-4 w-5/6 bg-[#E5E5E0]/50 rounded" />
        <div className="h-4 w-full bg-[#E5E5E0]/50 rounded" />
        <div className="h-4 w-4/6 bg-[#E5E5E0]/50 rounded" />

        <div className="h-4 w-full bg-[#E5E5E0]/50 rounded mt-8" />
        <div className="h-4 w-full bg-[#E5E5E0]/50 rounded" />
        <div className="h-4 w-3/4 bg-[#E5E5E0]/50 rounded" />
      </div>
    </main>
  );
}
