# Contributing

Thanks for your interest in improving **aws-data-lakehouse**. This repository is
infrastructure-as-code (Terraform + PySpark), so the bar for a change is that it
plans cleanly, keeps the security posture intact, and is documented.

## Getting set up

```bash
git clone https://github.com/shivajichaprana/aws-data-lakehouse.git
cd aws-data-lakehouse
make init
```

You will need:

- Terraform >= 1.5 and the AWS provider >= 5.40
- Python 3.9+ (for the producer and PySpark job scripts)
- `tflint`, `checkov`, and `flake8` for the local checks (optional but
  recommended; CI runs them)

## Local checks before opening a PR

Run the full local gate from the repo root:

```bash
make fmt        # terraform fmt -recursive
make validate   # terraform init -backend=false + validate
make lint       # tflint + checkov + flake8/py_compile over scripts
make test       # pytest (where applicable)
```

`make lint` covers both the Terraform and the Python sides; please make sure it
is clean before requesting review.

## Coding standards

**Terraform**

- Every variable has a `description` and, where it constrains input, a
  `validation` block.
- Prefer least-privilege IAM: scope actions to specific ARNs, add
  confused-deputy guards (`aws:SourceAccount` / `sts:ExternalId`), and scope KMS
  use with `kms:ViaService`.
- Keep optional or account-specific features behind boolean flags so a baseline
  plan stays minimal and a credential-less `terraform plan` stays clean.
- New modules live under `terraform/<module>/` with `main.tf`, `variables.tf`,
  and `outputs.tf`, and are composed from the root `terraform/main.tf`.

**Python / PySpark**

- Type hints, docstrings, and the `logging` module (not `print`).
- Validate inputs and fail loudly on real errors; quarantine bad data rather
  than dropping it silently.

## Commit and PR conventions

- Use [Conventional Commits](https://www.conventionalcommits.org/) for messages
  (`feat`, `fix`, `docs`, `ci`, `chore`, `refactor`, `test`).
- Keep each PR focused on one logical change; update the relevant docs in
  `docs/` and the module reference in `README.md` when behavior changes.
- Do not commit real account data: use the documented placeholder account id
  `123456789012`, generic bucket/org placeholders, and never check in tool
  output generated against a real account.

## Reporting security issues

Please report vulnerabilities privately through a
[GitHub Security Advisory](https://github.com/shivajichaprana/aws-data-lakehouse/security/advisories/new)
rather than opening a public issue.

## Questions

Open a Discussion in the repository or comment on the relevant PR.
