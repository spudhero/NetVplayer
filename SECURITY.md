# Security

Do not report credentials, private Provider source, signing keys, or complete
session/media URLs in a public issue. Remove those values from logs and
diagnostic attachments before sharing them.

For a suspected vulnerability, use GitHub private vulnerability reporting.
Include only the minimum reproduction, affected commit, and mitigation details
needed to triage the report.

The Provider runtime is designed to reject unsigned packages, path escapes,
undeclared executable assets, insecure distribution indexes, and unapproved
source bindings. These checks are defense in depth and do not replace a review
of the Provider's service terms or network behavior.
