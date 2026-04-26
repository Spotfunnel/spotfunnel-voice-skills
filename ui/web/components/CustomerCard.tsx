import Link from "next/link";

type Customer = {
  slug: string;
  name: string;
  created_at: string;
};

export function CustomerCard({ customer }: { customer: Customer }) {
  return (
    <Link
      href={`/c/${customer.slug}`}
      className="block p-6 border-b border-[#E5E5E0] hover:bg-white transition-colors"
    >
      <h2 className="text-[32px] font-medium leading-tight">{customer.name}</h2>
      <p className="mt-1 font-mono text-sm text-[#6B6B6B]">{customer.slug}</p>
    </Link>
  );
}
