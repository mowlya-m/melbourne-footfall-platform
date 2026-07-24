# Bootstrap

One-time infrastructure that everything else depends on. Applied manually from a
workstation, not from CI, because CI needs the OIDC role that this creates.

## Why local state

The remote backend cannot store the state of its own creation. Bootstrap
therefore uses local state, which is gitignored. This is the standard resolution
of that chicken-and-egg problem. Everything provisioned after bootstrap uses the
S3 backend created here.

If the local state file is lost, the resources still exist — reimport them with
`terraform import` rather than re-applying.

## Prerequisite

Enable billing alerts before applying, or the alarm has no metric to watch:

**AWS Console → Billing and Cost Management → Billing preferences →
Alert preferences → tick "Receive CloudWatch billing alerts" → Save.**

This setting is only available from the account root user or an admin, and only
in the us-east-1 console.

## Apply

```bash
cd infra/bootstrap
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan
terraform apply
```

Confirm the SNS subscription email that arrives afterwards, or alerts go nowhere.

## After applying

1. Copy the `github_actions_role_arn` output.
2. In the repository: **Settings → Secrets and variables → Actions → Variables →
   New repository variable**, name `AWS_ROLE_ARN`, value the ARN.
3. Copy the `backend_config` output into `infra/envs/dev/` from PR #4 onward.

## What this creates

| Resource | Purpose |
|---|---|
| CloudWatch billing alarm + SNS topic | Cost guardrail, created before anything billable |
| S3 bucket (versioned, encrypted, private) | Terraform remote state |
| DynamoDB table | State locking, prevents concurrent-apply corruption |
| IAM OIDC provider | Trusts GitHub's token issuer |
| IAM role | Assumed by Actions; scoped to this repository only |

## Cost

Under USD 1/month. The DynamoDB table is pay-per-request and effectively idle;
the S3 bucket holds a few hundred kilobytes.

## Note on credentials

No AWS access keys are stored in GitHub. Actions presents a short-lived OIDC
token, AWS validates it against the trust policy, and issues temporary
credentials. The trust policy is scoped with a `StringLike` condition on
`repo:OWNER/REPO:*`, so no other repository can assume this role.
