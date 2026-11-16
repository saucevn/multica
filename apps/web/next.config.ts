import type { NextConfig } from "next";
import { config } from "dotenv";
import { resolve } from "path";
import {
  resolveDevDocsUrl,
  resolveDevRemoteApiUrl,
  resolveDocsUrl,
  resolveRemoteApiUrl,
} from "./config/runtime-urls";
import { createMDX } from "fumadocs-mdx/next";

// Load root .env so local next.config.ts rewrites see REMOTE_API_URL / DOCS_URL.
// Production requests use proxy.ts runtime rewrites, which read process.env
// when the Next.js server runs instead of baking these URLs at build time.
config({ path: resolve(__dirname, "../../.env") });

// `next dev` falls back to the conventional localhost upstreams; builds use
// the strict resolvers so prebuilt images keep unset upstreams unproxied.
const isDev = process.env.NODE_ENV === "development";
const remoteApiUrl = isDev
  ? resolveDevRemoteApiUrl(process.env)
  : resolveRemoteApiUrl(process.env);
const docsUrl = isDev
  ? resolveDevDocsUrl(process.env)
  : resolveDocsUrl(process.env);

// Parse hostnames from CORS_ALLOWED_ORIGINS so that Next.js dev server
// allows cross-origin HMR / webpack requests (e.g. from Tailscale IPs).
const allowedDevOrigins = process.env.CORS_ALLOWED_ORIGINS
  ? process.env.CORS_ALLOWED_ORIGINS.split(",")
      .map((origin) => {
        try {
          return new URL(origin.trim()).host;
        } catch {
          return origin.trim();
        }
      })
      .filter(Boolean)
  : undefined;

const nextConfig: NextConfig = {
  ...(process.env.STANDALONE === "true" ? { output: "standalone" as const } : {}),
  transpilePackages: ["@multica/core", "@multica/ui", "@multica/views"],
  ...(allowedDevOrigins && allowedDevOrigins.length > 0
    ? { allowedDevOrigins }
    : {}),
  images: {
    formats: ["image/avif", "image/webp"],
    qualities: [75, 80, 85],
  },
  // Fork: this is a private instance, not a marketing site. Upstream's
  // `app/(landing)` route group still serves Multica branding on these paths,
  // which is what a visitor to app2.hira.vn currently lands on.
  //
  // Redirect rather than delete: the landing surface is ~41 upstream-owned files
  // plus MDX content and images. Deleting them would produce delete/modify
  // conflicts on every `scripts/sync-upstream.sh` run, forever — the exact tax
  // this fork is built to avoid. Those files stay byte-identical to upstream.
  //
  // `/` is deliberately NOT listed here. Config redirects run before proxy.ts,
  // and proxy.ts already sends a signed-in visitor with a `last_workspace_slug`
  // cookie straight to `/{slug}/issues`. Claiming `/` here would preempt that
  // and route them through `/login` instead — an extra hop and a visible flash
  // of the login screen for the common "type the bare domain" case. The
  // anonymous half of `/` is handled in proxy.ts instead.
  //
  // `permanent: false` (307) on purpose: a 308 is cached by browsers
  // indefinitely, so a real Hira landing added later would never reach anyone
  // who had already visited.
  async redirects() {
    return [
      { source: "/homepage", destination: "/login", permanent: false },
      { source: "/about", destination: "/login", permanent: false },
      { source: "/changelog", destination: "/login", permanent: false },
      { source: "/contact-sales", destination: "/login", permanent: false },
      // Advertises upstream Multica's releases, which are not this fork's builds.
      { source: "/download", destination: "/login", permanent: false },
      { source: "/usecases", destination: "/login", permanent: false },
      { source: "/usecases/:slug*", destination: "/login", permanent: false },
    ];
  },
  async rewrites() {
    return {
      // Run before file-system routes so /docs isn't shadowed by the
      // [workspaceSlug] dynamic segment.
      beforeFiles: docsUrl
        ? [
            {
              source: "/docs",
              destination: `${docsUrl}/docs`,
            },
            {
              source: "/docs/:path*",
              destination: `${docsUrl}/docs/:path*`,
            },
          ]
        : [],
      afterFiles: remoteApiUrl
        ? [
            {
              source: "/api/:path*",
              destination: `${remoteApiUrl}/api/:path*`,
            },
            {
              source: "/ws",
              destination: `${remoteApiUrl}/ws`,
            },
            {
              source: "/auth/:path*",
              destination: `${remoteApiUrl}/auth/:path*`,
            },
            {
              source: "/uploads/:path*",
              destination: `${remoteApiUrl}/uploads/:path*`,
            },
          ]
        : [],
      fallback: [],
    };
  },
};

// fumadocs-mdx@12 is incompatible with Next 16's Turbopack: its loader fails to
// dynamic-import `.source/source.config.mjs` under the Turbopack Node evaluator
// (see fumadocs#2658). `dev`/`build` scripts pass `--webpack` to opt out.
// Drop the flag once fumadocs-mdx ships a Turbopack-compatible loader.
const withMDX = createMDX() as (config: NextConfig) => NextConfig;

export default withMDX(nextConfig);
