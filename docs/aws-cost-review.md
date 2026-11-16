# AWS cost review

Read-only way to see what an AWS account spends, which regions it spends in, and which idle
resources are still billed. The IAM user can list and describe. It cannot stop, delete, or buy
anything.

This repository holds the snapshot script and the policy template. Each AWS account creates its own
IAM user in its infra repo.

| Account | Infra repo | Terragrunt stack | IAM user / `AWS_PROFILE` | Admin creds |
| --- | --- | --- | --- | --- |
| Personal | [kj_devops](https://github.com/kristijorgji/kj_devops) | `terragrunt/envs/aws/prod/global/infra/billing/iam-setup` | `kj-ai-cost-analysis` | `eval $(kj-env)` |
| Single.al prod | [s_ops_infra_maze](https://github.com/Single-al/s_ops_infra_maze) | `terragrunt/envs/aws/prod/global/infra/billing/iam-setup` | `s-ai-cost-analysis` | `$(s-aws-env prod)` |

The snapshot command is [`scripts/aws-cost-snapshot.sh`](../scripts/aws-cost-snapshot.sh).

The IAM user name and the local AWS profile name are the same string. Prefixes keep profiles obvious
next to each other in `~/.aws`:

- `kj-` for personal
- `s-` for Single.al
- another prefix per other project or workplace

## Table of contents

- [Profiles already in ~/.aws](#profiles-already-in-aws)
- [Access key lifetime](#access-key-lifetime)
- [What the IAM user can do](#what-the-iam-user-can-do)
- [Create the IAM user](#create-the-iam-user)
- [Create the local profile](#create-the-local-profile)
- [Run a snapshot](#run-a-snapshot)
- [Regions](#regions)
- [Phases](#phases)
- [API cost](#api-cost)
- [Cost allocation tags](#cost-allocation-tags)
- [What this does not change](#what-this-does-not-change)
- [Troubleshooting](#troubleshooting)

## Profiles already in ~/.aws

`~/.aws/credentials` and `~/.aws/config` already have other profiles. Those stay as they are.

Work, personal, and project accounts share this one config file. The AWS CLI reads a single config
file and a single credentials file. It does not merge a `config.d` directory. Name profiles by
project so they stay obvious next to each other.

Add a new profile named exactly like the IAM user (`kj-ai-cost-analysis` or `s-ai-cost-analysis`).
Do not put this key in `[default]` or `[login]`.

- `[login]` is the source profile for assume-role profiles. Replacing it breaks those profiles.
- `[default]` is what the AWS CLI uses when `AWS_PROFILE` is unset. Leaving it alone means every
  other terminal keeps working the way it does now.
- `AWS_PROFILE=...` applies only to the command you prefix with it. Other shells keep their own
  profile.
- `aws configure --profile <user>` appends a section. It does not rewrite the other sections.

Admin helpers such as `eval $(kj-env)` or `$(s-aws-env prod)` export `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`. Those variables override every named profile. The snapshot script unsets
them inside its own process and then checks that the caller is `user/<AWS_PROFILE>`. Your shell
keeps the exports. Open a new terminal, or `unset` those four variables, before a manual `aws` call
with this profile:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE
aws sts get-caller-identity --profile kj-ai-cost-analysis
# or: --profile s-ai-cost-analysis
```

The ARN must end in `user/<that profile name>`.

## Access key lifetime

The access key does not expire. There is no `aws sso login` step and no session timeout. Calls work
until you deactivate or delete the key.

That is acceptable here. A leaked key can read the bill and describe resources. It cannot stop,
delete, or buy anything, and it is not the admin key. Expiry would not add a second control: a
stolen key that can call `AssumeRole` again is just as useful the next hour.

Keep the long-lived read-only key. Revisit a login only if this profile starts running unattended or
the key is copied onto another machine.

Delete the key with admin credentials when you no longer want spend queries. The read-only policy
denies `iam:DeleteAccessKey`, so this profile cannot delete itself:

```bash
aws iam list-access-keys --user-name kj-ai-cost-analysis
aws iam delete-access-key --user-name kj-ai-cost-analysis --access-key-id AKIA...
```

There is no console password. The user cannot sign in to the AWS website.

## What the IAM user can do

Allowed calls are get, list, and describe only:

- Cost Explorer reads: cost and usage, anomalies, dimension values, cost allocation tag list.
- Cost Optimization Hub and Compute Optimizer reads, including enrollment status.
- Inventory reads: regions, instances, volumes, addresses, snapshots, NAT gateways, RDS instances
  and manual snapshots, load balancers, target health, and CloudWatch `GetMetricData`.

Everything else is denied. The policy also explicitly denies stop, start, terminate, delete,
release, commitment purchase, optimizer or hub enrollment changes, cost allocation tag updates, and
IAM user, key, or policy changes. A later broader policy attached to this same user still cannot do
those denied actions.

The script does not opt the account into Compute Optimizer or Cost Optimization Hub. If they are
off, phase 2 records that and skips recommendations.

## Create the IAM user

From the **infra** repository root, with admin credentials for that account. Examples:

```bash
# personal
eval $(kj-env)
cd terragrunt/envs/aws/prod/global/infra/billing/iam-setup
terragrunt apply

# Single.al prod
$(s-aws-env prod)
cd terragrunt/envs/aws/prod/global/infra/billing/iam-setup
terragrunt apply
```

Apply creates the IAM user and a customer managed policy (`<user>-readonly`), then attaches that
policy. It does not create an AccessKeyId or secret. Confirm the plan shows no `aws_iam_access_key`.
Inline user policies are limited to 2048 bytes, which this document exceeds, so the policy is
managed instead of inline. The template is
[`policies/billing-readonly.json.tmpl`](../policies/billing-readonly.json.tmpl).

If a later Cost Explorer call returns `AccessDenied` while the policy is attached, the account
billing switch is off. Sign in as the root user and turn on **IAM user and role access to Billing
information** (Billing console, Billing preferences). Do not attach `AdministratorAccess` to this
user to get past that.

## Create the local profile

Terraform apply created the IAM user and attached the policy. The user still cannot sign the API:
there is no access key yet, and the secret is not in state. You create the key with a later IAM API
call. That call uses the admin session already exported in the shell. The new user cannot create its
own key: the policy denies `iam:CreateAccessKey`.

`--user-name` names the user that already exists in the account. It does not read Terraform state.
The response prints `AccessKeyId` and `SecretAccessKey` once. Do not commit them, and do not paste
them into chat.

`aws configure` only writes those values into `~/.aws`. It does not call AWS.

```bash
# personal
eval $(kj-env)
aws iam create-access-key --user-name kj-ai-cost-analysis
aws configure --profile kj-ai-cost-analysis
aws configure set region us-east-1 --profile kj-ai-cost-analysis

# Single.al prod
$(s-aws-env prod)
aws iam create-access-key --user-name s-ai-cost-analysis
aws configure --profile s-ai-cost-analysis
aws configure set region us-east-1 --profile s-ai-cost-analysis
```

`aws configure --profile <user>` appends a section. It does not rewrite `[default]` or `[login]`.
The region you set is only the CLI default for this profile. The script still passes an explicit
region on every call. See [Regions](#regions).

Exported admin keys override `--profile`. Unset them before any command that should use the
cost-analysis profile:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE
aws sts get-caller-identity --profile kj-ai-cost-analysis
```

## Run a snapshot

From this repository root:

```bash
AWS_PROFILE=kj-ai-cost-analysis bash scripts/aws-cost-snapshot.sh
AWS_PROFILE=s-ai-cost-analysis bash scripts/aws-cost-snapshot.sh
```

One enabled region:

```bash
AWS_PROFILE=s-ai-cost-analysis bash scripts/aws-cost-snapshot.sh --region eu-central-1
```

Phase 2 and phase 3 wait until you pass `--confirm-phase`:

```bash
AWS_PROFILE=s-ai-cost-analysis bash scripts/aws-cost-snapshot.sh --phase 2 --confirm-phase
AWS_PROFILE=s-ai-cost-analysis bash scripts/aws-cost-snapshot.sh --phase 3 --confirm-phase
```

Stdout is a short summary. JSON is written to `tmp/aws-cost/<UTC timestamp>/`, which is gitignored,
plus `report.html` in that folder. Open the HTML in a browser. Do not commit `tmp/aws-cost/`.

Resume without repeating paid Cost Explorer calls (skips any JSON file that already exists):

```bash
AWS_PROFILE=s-ai-cost-analysis bash scripts/aws-cost-snapshot.sh --from-dir tmp/aws-cost/<stamp>
```

When every phase 1 JSON file is already in the directory, the script makes no AWS calls. A sample
snapshot from the personal account (2026-10-22) is in
[`docs/examples/aws-cost-snapshot/`](examples/aws-cost-snapshot/).
`get-anomalies` uses `--date-interval StartDate=,EndDate=` with end equal to today. Cost and usage
queries keep an exclusive `End` of tomorrow.

## Regions

Two different meanings:

- **API endpoint.** Cost Explorer and Cost Optimization Hub exist only in `us-east-1`. The script
  always passes `--region us-east-1` for those two services. That does not filter the bill. With no
  region filter, the result includes every region plus charges AWS marks as `global` (CloudFront is
  the usual one).
- **Resource region.** Compute Optimizer, EC2, EBS, addresses, snapshots, NAT gateways, RDS, and
  load balancers are per region. The script calls `ec2:DescribeRegions` and queries each enabled
  region. Disabled regions are skipped.

Default is all enabled regions. `--region` does three things:

- Cost Explorer gets a `REGION` dimension filter. `global` charges drop out, and the script says so.
- Cost Optimization Hub `list-recommendations` is filtered to that region. The endpoint stays
  `us-east-1`.
- The inventory and Compute Optimizer loop is that one region, after checking it is enabled.

Nothing in the script is hardcoded to the regions an account uses today.

## Phases

### Phase 1, spend

Eight Cost Explorer requests. The monthly window starts on the first day of the month six months
ago and includes the current partial month. The daily window is the last 30 days. Metric is
`UnblendedCost`.

- Monthly by service, by region, and by record type (usage, tax, credit, refund).
- Monthly by service and usage type. This is where `PublicIPv4:InUseAddress` shows up. An address
  with an association is not free.
- Daily by service.
- Anomalies for the last 30 days.
- Cost allocation tags, active and inactive.

### Phase 2, rightsizing

For each selected region, read Compute Optimizer enrollment. If it is not `Active`, skip
recommendations for that region. If it is active, collect EC2, EBS, idle, and RDS recommendations.
Findings are not limited to `OVER_PROVISIONED`.

Cost Optimization Hub enrollment is read from the `us-east-1` endpoint. Recommendations are listed
only when the hub is enrolled.

### Phase 3, idle resources

For each selected region, fields only:

- Volumes with `status=available`.
- Every address. `assoc` null is unassociated. Associated addresses are still listed.
- Snapshots you own (`--owner-ids self`). Age over 90 days is flagged `olderThan90Days`.
- NAT gateways in `available` or `pending`.
- Application, network, and classic load balancers. For application and network load balancers,
  a 14-day CloudWatch sum (`RequestCount` or `ProcessedBytes`). Zero is "no traffic in 14 days",
  not a delete instruction.
- RDS instances, and manual RDS snapshots with the same 90-day flag.

Nothing is deleted.

## API cost

Each Cost Explorer request on the primary billing view costs $0.01. Phase 1 makes 8 requests, about
$0.08. The script prints the count. `sts` and `ec2:DescribeRegions` are not Cost Explorer calls.

Do not turn on Cost Explorer hourly granularity. That is a separate per-record charge. This script
does not enable it.

## Cost allocation tags

Terragrunt tags resources with `Project`, `Parent`, `Environment`, and `Owner`. Cost Explorer hides
them until those cost allocation tags are activated. The analyst user is not allowed to activate
them (`ce:UpdateCostAllocationTagsStatus` is denied).

Activation is an admin action, and it is not part of the snapshot:

```bash
aws ce update-cost-allocation-tags-status --region us-east-1 \
  --cost-allocation-tags-status \
  TagKey=Project,Status=Active \
  TagKey=Parent,Status=Active \
  TagKey=Environment,Status=Active \
  TagKey=Owner,Status=Active
```

History from before activation stays untagged unless you later request a backfill. The script does
not request one.

## What this does not change

- No `terragrunt apply` is done by the snapshot script.
- No access key is created by Terraform.
- Compute Optimizer and Cost Optimization Hub are not enrolled.
- No Savings Plan or Reserved Instance is purchased.
- No volume, snapshot, address, instance, or database is deleted or resized.
- The official billing MCP server is not installed. Use this profile and the script.
- `[default]`, `[login]`, and the assume-role profiles in `~/.aws` are not edited by the script.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| `Refusing to run: AWS_PROFILE must be set` | Export `AWS_PROFILE` to the cost-analysis IAM user name. Do not rely on `default`. |
| Caller is not `user/<AWS_PROFILE>` | Admin keys are still exported. Unset `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, and `AWS_DEFAULT_PROFILE`, then retry. |
| `AccessDenied` on `ce:` | Policy attached, then the billing IAM switch. Root user, Billing preferences. |
| Phase 2 says not enrolled | Expected until you opt in yourself. The script will not do it. |
| `--region` says the region is not enabled | `aws ec2 describe-regions --profile <user> --region us-east-1`. |
| Empty volumes in one region | That region has no unattached volumes. Other enabled regions are still scanned unless you passed `--region`. |
| Phase 2 or 3 exits with status 2 | Re-run with `--confirm-phase`. |
