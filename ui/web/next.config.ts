import type { NextConfig } from "next";
import path from "node:path";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  turbopack: {
    // Pin the workspace root so Next does not inadvertently pick up an
    // unrelated lockfile higher up the filesystem.
    root: path.resolve(__dirname),
  },
};

export default nextConfig;
