/** No automatic opening or action override: the normal popup stays default. */
export function mountSidePanel(root: HTMLElement, notify: (text: string) => void) {
  const top = root.querySelector<HTMLElement>('.top');
  if (!top || !chrome.sidePanel?.open) return;
  const inPanel = location.pathname === '/sidepanel.html';
  document.documentElement.classList.toggle('side-panel', inPanel);
  let actions = top.querySelector<HTMLElement>('.nexus-header-actions');
  if (!actions) {
    actions = document.createElement('span');
    actions.className = 'nexus-header-actions';
    const last = top.lastElementChild;
    last?.replaceWith(actions);
    if (last && last.tagName === 'BUTTON') actions.append(last);
  }
  const button = document.createElement('button');
  button.id = 'dual-window';
  button.className = 'icon';
  button.type = 'button';
  button.title = inPanel ? 'Close side panel' : 'Open beside webpage';
  button.setAttribute('aria-label', button.title);
  button.setAttribute('aria-pressed', String(inPanel));
  button.innerHTML = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M15 4v16M17.5 8h1M17.5 11h1M17.5 14h1"/></svg>';
  actions.prepend(button);
  let windowId: number | undefined;
  button.disabled = true;
  void chrome.windows.getCurrent().then(current => {
    windowId = current.id;
    button.disabled = windowId == null;
  }).catch(() => { button.title = 'Side panel unavailable in this browser'; });
  button.onclick = () => {
    if (windowId == null) return;
    // Invoke directly inside the click handler: Chrome requires a user gesture.
    const closing = (chrome.sidePanel as typeof chrome.sidePanel & {
      close?: (options: {windowId: number}) => Promise<void>;
    }).close;
    if (inPanel && !closing) {
      notify('Use the browser’s × button to close this side panel.');
      return;
    }
    const operation = inPanel ? closing!({windowId}) : chrome.sidePanel.open({windowId});
    void operation.catch(() => notify('The browser could not open or close the side panel. Try the extension in a normal browser window.'));
  };
}
