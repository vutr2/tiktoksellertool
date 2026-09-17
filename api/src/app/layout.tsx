import type { Metadata } from "next";
import type { ReactNode } from "react";

// Root layout. The API previously had no pages; it was added so the public
// Privacy Policy, Terms of Use and Support pages (linked from the app and from
// App Store Connect) can be served from the same origin as the API.
export const metadata: Metadata = {
  title: "Listing Force",
  description: "Legal and support information for the Listing Force app.",
};

const styles = `
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    line-height: 1.6;
    color: #1c1c1e;
    background: #f2f2f7;
  }
  main {
    max-width: 720px;
    margin: 0 auto;
    padding: 40px 20px 64px;
  }
  h1 { font-size: 2rem; margin: 0 0 4px; }
  h2 { font-size: 1.25rem; margin: 32px 0 8px; }
  p, li { font-size: 1rem; }
  a { color: #0a84ff; }
  .updated { color: #6e6e73; font-size: 0.9rem; margin: 0 0 24px; }
  .home { display: inline-block; margin-top: 40px; font-size: 0.9rem; }
  @media (prefers-color-scheme: dark) {
    body { color: #f2f2f7; background: #000; }
    .updated { color: #98989d; }
  }
`;

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <style dangerouslySetInnerHTML={{ __html: styles }} />
      </head>
      <body>
        <main>{children}</main>
      </body>
    </html>
  );
}
