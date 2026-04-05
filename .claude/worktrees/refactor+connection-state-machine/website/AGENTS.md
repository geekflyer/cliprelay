# Website Agent Instructions

## Preview After Changes
After any change to files in this directory (HTML, CSS, JS), open the updated page in the user's default browser for local preview:

```
open index.html
```

If the change was to a specific page (e.g., `privacy.html`), open that page instead:

```
open privacy.html
```

## Deployment

The website is hosted on **Cloudflare Pages**.

- **Project name**: `cliprelay`
- **Production URL**: https://cliprelay.org
- **Source directory**: `website/`

### Deploy command

```bash
npx wrangler pages deploy website --project-name cliprelay --commit-dirty=true
```

### Authentication

If wrangler isn't authenticated, run:

```bash
npx wrangler login
```

This opens an OAuth flow in the browser. Credentials are cached locally after login.

### After website changes

After committing website changes, deploy to Cloudflare Pages using the deploy command above. The site serves the `website/` directory as-is (static HTML/CSS/JS, no build step).
