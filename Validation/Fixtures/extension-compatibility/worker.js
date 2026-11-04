// Synthetic data only. Run with a temporary EGLU_DATA_ROOT and bundle id.
(async () => {
  const checks = [], received = [];
  let finished = false;
  chrome.runtime.onMessage.addListener((message) => {
    if (message?.validationResults === true) return Promise.resolve({ checks, finished });
  });
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const note = (text) => chrome.runtime.sendNativeMessage('eglu', { api: 'report', args: ['validation', text] }).catch(() => {});
  note('API fixture started');
  const check = async (name, work) => {
    try {
      if (!await Promise.race([work(), wait(6000).then(() => { throw new Error('API timed out'); })])) throw new Error('Unexpected result');
      checks.push({ name, ok: true });
    }
    catch (error) { checks.push({ name, ok: false, error: String(error.message || error) }); }
    note(JSON.stringify(checks[checks.length - 1]));
    chrome.storage.local.set({ checks }).catch(() => {});
  };
  const rejects = async (work, text) => {
    try { await work(); return false; } catch (error) { return String(error.message || error).includes(text); }
  };
  chrome.storage.local.set({ checks: [], finished: false }).catch(() => {});
  for (const [namespace, name] of [['bookmarks', 'onCreated'], ['bookmarks', 'onChanged'], ['bookmarks', 'onRemoved'], ['history', 'onVisited'], ['downloads', 'onCreated'], ['downloads', 'onChanged'], ['downloads', 'onErased']]) {
    chrome[namespace][name].addListener((...args) => received.push({ event: namespace + '.' + name, args }));
  }
  await wait(150);
  let folder, bookmark, download;
  await check('isolated bookmark tree starts empty', async () => (await chrome.bookmarks.getChildren('1')).length === 0);
  await check('create bookmark folder', async () => { folder = await chrome.bookmarks.create({ title: 'Synthetic folder' }); return !!folder.id && folder.parentId === '1'; });
  await check('create and find bookmark', async () => {
    bookmark = await chrome.bookmarks.create({ parentId: folder.id, title: 'Synthetic page', url: 'https://example.invalid/compatibility' });
    return (await chrome.bookmarks.search('Synthetic page'))[0].id === bookmark.id;
  });
  await check('update and move bookmark', async () => {
    await chrome.bookmarks.update(bookmark.id, { title: 'Updated page' });
    const moved = await chrome.bookmarks.move(bookmark.id, { parentId: '1', index: 0 });
    return moved.parentId === '1' && moved.title === 'Updated page';
  });
  await check('fixed bookmark root cannot be removed', () => rejects(() => chrome.bookmarks.removeTree('1'), 'cannot be edited'));
  await check('write and search history', async () => {
    await chrome.history.addUrl({ url: 'https://example.invalid/compatibility' });
    const found = await chrome.history.search({ text: 'example.invalid', startTime: 0 });
    return found.some((item) => item.url === 'https://example.invalid/compatibility');
  });
  await check('read history visits', async () => (await chrome.history.getVisits({ url: 'https://example.invalid/compatibility' })).length === 1);
  await check('top sites uses space history', async () => (await chrome.topSites.get()).some((item) => item.url.includes('example.invalid')));
  await check('read notification permission without prompting', async () => ['granted', 'denied'].includes(await chrome.notifications.getPermissionLevel()));
  await check('unsupported notification templates reject', () => rejects(() => chrome.notifications.create('synthetic-image', { type: 'image', title: 'Synthetic', message: 'Not delivered' }), 'Image and progress'));
  await check('download actual bytes', async () => {
    download = await chrome.downloads.download({ url: 'data:text/plain;base64,U3ludGhldGljIGRvd25sb2Fk', filename: 'synthetic-extension.txt' });
    for (let attempt = 0; attempt < 30; attempt++) {
      const item = (await chrome.downloads.search({ id: download }))[0];
      if (item?.state === 'complete') return item.exists && item.fileSize === 18;
      if (item?.state === 'interrupted') throw new Error(item.error || 'Download interrupted');
      await wait(150);
    }
    return false;
  });
  await check('reject download path traversal', () => rejects(() => chrome.downloads.download({ url: 'data:text/plain,test', filename: '../escape.txt' }), 'subfolders'));
  await check('remove and erase a synthetic download', async () => {
    await chrome.downloads.removeFile(download);
    if ((await chrome.downloads.search({ id: download }))[0].exists) return false;
    const erased = await chrome.downloads.erase({ id: download });
    return erased.includes(download) && (await chrome.downloads.search({ id: download })).length === 0;
  });
  await check('processor information', async () => { const cpu = await chrome.system.cpu.getInfo(); return cpu.numOfProcessors > 0 && cpu.processors.length === cpu.numOfProcessors; });
  await check('memory information', async () => { const memory = await chrome.system.memory.getInfo(); return memory.capacity > 0 && memory.availableCapacity >= 0; });
  await check('display information', async () => (await chrome.system.display.getInfo()).some((display) => display.isPrimary));
  await check('storage information', async () => (await chrome.system.storage.getInfo()).length > 0);
  await check('installed fonts', async () => (await chrome.fontSettings.getFontList()).length > 0);
  await check('installed speech voices without playing audio', async () => Array.isArray(await chrome.tts.getVoices()));
  await check('website data settings', async () => (await chrome.browsingData.settings()).dataRemovalPermitted.cache === true);
  await check('protected cookies cannot be cleared', () => rejects(() => chrome.browsingData.remove({}, { cookies: true }), 'cannot clear cookies'));
  await check('clear synthetic cache', async () => { await chrome.browsingData.removeCache({}); return true; });
  await check('closed tab sessions', async () => Array.isArray(await chrome.sessions.getRecentlyClosed()));
  await check('tab capture explains its limitation', () => rejects(() => chrome.tabCapture.getMediaStreamId(), 'cannot record an individual tab'));
  await check('native bookmark and history events', async () => {
    await chrome.bookmarks.remove(bookmark.id);
    await chrome.bookmarks.remove(folder.id);
    await wait(150);
    return ['bookmarks.onCreated', 'bookmarks.onChanged', 'bookmarks.onRemoved', 'history.onVisited'].every((event) => received.some((item) => item.event === event));
  });
  await check('native download lifecycle events', async () => ['downloads.onCreated', 'downloads.onChanged', 'downloads.onErased'].every((event) => received.some((item) => item.event === event)));
  await check('tab updates open extension pages in the same tab', async () => {
    const tab = await chrome.tabs.create({ url: 'about:blank', active: true });
    const target = chrome.runtime.getURL('report.html?validation=tab-update');
    const uppercase = target.replace(chrome.runtime.id, chrome.runtime.id.toUpperCase());
    await chrome.tabs.update(tab.id, { url: uppercase });
    let loaded = false;
    for (let attempt = 0; attempt < 20; attempt++) {
      const reply = await chrome.runtime.sendMessage({ validationPage: target }).catch(() => undefined);
      if (reply?.url === target) {
        loaded = (await chrome.tabs.get(tab.id)).url === target;
        const probe = await chrome.bookmarks.create({ title: 'Page subscription probe', url: 'https://example.invalid/page-subscription' });
        await wait(150);
        loaded = loaded && received.some((entry) => entry.event === 'bookmarks.onCreated' && entry.args[0] === probe.id);
        await chrome.bookmarks.remove(probe.id);
        break;
      }
      await wait(100);
    }
    await chrome.tabs.remove(tab.id);
    return loaded;
  });
  await check('data removal respects excluded website data', async () => {
    await chrome.browsingData.removeHistory({ originTypes: { unprotectedWeb: false } });
    return (await chrome.history.search({ text: 'example.invalid', startTime: 0 })).length > 0;
  });
  await check('remove history through browsing data', async () => {
    await chrome.browsingData.removeHistory({});
    return (await chrome.history.search({ text: 'example.invalid', startTime: 0 })).length === 0;
  });
  await check('clear finished download activity through browsing data', async () => {
    await chrome.browsingData.removeDownloads({});
    return (await chrome.downloads.search({})).length === 0;
  });
  note('API fixture finished: ' + checks.filter((check) => check.ok).length + '/' + checks.length);
  finished = true;
  await chrome.storage.local.set({ checks, finished: true, received });
})();
