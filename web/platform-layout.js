(() => {
  const params = new URLSearchParams(location.search);
  let layout = (params.get('layout') || 'landscape').toLowerCase();
  if (!['landscape', 'portrait', 'square'].includes(layout)) layout = 'landscape';
  document.documentElement.dataset.layout = layout;
  document.body.classList.add(`layout-${layout}`);
  const profile = (params.get('profile') || '').toLowerCase();
  if (profile) document.body.classList.add(`profile-${profile}`);
  const group = params.get('group');
  if (group) document.body.dataset.streamGroup = group;
})();
