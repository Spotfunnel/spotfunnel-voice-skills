// Loading skeleton for the customer detail page. Matches the actual layout:
// title + run line + 7 chapter rows. Renders during Supabase fetches before
// the customer page hydrates.
export default function Loading() {
  return (
    <main
      className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A]"
      data-testid="customer-loading"
    >
      <div className="max-w-2xl animate-pulse">
        <div className="h-8 w-56 bg-[#E5E5E0] rounded" />
        <hr className="mt-4 border-t border-[#E5E5E0]" />
        <div className="mt-4 h-4 w-72 bg-[#E5E5E0]/60 rounded" />

        <div className="mt-12 h-3 w-12 bg-[#E5E5E0]/70 rounded" />

        <div className="mt-4 divide-y divide-[#E5E5E0]">
          {Array.from({ length: 7 }).map((_, i) => (
            <div key={i} className="flex items-baseline py-3 gap-4">
              <div className="h-4 w-6 bg-[#E5E5E0]/60 rounded" />
              <div className="h-4 flex-1 bg-[#E5E5E0]/60 rounded" />
              <div className="h-4 w-20 bg-[#E5E5E0]/60 rounded" />
            </div>
          ))}
        </div>
      </div>
    </main>
  );
}
