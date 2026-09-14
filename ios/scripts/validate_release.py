"""Validate release configuration without contacting or printing endpoints."""
import ipaddress
import os
import sys
from urllib.parse import urlsplit


def public_https(value):
    try:
        url = urlsplit(value)
        host = (url.hostname or "").rstrip(".").lower()
        if url.scheme != "https" or not host or url.username or url.password or url.fragment:
            return False
        if url.port is not None and not 1 <= url.port <= 65535:
            return False
        if any(c.isspace() for c in value) or "\\" in value:
            return False
        if host == "localhost" or host.endswith((".localhost", ".local", ".test", ".invalid", ".example")):
            return False
        if host in {"example.com", "example.net", "example.org"} or host.endswith((".example.com", ".example.net", ".example.org")):
            return False
        try:
            return ipaddress.ip_address(host).is_global
        except ValueError:
            # Reject ambiguous numeric hosts, including noncanonical loopbacks.
            return "." in host and not all(c in "0123456789abcdefx.:" for c in host)
    except ValueError:
        return False


def validate(environ):
    if environ.get("CONFIGURATION") != "Release":
        return []
    errors = []
    for key in ["API_BASE_URL", "PRIVACY_POLICY_URL", "SUPPORT_URL", "TERMS_URL"]:
        value = environ.get(key, "")
        if not public_https(value):
            errors.append(f"{key} must be a public HTTPS URL, without credentials or placeholders, before Release.")
        elif key == "API_BASE_URL" and urlsplit(value).query:
            errors.append("API_BASE_URL must not include query parameters.")
    return errors


if __name__ == "__main__":
    errors = validate(os.environ)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    sys.exit(1 if errors else 0)
