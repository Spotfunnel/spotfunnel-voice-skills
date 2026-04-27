import Link from "next/link";
import { getServerSupabase } from "@/lib/supabase-server";

// Tiny right-aligned chrome: "signed in as <email> · sign out". Server
// Component; reads the current session via the SSR client. Renders nothing
// when there's no user (login page won't show the header).
export async function Header() {
  const supabase = await getServerSupabase();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user?.email) return null;

  return (
    <div className="fixed top-0 right-0 z-30 px-4 py-2 text-[11px] text-[#7A7A72]">
      <span data-testid="header-email">{user.email}</span>
      <span className="mx-1.5 text-[#C0C0BA]">·</span>
      <Link
        href="/logout"
        prefetch={false}
        className="hover:text-[#1A1A1A] transition-colors"
        data-testid="header-logout"
      >
        sign out
      </Link>
    </div>
  );
}
