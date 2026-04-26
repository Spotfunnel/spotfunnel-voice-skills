import { getServerSupabase } from "@/lib/supabase-server";
import { CustomerCard } from "@/components/CustomerCard";

type CustomerRow = {
  id: string;
  slug: string;
  name: string;
  created_at: string;
};

export default async function Home() {
  const supabase = await getServerSupabase();
  const { data, error } = await supabase
    .from("customers")
    .select("id, slug, name, created_at")
    .order("created_at", { ascending: false });

  if (error) {
    throw new Error(`Failed to load customers: ${error.message}`);
  }

  const customers: CustomerRow[] = data ?? [];

  if (customers.length === 0) {
    return (
      <main className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A]">
        <h1 className="text-3xl font-medium">ZeroOnboarding</h1>
        <p className="mt-8 text-[#6B6B6B]">
          Run /base-agent in Claude Code to onboard your first customer.
        </p>
      </main>
    );
  }

  return (
    <main className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A]">
      <h1 className="text-3xl font-medium">ZeroOnboarding</h1>
      <div className="mt-8 border-t border-[#E5E5E0]">
        {customers.map((c) => (
          <CustomerCard key={c.id} customer={c} />
        ))}
      </div>
    </main>
  );
}
