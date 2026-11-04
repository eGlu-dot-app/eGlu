document.title = 'Report script started';
chrome.notifications.onClicked.addListener(() => {});
const refresh = async () => {
  const { checks = [], finished = false } = await chrome.runtime.sendMessage({ validationResults: true }) || {};
  document.getElementById('results').textContent = JSON.stringify(checks, null, 2);
  const failed = checks.filter((check) => !check.ok);
  document.title = finished ? `API checks: ${checks.length - failed.length}/${checks.length} passed${failed.length ? ': ' + failed.map((check) => check.name + ' ' + check.error).join('; ') : ''}` : 'API checks running';
};
refresh();
chrome.storage.onChanged.addListener(refresh);
setInterval(refresh, 1000);
chrome.runtime.onMessage.addListener((message) => {
  if (message?.validationPage === location.href) return Promise.resolve({ url: location.href });
});
