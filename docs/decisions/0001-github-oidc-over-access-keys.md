# 0001: Use GitHub OIDC federation instead of stored AWS access keys

Date: 2026-07-24
Status: Accepted

## Context

GitHub Actions needs to deploy infrastructure into AWS. It requires credentials.
Three options were available:

1. Long-lived IAM user access keys stored as GitHub secrets
2. OIDC federation with a short-lived assumed role
3. A self-hosted runner inside the AWS account with an instance profile

## Decision

OIDC federation. GitHub Actions presents a short-lived OIDC token, AWS validates
it against a trust policy scoped to this repository, and STS issues temporary
credentials valid for one hour.

## Consequences

Positive:
- No long-lived credential exists to leak, rotate, or forget about
- Credentials expire in one hour, so a compromised workflow log has a narrow window
- The trust policy is scoped with `StringLike` on `repo:OWNER/REPO:*`, so no other
  repository can assume the role even if the ARN is public
- No rotation process to maintain

Negative:
- More setup than pasting two secrets: an OIDC provider, a trust policy, and a
  repository variable
- The thumbprint is pinned in Terraform and would need updating if GitHub rotated
  its certificate chain
- Harder to debug when it fails: errors surface as opaque STS denials rather than
  a clear "bad credentials"

## Alternatives rejected

**Stored access keys.** Simplest to set up and the most common approach in
tutorials. Rejected because a long-lived key in a public repository's settings is
a permanent liability, and key rotation is a process nobody actually runs.

**Self-hosted runner.** Removes the credential question entirely by running
inside the account. Rejected as disproportionate: it means operating an EC2
instance continuously for a pipeline that deploys a few times a day, which
contradicts the cost target.
