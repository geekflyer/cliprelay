(function() {
    const REPO = 'geekflyer/cliprelay';
    const API_URL = `https://api.github.com/repos/${REPO}/releases`;

    async function getLatestMacDownloadUrl() {
        try {
            const response = await fetch(API_URL + '?per_page=10');
            const releases = await response.json();
            const macRelease = releases.find(r => r.tag_name.startsWith('mac/'));
            if (macRelease) {
                const dmgAsset = macRelease.assets.find(a => a.name === 'ClipRelay.dmg');
                if (dmgAsset) return dmgAsset.browser_download_url;
            }
        } catch (e) {
            console.warn('Failed to fetch latest release URL, using fallback', e);
        }
        return `https://github.com/${REPO}/releases`;
    }

    document.addEventListener('DOMContentLoaded', async function() {
        const url = await getLatestMacDownloadUrl();
        document.querySelectorAll('a[data-download="mac"]').forEach(link => {
            link.href = url;
        });
    });
})();
