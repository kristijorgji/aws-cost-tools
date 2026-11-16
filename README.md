# aws-cost-tools

Read-only AWS spend snapshot shared by personal (`kj_devops`) and Single.al (`s_ops_infra_maze`)
accounts. The IAM user can list and describe. It cannot stop, delete, or buy anything.

## Requirements

- `aws` CLI
- `jq`
- A local AWS profile whose name matches the cost-analysis IAM user

## Run a snapshot

```bash
AWS_PROFILE=kj-ai-cost-analysis bash scripts/aws-cost-snapshot.sh
AWS_PROFILE=s-ai-cost-analysis bash scripts/aws-cost-snapshot.sh
```

`AWS_PROFILE` must be set. The script checks that `sts get-caller-identity` is `user/<that name>`.

Output goes to `tmp/aws-cost/<UTC stamp>/` (gitignored). Resume with `--from-dir` to skip Cost
Explorer files that already exist. Each new Cost Explorer request costs $0.01.

Full runbook: [docs/aws-cost-review.md](docs/aws-cost-review.md).

## Layout

```text
scripts/aws-cost-snapshot.sh
docs/aws-cost-review.md
docs/examples/aws-cost-snapshot/
policies/billing-readonly.json.tmpl
```

IAM users stay in each account's Terragrunt repo. Copy
[`policies/billing-readonly.json.tmpl`](policies/billing-readonly.json.tmpl) into those stacks; do
not create access keys in Terraform.
