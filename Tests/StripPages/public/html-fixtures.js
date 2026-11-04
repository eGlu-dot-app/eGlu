// Plain DOM event handlers. These pages do not mount React.
document.querySelectorAll('[data-collapse]').forEach((button) => {
  button.addEventListener('click', () => {
    const panel = document.getElementById(button.dataset.collapse);
    if (!panel) return;
    const expanded = panel.classList.toggle('show');
    button.setAttribute('aria-expanded', String(expanded));
  });
});
document.querySelectorAll('[data-dropdown]').forEach((button) => {
  button.addEventListener('click', () => {
    const menu = document.getElementById(button.dataset.dropdown);
    if (!menu) return;
    menu.hidden = !menu.hidden;
    button.setAttribute('aria-expanded', String(!menu.hidden));
  });
});
document.querySelectorAll('[data-message]').forEach((button) => {
  button.addEventListener('click', () => {
    const output = button.closest('.theme').querySelector('output');
    if (output) output.textContent = button.dataset.message;
  });
});
document.querySelectorAll('.bootstrap-search').forEach((form) => {
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const output = form.closest('.theme').querySelector('output');
    if (output) output.textContent = `Search: ${new FormData(form).get('query') || 'all articles'}`;
  });
});
