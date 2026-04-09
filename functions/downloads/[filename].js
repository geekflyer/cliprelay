const REPO = 'geekflyer/cliprelay';
const API_URL = `https://api.github.com/repos/${REPO}/releases?per_page=50`;
const RELEASES_PAGE = `https://github.com/${REPO}/releases`;

// Cache the resolved URL for 5 minutes to avoid GitHub API rate limits.
const CACHE_TTL_S = 300;

export async function onRequestGet(context) {
  const { params } = context;
  const requested = params.filename; // e.g. "ClipRelay.dmg"

  if (!requested?.endsWith('.dmg')) {
    return new Response('Not found', { status: 404 });
  }

  const cache = caches.default;
  const cacheKey = new Request(`https://cliprelay.org/_fn_cache/latest-mac-dmg`);

  let downloadUrl;

  const cached = await cache.match(cacheKey);
  if (cached) {
    downloadUrl = await cached.text();
  } else {
    downloadUrl = await resolveLatestDmgUrl();
    if (downloadUrl && downloadUrl !== RELEASES_PAGE) {
      const res = new Response(downloadUrl, {
        headers: { 'Cache-Control': `s-maxage=${CACHE_TTL_S}` },
      });
      context.waitUntil(cache.put(cacheKey, res));
    }
  }

  if (!downloadUrl) {
    downloadUrl = RELEASES_PAGE;
  }

  return Response.redirect(downloadUrl, 302);
}

async function resolveLatestDmgUrl() {
  try {
    const resp = await fetch(API_URL, {
      headers: { 'User-Agent': 'cliprelay-website/1.0' },
    });
    if (!resp.ok) return null;

    const releases = await resp.json();
    const macRelease = releases.find(
      (r) => r.tag_name.startsWith('mac/') && !r.prerelease && !r.draft,
    );
    if (!macRelease) return null;

    const dmgAsset = macRelease.assets.find((a) => a.name.endsWith('.dmg'));
    return dmgAsset?.browser_download_url ?? null;
  } catch {
    return null;
  }
}
