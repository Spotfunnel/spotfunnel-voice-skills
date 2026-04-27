import { NextResponse, type NextRequest } from "next/server";
import { updateSession } from "@/lib/supabase-middleware";

// Public paths that don't require an auth session. Anything else redirects to
// /login when there's no user.
const PUBLIC_PATHS = ["/login", "/auth/callback", "/logout"];

export async function middleware(req: NextRequest) {
  const { supabaseResponse, user } = await updateSession(req);

  const pathname = req.nextUrl.pathname;
  const isPublic =
    PUBLIC_PATHS.includes(pathname) ||
    pathname.startsWith("/_next") ||
    pathname.startsWith("/favicon");

  if (!user && !isPublic) {
    const url = req.nextUrl.clone();
    url.pathname = "/login";
    url.search = "";
    return NextResponse.redirect(url);
  }

  return supabaseResponse;
}

export const config = {
  matcher: [
    // Run middleware on everything except static assets + image optimizer.
    "/((?!_next/static|_next/image|favicon.ico).*)",
  ],
};
