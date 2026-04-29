import Link from "next/link";

// URL-driven tabs (server-rendered). Active tab is whichever ?tab=... is set
// in the page's searchParams. Type-only nav: 11px uppercase tracking-widest,
// 1px underline beneath the active label, NO pill backgrounds. Anchored to
// the operator UI's editorial aesthetic — see clever-pondering-map.md
// "Visual language" section.

export type TabId = "overview" | "connections" | "read" | "verify" | "audit";

const TABS: ReadonlyArray<{ id: TabId; label: string }> = [
  { id: "overview", label: "Overview" },
  { id: "connections", label: "Connections" },
  { id: "read", label: "Read" },
  { id: "verify", label: "Verify" },
  { id: "audit", label: "Audit" },
];

export const DEFAULT_TAB: TabId = "overview";

// Defensive parser — anything outside the known set falls back to the
// default. Used both for rendering "active" state and by the page to
// decide which tab body to render.
export function parseTab(value: string | string[] | undefined): TabId {
  const v = Array.isArray(value) ? value[0] : value;
  if (v === "overview" || v === "connections" || v === "read" || v === "verify" || v === "audit") {
    return v;
  }
  return DEFAULT_TAB;
}

export function CustomerTabs({
  slug,
  currentTab,
}: {
  slug: string;
  currentTab: TabId;
}) {
  return (
    <nav
      className="mt-10 border-b border-[#EDECE6]"
      aria-label="Customer detail sections"
      data-testid="customer-tabs"
    >
      <ul className="flex items-end gap-8">
        {TABS.map((t) => {
          const active = t.id === currentTab;
          // The active tab's bottom border SITS ON TOP of the row's
          // border-b — paint it ink-black and the underlying #EDECE6 rule
          // is invisible at that segment.
          const tabClasses = [
            "inline-block pb-3 text-[11px] uppercase tracking-[0.18em] font-medium",
            "transition-colors duration-150",
            active
              ? "text-[#1A1A1A] border-b border-[#1A1A1A] -mb-px"
              : "text-[#9A9A92] hover:text-[#1A1A1A] border-b border-transparent",
          ].join(" ");
          // tab=overview is the default — omit the query string so the
          // canonical URL is /c/{slug}, not /c/{slug}?tab=overview.
          const href = t.id === DEFAULT_TAB ? `/c/${slug}` : `/c/${slug}?tab=${t.id}`;
          return (
            <li key={t.id}>
              <Link
                href={href}
                className={tabClasses}
                aria-current={active ? "page" : undefined}
                data-testid={`customer-tab-${t.id}`}
                data-active={active ? "true" : "false"}
              >
                {t.label}
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
