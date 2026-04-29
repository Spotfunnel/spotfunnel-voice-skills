import { ChapterRow } from "@/components/ChapterRow";
import { ARTIFACT_ORDER } from "@/lib/types";

// The existing chapter list, relocated into a tab. The ChapterRow component
// + ARTIFACT_ORDER constant stay unchanged — this is purely a structural
// move so the customer page can render Read alongside the new tabs.

export function ReadTab({
  slug,
  artifactNames,
  openByArtifact,
  resolvedByArtifact,
  scrapeCount,
}: {
  slug: string;
  artifactNames: Set<string>;
  openByArtifact: Map<string, number>;
  resolvedByArtifact: Map<string, number>;
  scrapeCount: number | undefined;
}) {
  return (
    <div className="mt-2 py-8 border-t border-[#EDECE6]" data-testid="tab-read">
      <h2 className="text-[11px] uppercase tracking-[0.18em] text-[#9A9A92] font-medium">
        Read
      </h2>
      <div className="mt-4 divide-y divide-[#E5E5E0]">
        {ARTIFACT_ORDER.map((chapter, i) => {
          const present = artifactNames.has(chapter.artifact);
          return (
            <ChapterRow
              key={chapter.artifact}
              number={i + 1}
              name={chapter.name}
              href={present ? `/c/${slug}/${chapter.artifact}` : null}
              openCount={openByArtifact.get(chapter.artifact) ?? 0}
              resolvedCount={resolvedByArtifact.get(chapter.artifact) ?? 0}
            />
          );
        })}

        {typeof scrapeCount === "number" ? (
          <ChapterRow
            number={7}
            name={`Scraped pages (${scrapeCount})`}
            href={`/c/${slug}/scraped-pages`}
            openCount={openByArtifact.get("scraped-pages") ?? 0}
            resolvedCount={resolvedByArtifact.get("scraped-pages") ?? 0}
          />
        ) : (
          <ChapterRow
            number={7}
            name="Scraped pages"
            href={null}
            openCount={null}
            resolvedCount={null}
          />
        )}
      </div>
    </div>
  );
}
