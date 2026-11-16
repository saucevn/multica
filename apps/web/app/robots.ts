import type { MetadataRoute } from "next";

export default function robots(): MetadataRoute.Robots {
  // Fork: upstream ships this for the public multica.ai marketing site, so it
  // allowed `/`, `/about` and `/changelog` and advertised a sitemap on the
  // multica.ai host. This fork is a private instance — every page behind it is
  // either a login screen or workspace data, and the marketing paths now
  // redirect to /login. Nothing here should be crawled, and advertising a
  // multica.ai sitemap from a Hira deployment is simply wrong.
  return {
    rules: [
      {
        userAgent: "*",
        disallow: "/",
      },
    ],
  };
}
