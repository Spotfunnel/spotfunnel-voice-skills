import type { Annotation } from "@/lib/types";

// Display the author of an annotation. M22+ rows have author_email (from JWT);
// pre-M22 localStorage-era rows have author_name only. Prefer email's local-
// part for tighter rail rendering — "leo · 2h ago" beats "leo@getspotfunnel.com
// · 2h ago".
export function displayAuthor(
  a: Pick<Annotation, "author_email" | "author_name">,
): string {
  if (a.author_email) {
    const at = a.author_email.indexOf("@");
    return at > 0 ? a.author_email.slice(0, at) : a.author_email;
  }
  if (a.author_name) return a.author_name;
  return "unknown";
}
