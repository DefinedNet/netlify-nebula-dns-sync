# Sync Nebula Host Names to Netlify DNS

Template repo for syncing your [Defined Networking](https://www.defined.net/) host names to [Netlify DNS](https://docs.netlify.com/domains-https/netlify-dns/) records via the API.

See the accompanying blog post: https://www.defined.net/blog/dns-for-nebula-hosts-using-the-api/

## Setup

1. Click **Use this template** and set your new repo's visibility to **Private** — scheduled workflows in public repos are [disabled automatically](https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-workflow-runs/disabling-and-enabling-a-workflow) after 60 days without activity.
2. Add `DN_API_KEY` and `NETLIFY_TOKEN` as [repository secrets](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions).
3. Set `DOMAIN` (and optionally `SUBDOMAIN`) in `.github/workflows/sync-dns.yml`.
4. Uncomment the `schedule` trigger in `.github/workflows/sync-dns.yml` — it ships commented out so the sync doesn't run before your secrets are configured.
