import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Support — Listing Force",
};

const SUPPORT_EMAIL = "trungvu0512@cttech.ltd";

export default function SupportPage() {
  return (
    <article>
      <h1>Listing Force Support</h1>
      <p className="updated">We&apos;re here to help.</p>

      <p>
        Listing Force helps sellers photograph products and generate marketplace
        listings with AI. If you have a question, a problem or feedback, get in touch.
      </p>

      <h2>Contact us</h2>
      <p>
        Listing Force is operated by C&amp;T Technology Company Limited (cttech.ltd).
        Email{" "}
        <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>. We aim to reply within
        two business days. To help us assist you faster, include your account email,
        your device and iOS version, and a description of what happened.
      </p>

      <h2>Common questions</h2>

      <h2>How do purchases and credits work?</h2>
      <p>
        Credits and any subscriptions are purchased through the App Store using your
        Apple ID. You can restore previous purchases from{" "}
        <strong>Settings → Restore Purchases</strong> in the app.
      </p>

      <h2>How do I manage or cancel a subscription?</h2>
      <p>
        Manage or cancel Apple subscriptions in your Apple ID account settings, or tap{" "}
        <strong>Manage Apple subscriptions</strong> in the app&apos;s Settings.
        Deleting the app or your account does not cancel an Apple subscription.
      </p>

      <h2>How do I request a refund?</h2>
      <p>
        Refunds for App Store purchases are handled by Apple at{" "}
        <a href="https://reportaproblem.apple.com">reportaproblem.apple.com</a>.
      </p>

      <h2>How do I delete my account?</h2>
      <p>
        Go to <strong>Settings → Delete Account</strong> in the app. This removes your
        account and product content. Some purchase records may be retained to support
        refunds and meet legal obligations.
      </p>

      <h2>How is my data used?</h2>
      <p>
        See our <a href="/privacy">Privacy Policy</a>. Background removal happens on
        your device, and AI generation uses only the product cutout and details you
        provide.
      </p>

      <p>
        <a href="/privacy">Privacy Policy</a> · <a href="/terms">Terms of Use</a>
      </p>
    </article>
  );
}
