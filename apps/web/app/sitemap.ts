import type { MetadataRoute } from "next";

export default function sitemap(): MetadataRoute.Sitemap {
  // Fork: upstream lists the multica.ai marketing pages here. Those paths now
  // redirect to /login on this instance, and robots.ts disallows crawling
  // entirely, so a sitemap would only advertise URLs that no longer serve
  // content — on the wrong hostname at that. Empty is the honest answer.
  return [];
}
