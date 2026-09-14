const navToggle = document.querySelector('.nav-toggle');
const navMenu = document.querySelector('.nav-menu');
const navLinks = document.querySelectorAll('.nav-menu a');
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

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
