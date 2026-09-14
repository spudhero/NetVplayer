const navToggle = document.querySelector('.nav-toggle');
const navMenu = document.querySelector('.nav-menu');
const navLinks = document.querySelectorAll('.nav-menu a');
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
const releaseVersionNodes = document.querySelectorAll('[data-release-version]');
const releaseDownloadLinks = document.querySelectorAll('[data-release-download]');
const latestReleaseAPI = 'https://api.github.com/repos/spudhero/NetVplayer/releases/latest';

async function synchronizeLatestRelease() {
  try {
    const response = await fetch(latestReleaseAPI, {
      headers: { Accept: 'application/vnd.github+json' },
      cache: 'no-store'
    });
    if (!response.ok) return;

    const release = await response.json();
    const version = String(release.tag_name || '').replace(/^v/, '');
    if (!/^\d+\.\d+\.\d+$/.test(version) || !Array.isArray(release.assets)) return;

    const expectedAssetName = `NetVplayer-${version}-macos-arm64.zip`;
    const asset = release.assets.find((candidate) => candidate?.name === expectedAssetName);
    if (!asset?.browser_download_url) return;

    releaseVersionNodes.forEach((node) => {
      node.textContent = version;
    });
    releaseDownloadLinks.forEach((link) => {
      link.href = asset.browser_download_url;
    });
  } catch {
    // Keep the reviewed static release fallback when GitHub is unavailable.
  }
}

synchronizeLatestRelease();

function setNavigation(open) {
  if (!navToggle || !navMenu) return;

  navToggle.setAttribute('aria-expanded', String(open));
  navToggle.querySelector('.sr-only').textContent = open ? '关闭导航菜单' : '打开导航菜单';
  navMenu.classList.toggle('is-open', open);
  document.body.classList.toggle('nav-open', open);
}

navToggle?.addEventListener('click', () => {
  setNavigation(navToggle.getAttribute('aria-expanded') !== 'true');
});

navLinks.forEach((link) => {
  link.addEventListener('click', () => setNavigation(false));
});

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') setNavigation(false);
});

window.addEventListener('resize', () => {
  if (window.innerWidth > 760) setNavigation(false);
});

const revealItems = document.querySelectorAll('.reveal');

if (reduceMotion.matches || !('IntersectionObserver' in window)) {
  revealItems.forEach((item) => item.classList.add('is-visible'));
} else {
  const observer = new IntersectionObserver((entries, instance) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('is-visible');
      instance.unobserve(entry.target);
    });
  }, {
    rootMargin: '0px 0px -10% 0px',
    threshold: 0.12
  });

  revealItems.forEach((item) => observer.observe(item));
}

document.querySelectorAll('[data-media-shell] img').forEach((image) => {
  const markMissing = () => image.closest('[data-media-shell]')?.classList.add('is-missing');

  image.addEventListener('error', markMissing, { once: true });
  if (image.complete && image.naturalWidth === 0) markMissing();
});

const themePreview = document.querySelector('#theme-preview');
const themeCaption = document.querySelector('#theme-caption');
const themeOptions = document.querySelectorAll('.theme-option');

themeOptions.forEach((option) => {
  option.addEventListener('click', () => {
    if (!themePreview || option.getAttribute('aria-pressed') === 'true') return;

    themeOptions.forEach((item) => {
      const selected = item === option;
      item.setAttribute('aria-pressed', String(selected));
      item.classList.toggle('is-active', selected);
    });

    themePreview.src = option.dataset.themeSrc;
    themePreview.alt = option.dataset.themeAlt;
    if (themeCaption) themeCaption.textContent = option.dataset.themeName;
  });
});

const experiencePreview = document.querySelector('#experience-preview');
const experienceCaption = document.querySelector('#experience-caption');
const experienceOptions = document.querySelectorAll('.experience-option');

experienceOptions.forEach((option) => {
  option.addEventListener('click', () => {
    if (!experiencePreview || option.getAttribute('aria-pressed') === 'true') return;

    experienceOptions.forEach((item) => {
      const selected = item === option;
      item.setAttribute('aria-pressed', String(selected));
      item.classList.toggle('is-active', selected);
    });

    experiencePreview.src = option.dataset.screenSrc;
    experiencePreview.alt = option.dataset.screenAlt;
    if (experienceCaption) experienceCaption.textContent = option.dataset.screenName;
  });
});
