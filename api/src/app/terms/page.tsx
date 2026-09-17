import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Terms of Use — Listing Force",
};

const SUPPORT_EMAIL = "trungvu0512@cttech.ltd";
const EFFECTIVE_DATE = "September 17, 2026";

export default function TermsPage() {
  return (
    <article>
      <h1>Terms of Use</h1>
      <p className="updated">Last updated: {EFFECTIVE_DATE}</p>

      <p>
        These Terms of Use (&quot;Terms&quot;) govern your use of the Listing Force iOS
        app and related services (the &quot;Service&quot;), operated by C&amp;T Technology
        Company Limited (cttech.ltd). You can reach us at{" "}
        <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>. By using the Service you
        agree to these Terms. If you do not agree, do not use the Service.
      </p>

      <h2>The service</h2>
      <p>
        Listing Force helps sellers photograph products and generate marketplace
        listing content, including titles, descriptions and ad scripts, with the help
        of AI. You must have a valid account to use the Service.
      </p>

      <h2>Eligibility and accounts</h2>
      <p>
        You must be at least 18 years old, or the age of majority in your
        jurisdiction, and able to form a binding contract. You are responsible for
        activity under your account and for keeping your sign-in secure.
      </p>

      <h2>Purchases, credits and subscriptions</h2>
      <p>
        The Service offers in-app purchases, including consumable credits and, where
        offered, auto-renewable subscriptions. Purchases are processed by Apple through
        your App Store account and are subject to the Apple Media Services Terms.
      </p>
      <ul>
        <li>
          Payment is charged to your Apple ID at confirmation of purchase.
        </li>
        <li>
          Auto-renewable subscriptions renew automatically unless cancelled at least 24
          hours before the end of the current period. Manage or cancel subscriptions in
          your Apple ID account settings; deleting the app or your Listing Force account
          does not cancel an Apple subscription.
        </li>
        <li>
          Consumable credits are consumed as you generate content and are generally
          non-refundable except as required by law or Apple&apos;s policies. Refund
          requests for App Store purchases are handled by Apple.
        </li>
      </ul>

      <h2>Acceptable use</h2>
      <p>You agree not to use the Service to:</p>
      <ul>
        <li>submit content you do not have the rights to use;</li>
        <li>create false, deceptive, infringing or unlawful listings;</li>
        <li>upload unlawful, harmful or others&apos; personal or sensitive information;</li>
        <li>interfere with, probe or attempt to disrupt the Service; or</li>
        <li>violate any marketplace&apos;s policies or applicable law.</li>
      </ul>

      <h2>Your content</h2>
      <p>
        You retain ownership of the product photos and details you submit. You grant us
        a limited licence to process that content to provide the Service, including
        sending it to our AI provider to generate results, as described in our{" "}
        <a href="/privacy">Privacy Policy</a>. You are responsible for reviewing
        generated content before publishing it to any marketplace.
      </p>

      <h2>AI-generated content</h2>
      <p>
        Generated listings and scripts are provided as drafts. AI output may be
        inaccurate or incomplete. You are solely responsible for verifying accuracy,
        legality and compliance before use. We make no warranty that generated content
        will meet any marketplace&apos;s requirements or result in sales.
      </p>

      <h2>Disclaimers</h2>
      <p>
        The Service is provided &quot;as is&quot; and &quot;as available&quot; without
        warranties of any kind, to the fullest extent permitted by law. We do not
        warrant that the Service will be uninterrupted, error-free or secure.
      </p>

      <h2>Limitation of liability</h2>
      <p>
        To the fullest extent permitted by law, Listing Force will not be liable for
        any indirect, incidental, special, consequential or punitive damages, or any
        loss of profits, revenue, data or goodwill, arising out of or related to your
        use of the Service.
      </p>

      <h2>Termination</h2>
      <p>
        You may stop using the Service and delete your account at any time from
        Settings in the app. We may suspend or terminate access if you violate these
        Terms or use the Service unlawfully.
      </p>

      <h2>Changes</h2>
      <p>
        We may update these Terms from time to time. Continued use of the Service after
        changes take effect constitutes acceptance of the revised Terms.
      </p>

      <h2>Contact</h2>
      <p>
        Questions about these Terms? Email{" "}
        <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>.
      </p>

      <a className="home" href="/support">Support</a>
    </article>
  );
}
