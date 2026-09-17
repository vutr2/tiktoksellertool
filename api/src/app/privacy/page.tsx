import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Privacy Policy — Listing Force",
};

const SUPPORT_EMAIL = "trungvu0512@cttech.ltd";
const EFFECTIVE_DATE = "September 17, 2026";

export default function PrivacyPage() {
  return (
    <article>
      <h1>Privacy Policy</h1>
      <p className="updated">Last updated: {EFFECTIVE_DATE}</p>

      <p>
        This Privacy Policy explains how Listing Force (&quot;Listing Force&quot;,
        &quot;we&quot;, &quot;us&quot;), the app operated by C&amp;T Technology Company Limited (cttech.ltd),
        handles information when you use the Listing Force iOS app and related services.
        You can reach us at{" "}
        <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>. We collect only what
        the app needs to function. We do not track you across other companies&apos; apps or websites,
        and we do not sell your personal data.
      </p>

      <h2>Information we collect</h2>
      <ul>
        <li>
          <strong>Account information.</strong> When you sign in with email or Sign in
          with Apple, we collect your email address (which may be an Apple private
          relay address) and, if provided by Apple, your name. We assign your account a
          user identifier.
        </li>
        <li>
          <strong>Product content you create.</strong> Product photos, product names,
          categories, key features and other details you enter to generate listings.
          Background removal is performed on your device; the original camera frame is
          not uploaded — only the product cutout is.
        </li>
        <li>
          <strong>Purchase records.</strong> Records of in-app purchases and credits,
          used to deliver what you bought and to support refunds. Payment itself is
          processed by Apple; we do not receive your card details.
        </li>
        <li>
          <strong>Content reports.</strong> If you report generated content, we retain
          your explanation and the affected content to review it.
        </li>
        <li>
          <strong>Service and diagnostic data.</strong> Records of your generation
          requests (the requested operation, marketplace and status), request latency,
          and AI provider/model metadata and traces, used to deliver results, recover
          your work, account for usage and operate the service.
        </li>
      </ul>

      <h2>How we use information</h2>
      <p>
        We use the information above solely to provide app functionality: to
        authenticate you, generate and store your listings, process purchases and
        credits, respond to reports and support requests, and keep the service
        working. We do not use your information for advertising or tracking.
      </p>

      <h2>AI processing</h2>
      <p>
        To generate listing text and ad scripts, we send your product cutout photos,
        the product details you enter and visible label text to our AI provider,
        Anthropic, which processes them to return the generated content. You are asked
        for permission before any AI request, and you can withdraw that permission for
        future requests at any time in Settings. Please avoid including personal or
        sensitive information in your product photos and descriptions.
      </p>

      <h2>Service providers</h2>
      <p>
        We share information with providers that operate the service on our behalf,
        including our cloud hosting and database provider and our AI provider
        (Anthropic). These providers process data only to provide their services to
        us. We do not share your data with data brokers.
      </p>

      <h2>International data transfers</h2>
      <p>
        Our service providers, including our AI provider, may process and store your
        information on servers located in the United States and other countries. Where
        required, we rely on appropriate safeguards for such transfers. By using the
        Service you understand your information may be processed outside your country of
        residence.
      </p>

      <h2>Data retention and deletion</h2>
      <p>
        We keep your account and content while your account is active. You can delete
        your account at any time from <strong>Settings → Delete Account</strong> in the
        app, which removes your account and product content. Certain purchase records
        may be retained where required to support refunds or to meet legal and
        accounting obligations.
      </p>

      <h2>Your choices</h2>
      <ul>
        <li>Withdraw AI data-sharing permission in Settings.</li>
        <li>Delete your account and content from within the app.</li>
        <li>Contact us to request access to or deletion of your personal data.</li>
      </ul>

      <h2>Children</h2>
      <p>
        Listing Force is intended for business sellers and is not directed to children
        under 13, and we do not knowingly collect their personal information.
      </p>

      <h2>Changes to this policy</h2>
      <p>
        We may update this policy from time to time. When we do, we will revise the
        &quot;Last updated&quot; date above.
      </p>

      <h2>Contact us</h2>
      <p>
        Questions about this policy or your data? Email{" "}
        <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>.
      </p>

      <a className="home" href="/support">Support</a>
    </article>
  );
}
